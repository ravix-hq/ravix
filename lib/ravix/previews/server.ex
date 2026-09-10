defmodule Ravix.Previews.Server do
  @moduledoc """
  One process per track: the serial half of `server/previews.ts`.

  The TypeScript kept three maps on the manager: `operations` (a promise
  chain per track, so starts, stops and reconfigurations of one preview
  never overlap), `holds` (when the Sprites activity task was last
  refreshed) and `destinations`. Here the chain is a mailbox: every
  operation on a track is a call into that track's server, run to
  completion before the next, and the hold timestamp is the server's own
  memory. The database work that changes *intent* (desired state,
  generation, grants) is still done by the caller, in `Ravix.Previews`,
  before the operation is queued, which is what lets a stop that arrives
  during a sixty-second startup take effect: the startup re-reads the row at
  every step and abandons itself when the generation moved on.

  Servers are started on demand under `Ravix.Previews.Supervisor` and named
  through `:global` (`Ravix.Cluster.via/2`), so there is one per track in the
  *cluster* and not one per instance (ADR 0003): the chain above is a lock on a
  sprite, and two instances holding it would be no lock at all. One that has had
  nothing to do for ten minutes stops. They carry the `$callers` of whoever
  started them, so the SQL sandbox and Mimic follow a test into them.

  `Ravix.Previews.Registry` stays, demoted to one job: the `:idle`/`:busy` flag
  that `busy?/1` reads. It is node-local, on whichever instance owns the server,
  because a `:global` name carries no value and the flag has to be readable
  without sending the server a message -- its mailbox is, when the answer
  matters, exactly what is blocked.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Ravix.Previews
  alias Ravix.Previews.{Clock, Row, Store}
  alias Ravix.Repo
  alias Ravix.Sprites

  @registry Ravix.Previews.Registry
  @supervisor Ravix.Previews.Supervisor
  @start_ms 60_000
  @probe_ms 500
  @max_probes div(@start_ms, @probe_ms)
  @hold_ms 30_000
  @idle_ms 10 * 60_000
  @check_timeout_sec 15
  # Reading one flag off a sibling instance. Short on purpose: the caller is a
  # fifteen-second reconciliation tick, and a slow answer is worth less than a
  # prompt "assume busy" (see `busy?/1`).
  @busy_timeout_ms 1_000
  @hold_key :ravix_preview_hold_at

  @typedoc "What a server is asked to do, in order of arrival."
  @type operation ::
          {:ensure_running, generation :: integer(), restart? :: boolean()}
          | {:retire, Row.t(), remove? :: boolean(), changes :: keyword()}

  @typep failure :: {:error, :stale} | {:error, term(), Row.t()}

  @doc "The child specs of the registry and supervisor the servers live under."
  @spec child_specs() :: [{module(), keyword()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  @doc false
  def start_link(opts) do
    track_id = Keyword.fetch!(opts, :track_id)
    GenServer.start_link(__MODULE__, opts, name: Ravix.Cluster.via(:preview, track_id))
  end

  @doc "The server for a track, anywhere in the cluster, started here if it is not running."
  @spec ensure(String.t()) :: pid()
  def ensure(track_id) do
    case Ravix.Cluster.whereis(:preview, track_id) do
      nil -> start_server(track_id)
      pid -> if alive?(pid), do: pid, else: start_server(track_id)
    end
  end

  defp start_server(track_id) do
    callers = [self() | Process.get(:"$callers", [])]
    spec = {__MODULE__, track_id: track_id, callers: callers}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} ->
        pid

      # Another instance got there first, which is the whole point of the name.
      {:error, {:already_started, pid}} ->
        if alive?(pid), do: pid, else: ensure(track_id)
    end
  end

  # `Process.alive?/1` raises on a pid from another node, and a `:global` name
  # can briefly outlive its process: the removal is asynchronous, as a local
  # `Registry` entry was. For a remote server the answer is whether its instance
  # is still in the cluster -- one that died individually is caught instead by
  # `run/2`, which turns the exit into `{:error, :preview_server_down}`.
  defp alive?(pid) when node(pid) == node(), do: Process.alive?(pid)
  defp alive?(pid), do: node(pid) in Node.list()

  @doc """
  Run an operation on a track's server and wait for it.

  Operations run one at a time in arrival order. A server that stops
  underneath the call answers `{:error, :preview_server_down}` rather than
  exiting the caller.
  """
  @spec run(String.t(), operation()) :: :ok | {:error, term()}
  def run(track_id, operation) do
    GenServer.call(ensure(track_id), {:run, operation}, :infinity)
  catch
    :exit, _ -> {:error, :preview_server_down}
  end

  @doc """
  Whether an operation is in flight on a track (`operations.has` in the TypeScript).

  The flag is held on the instance that owns the server, so this reads across the
  cluster when it has to. An instance that cannot answer counts as busy: the only
  caller is `Ravix.Previews.Reconciler`, deciding whether to queue an `:ensure`,
  and "leave this track alone and come back in fifteen seconds" is the answer
  that cannot start work behind an operation it could not see.
  """
  @spec busy?(String.t()) :: boolean()
  def busy?(track_id) do
    case Ravix.Cluster.whereis(:preview, track_id) do
      nil -> false
      pid -> pid |> node() |> busy_on(track_id)
    end
  end

  @doc false
  @spec busy_on(node(), String.t()) :: boolean()
  def busy_on(owner, track_id) when owner == node(), do: local_busy?(track_id)

  def busy_on(owner, track_id) do
    :erpc.call(owner, __MODULE__, :local_busy?, [track_id], @busy_timeout_ms)
  catch
    _kind, _reason -> true
  end

  @doc false
  @spec local_busy?(String.t()) :: boolean()
  def local_busy?(track_id), do: match?([{_, :busy}], Registry.lookup(@registry, track_id))

  @doc "Stop a track's server if it is running (tests, and a track that is gone)."
  @spec stop(String.t()) :: :ok
  def stop(track_id) do
    case Ravix.Cluster.whereis(:preview, track_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  # ── the process ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.put(:"$callers", Keyword.get(opts, :callers, []))
    {:ok, %{track_id: Keyword.fetch!(opts, :track_id)}, @idle_ms}
  end

  @impl true
  def handle_call({:run, operation}, _from, state) do
    mark(state.track_id, :busy)

    result =
      try do
        perform(operation, state.track_id)
      rescue
        error ->
          Logger.error("ravix: preview operation #{state.track_id}: #{Exception.message(error)}")
          {:error, error}
      after
        mark(state.track_id, :idle)
      end

    {:reply, result, state, @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:noreply, state, @idle_ms}

  # Registered on first use rather than in `init/1`. A predecessor for this
  # track has already released its `:global` name by the time a successor can
  # start, but `Registry` reaps its entry on a monitor message, which may not
  # have arrived yet; an operation is late enough that it has.
  defp mark(track_id, value) do
    case Registry.update_value(@registry, track_id, fn _ -> value end) do
      :error -> Registry.register(@registry, track_id, value)
      {_new, _old} -> :ok
    end

    :ok
  end

  defp perform({:ensure_running, generation, restart?}, track_id) do
    case Store.get(track_id) do
      %Row{generation: ^generation} -> ensure_running(track_id, restart?)
      _ -> :ok
    end
  end

  defp perform({:retire, row, remove?, changes}, _track_id) do
    with :ok <- retire(row, remove?), do: update(row, changes)
  end

  # ── shared with the caller-side operations ───────────────────────────

  @doc false
  # Is `row` still the intent on record? Every step of a startup asks
  # before it acts, so a stop or a new configuration wins the moment it is
  # saved rather than when the startup notices.
  @spec current?(Row.t()) :: boolean()
  def current?(%Row{} = row) do
    case Store.get(row.track_id) do
      %Row{generation: generation, desired: :running, cleanup: false} ->
        generation == row.generation

      _ ->
        false
    end
  end

  @doc false
  # Change a row, but only if it is still the generation `row` names.
  @spec update(Row.t(), keyword()) :: :ok
  def update(%Row{} = row, changes) do
    Repo.transaction(fn ->
      case Store.get(row.track_id) do
        %Row{generation: generation} = fresh when generation == row.generation ->
          Store.save!(struct!(fresh, changes))

        _ ->
          :ok
      end
    end)

    :ok
  end

  # ── retire and hold ──────────────────────────────────────────────────

  # Stop the service and release its activity task; delete it when the
  # track is done with it.
  defp retire(%Row{sprite: nil}, _remove?), do: :ok

  defp retire(%Row{} = row, remove?) do
    with cfg when is_map(cfg) <- Sprites.config(),
         {:ok, _} <- Sprites.service_action(cfg, row.sprite, row.service, :stop),
         :ok <- release_activity(cfg, row),
         _ = Process.delete(@hold_key),
         {:ok, _} <- remove(cfg, row, remove?) do
      :ok
    else
      nil -> {:error, {:unavailable, "Restore SPRITES_TOKEN to stop the saved preview service."}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `service_action/4` treats a missing sprite as already-stopped, but
  # `activity/4` goes through `exec/4`, which has no such notion and fails for
  # a machine that is asleep or gone. Releasing a lease on a machine that no
  # longer exists is not work left undone, and holding cleanup open for it is:
  # the row keeps `cleanup: true`, so the reconciler decides `:cleanup` again
  # every fifteen seconds, for the life of the deployment, per abandoned track.
  defp release_activity(cfg, row) do
    case Sprites.activity(cfg, row.sprite, row.service, true) do
      :ok -> :ok
      {:error, %Sprites.Error{status: status}} when status in [404, 501] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove(_cfg, _row, false), do: {:ok, ""}
  defp remove(cfg, row, true), do: Sprites.service_action(cfg, row.sprite, row.service, :delete)

  # Refresh the two-minute Sprites task while the viewing lease is held, at
  # most every thirty seconds.
  defp hold(%Row{} = row) do
    now = Clock.now_ms()
    held_at = Process.get(@hold_key, 0)

    if row.sprite == nil or row.lease_until <= now or held_at > now - @hold_ms do
      :ok
    else
      with :ok <- Sprites.activity(Sprites.config(), row.sprite, row.service, false) do
        Process.put(@hold_key, now)
        :ok
      end
    end
  end

  # ── ensure_running ───────────────────────────────────────────────────

  defp ensure_running(track_id, restart?) do
    with %Row{} = row <- Store.get(track_id),
         true <- current?(row) do
      case start(row, restart?) do
        :ok -> :ok
        {:error, :stale} -> :ok
        {:error, reason, row} -> fail(row, reason)
      end
    else
      _ -> :ok
    end
  end

  @spec start(Row.t(), boolean()) :: :ok | failure()
  defp start(row, restart?) do
    with {:ok, %{track: track, project: project}} <- open(row),
         {:ok, config} <- config_for(row, project),
         {:ok, machine} <- machine(row, project),
         {:ok, sprite} <- sprite(row, machine),
         :ok <- fresh(row),
         {:ok, row} <- replace_if_moved(row, machine, sprite),
         {:ok, row} <- allocate(row, machine, sprite),
         {:ok, row} <- define(row, track, config, restart?),
         :ok <- fresh(row),
         :ok <- sprites(hold(Store.get(row.track_id) || row), row) do
      await_ready(row, project, config, Clock.now_ms() + @start_ms, @max_probes)
    end
  end

  # `{:error, :stale}` ends a startup silently: something newer is on record.
  defp fresh(row), do: if(current?(row), do: :ok, else: {:error, :stale})

  defp open(row) do
    case Previews.assert_open(row.track_id) do
      {:ok, found} -> {:ok, found}
      {:error, {:conflict, _code, message}} -> {:error, message, row}
    end
  end

  defp config_for(row, project) do
    case row.config || Store.defaults(project.id) do
      nil -> {:error, "Save a preview startup command and app directory first.", row}
      config -> {:ok, config}
    end
  end

  # Fresh, not memoised: the reconciler is what notices a replaced machine.
  defp machine(row, project) do
    case Ravix.Tracks.machine_of(project, fresh: true) do
      {:ok, %{sandbox_id: _} = machine} -> {:ok, machine}
      {:ok, nil} -> {:error, "This project has no machine. Open a track first.", row}
      {:error, reason} -> {:error, reason, row}
    end
  end

  defp sprite(row, machine) do
    case Ravix.Tracks.sprite_for(machine.sandbox_id) do
      sprite when is_binary(sprite) ->
        {:ok, sprite}

      _ ->
        message = "This workspace does not expose a Sprite. Previews are unavailable."
        {:error, Sprites.Error.new(501, message), row}
    end
  end

  # A service on a machine that is gone is retired before a new one is
  # defined, under a new generation so nothing from before can publish.
  defp replace_if_moved(%Row{sprite: nil} = row, _machine, _sprite), do: {:ok, row}

  defp replace_if_moved(row, machine, sprite) do
    if row.sprite == sprite and row.sandbox_id == machine.sandbox_id do
      {:ok, row}
    else
      with :ok <- sprites(retire(row, true), row),
           :ok <- fresh(row) do
        update(row,
          sprite: nil,
          port: nil,
          applied_config: nil,
          state: :starting,
          generation: row.generation + 1
        )

        {:ok, Store.get(row.track_id)}
      end
    end
  end

  defp allocate(row, machine, sprite) do
    case Store.allocate(row.track_id, machine.sandbox_id, sprite) do
      {:ok, row} -> {:ok, row}
      {:error, :no_ports} -> {:error, "This machine has no available preview ports.", row}
    end
  end

  defp define(row, track, config, restart?) do
    cfg = Sprites.config()
    fingerprint = Row.fingerprint(config)
    directory = Sprites.resolve_cwd(track.workdir, config.directory)

    with {:ok, service} <- sprites(Sprites.service(cfg, row.sprite, row.service), row),
         :ok <- fresh(row) do
      cond do
        restart? or row.applied_config != fingerprint or
            not matches?(service, config, directory, row.port) ->
          redefine(row, service, config, directory, fingerprint)

        get_in(service, ["state", "status"]) != "running" ->
          resume(row)

        true ->
          {:ok, row}
      end
    end
  end

  # The definition is right and the service merely stopped: start it again.
  defp resume(row) do
    cfg = Sprites.config()

    with {:ok, logs} <- sprites(Sprites.service_action(cfg, row.sprite, row.service, :start), row) do
      update(row, state: :starting, logs: logs, started_at: Clock.now_ms())
      {:ok, row}
    end
  end

  # PUT can return 200 "already running with that command" while retaining
  # old args, env or cwd, even after stop. Replace this track's owned
  # definition so the saved configuration really applies.
  defp redefine(row, service, config, directory, fingerprint) do
    cfg = Sprites.config()

    with :ok <- drop_definition(row, service),
         :ok <- port_free(row),
         :ok <- fresh(row),
         {:ok, logs} <-
           sprites(
             Sprites.define_service(
               cfg,
               row.sprite,
               row.service,
               directory,
               config.command,
               row.port
             ),
             row
           ) do
      update(row,
        applied_config: fingerprint,
        state: :starting,
        logs: logs,
        started_at: Clock.now_ms()
      )

      {:ok, row}
    end
  end

  defp drop_definition(_row, nil), do: :ok

  defp drop_definition(row, _service) do
    cfg = Sprites.config()

    with {:ok, _} <- sprites(Sprites.service_action(cfg, row.sprite, row.service, :stop), row),
         :ok <- fresh(row),
         {:ok, _} <- sprites(Sprites.service_action(cfg, row.sprite, row.service, :delete), row),
         do: fresh(row)
  end

  # Refuse a collision before creating a service. Readiness below only
  # examines the allocated port, so a server's fallback is never Ready.
  defp port_free(row) do
    script =
      "command -v ss >/dev/null || { echo \"Cannot verify preview port: ss is unavailable.\" >&2; exit 1; }; " <>
        "if ss -H -ltn 'sport = :#{row.port}' | read line; then " <>
        "echo 'Preview port #{row.port} is occupied. Stop the conflicting process.' >&2; exit 1; fi"

    case Sprites.exec(Sprites.config(), row.sprite, ["sh", "-lc", script], @check_timeout_sec) do
      {:ok, %{code: 0}} ->
        :ok

      {:ok, %{stderr: stderr}} ->
        {:error, blank_to(stderr, "Preview port collision."), row}

      # A machine that is asleep, gone, or unreachable answers here, and so
      # does an unconfigured Sprites. Without this clause the `case` raises,
      # which skips `fail/1` entirely: the row keeps `state: :starting` and a
      # nil error while its old service has already been dropped, so the page
      # says "Starting..." until the idle timer quietly stops it.
      {:error, reason} ->
        {:error, reason, row}
    end
  end

  defp matches?(nil, _config, _directory, _port), do: false

  defp matches?(service, config, directory, port) do
    service["cmd"] == "sh" and service["args"] == ["-lc", config.command] and
      service["dir"] == directory and
      get_in(service, ["env", "PORT"]) == Integer.to_string(port) and
      get_in(service, ["env", "HOST"]) == "127.0.0.1" and service["http_port"] == nil and
      (service["needs"] || []) == []
  end

  defp await_ready(row, _project, config, _deadline, 0), do: not_ready(row, config)

  defp await_ready(row, project, config, deadline, probes) do
    with :ok <- fresh(row),
         {:ok, actual} <- sprites(Sprites.service(Sprites.config(), row.sprite, row.service), row),
         :ok <- not_crashed(actual, row),
         false <- running?(actual) and Previews.ready?(row, config.readiness_path) do
      Clock.sleep(@probe_ms)

      if Clock.now_ms() < deadline,
        do: await_ready(row, project, config, deadline, probes - 1),
        else: not_ready(row, config)
    else
      true -> publish_ready(row, project)
      {:error, _} = failure -> failure
      {:error, _, _} = failure -> failure
    end
  end

  defp running?(actual), do: get_in(actual, ["state", "status"]) == "running"

  defp not_crashed(actual, row) do
    if (get_in(actual, ["state", "restart_count"]) || 0) >= 3,
      do:
        {:error,
         "Preview crashed repeatedly. Fix the startup command, then restart. See logs below.",
         row},
      else: :ok
  end

  # A machine replacement during startup cannot publish an old result.
  defp publish_ready(row, project) do
    case Ravix.Tracks.machine_of(project, fresh: true) do
      {:ok, %{sandbox_id: sandbox_id}} when sandbox_id == row.sandbox_id ->
        update(row, state: :ready, error: nil)

      _ ->
        {:error, "The workspace changed during startup. Open the preview again.", row}
    end
  end

  defp not_ready(row, config) do
    {:error,
     "Readiness did not pass at #{config.readiness_path} on $PORT=#{row.port}. " <>
       "The command must honor $PORT and fail on a collision.", row}
  end

  # Record a failed startup: keep the logs, stop the service, and stop
  # trying until somebody opens or restarts the preview again.
  defp fail(row, reason) do
    if current?(row) do
      logs = failure_logs(row)
      retire_or_defer(row)

      update(row,
        state: :failed,
        desired: :stopped,
        error: message_of(reason),
        logs: logs,
        unavailable: unavailable_of(reason)
      )
    end

    :ok
  end

  defp failure_logs(%Row{sprite: nil, logs: logs}), do: logs

  defp failure_logs(row) do
    case Sprites.service_logs(Sprites.config(), row.sprite, row.service) do
      {:ok, logs} -> logs
      _ -> row.logs
    end
  end

  defp retire_or_defer(%Row{sprite: nil}), do: :ok

  defp retire_or_defer(row) do
    case retire(row, false) do
      :ok -> :ok
      {:error, _reason} -> update(row, stop_pending: true)
    end
  end

  defp sprites(:ok, _row), do: :ok
  defp sprites({:ok, value}, _row), do: {:ok, value}
  defp sprites({:error, reason}, row), do: {:error, reason, row}

  @doc false
  @spec message_of(term()) :: String.t()
  def message_of(message) when is_binary(message), do: message
  def message_of(%Sprites.Error{message: message}), do: message
  def message_of(:unconfigured), do: "Previews unavailable: SPRITES_TOKEN is not configured."
  def message_of({:unavailable, message}), do: message
  def message_of({:conflict, _code, message}), do: message
  def message_of(%{__exception__: true} = error), do: Exception.message(error)
  def message_of(%{message: message}) when is_binary(message), do: message
  def message_of(_other), do: "Preview startup failed."

  defp unavailable_of(%Sprites.Error{status: status, message: message}) when status in [404, 501],
    do: message

  defp unavailable_of(_reason), do: nil

  defp blank_to(value, default) when value in [nil, ""], do: default
  defp blank_to(value, _default), do: value
end
