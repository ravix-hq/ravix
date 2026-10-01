defmodule Ravix.Previews.Lifecycle do
  @moduledoc """
  A track's preview service by track id: what happens to the row and to the
  per-track `Ravix.Previews.Server` once somebody has already decided the
  track may be touched.

  This is the id-only half of `Ravix.Previews`, and it is its own module for
  the same reason the row layer is `Ravix.Previews.Store`: nothing here
  establishes anybody's access, so it must not sit beside the functions that
  do. It is not *in* the store because it is not row access. `start_service/2`
  waits up to a minute on a GenServer, `stop_service/3` and `configure/2`
  hand the server an operation after the transaction commits, `ready?/2`
  opens a tunnel to the sprite; a store that talked to Sprites would be a
  store nobody could reason about. `Ravix.Credo.Architecture` judges a
  `Lifecycle` module exactly as it judges a `Store`: a page may not name
  one, and another context reaching in says which door it already went
  through in a `# ownership:` comment.

  Every operation that changes intent is written to the row here, before the
  server carries it out, so the reconciler (`Ravix.Previews.Reconciler`) can
  pick up after a restart from the database alone. The preview gateway,
  which runs before there is a signed-in caller and lives in `lib/ravix_web/`,
  reaches the questions it needs (`assert_open/1`, `info/1`, `touch/1`,
  `destination/1`, `start_service/1`) through the delegates `Ravix.Previews`
  keeps for it.
  """

  alias Ravix.Clock
  alias Ravix.MachineCache.Machine
  alias Ravix.Previews
  alias Ravix.Previews.{Row, Server, Store, View}
  alias Ravix.Projects.Project
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Sprites
  alias Ravix.Sprites.Tunnel
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.Track

  @probe_ms 3_000

  # ── who is watching ──────────────────────────────────────────────────

  @doc """
  The PubSub topic a track's preview changes go out on.

  One per track, on `Ravix.PubSub`, so a page on any instance hears a change
  that another instance's server made (ADR 0003). Subscribing is
  `Ravix.Previews.subscribe/2`, which establishes access first.
  """
  @spec topic(String.t()) :: String.t()
  def topic(track_id), do: "preview:" <> track_id

  @doc """
  Tell whoever follows a track's preview that its row changed, once the
  change has committed.

  The message is `{:preview, track_id}` and carries nothing else: what the
  preview now says is read back through `Ravix.Previews.status/2`, which asks
  the reader's access again. A page whose session ended or whose membership
  went a second ago learns nothing from the message itself.
  """
  @spec publish(String.t()) :: :ok
  def publish(track_id),
    do: Phoenix.PubSub.broadcast(Ravix.PubSub, topic(track_id), {:preview, track_id})

  # ── what is there ────────────────────────────────────────────────────

  @doc "A track's `PreviewInfo`, creating its (stopped) row on first sight."
  @spec info(String.t()) :: View.t()
  def info(track_id), do: track_id |> Store.ensure() |> present()

  @doc "`PreviewInfo` for a row: the track's override or the project default, and the row's state."
  @spec present(Row.t()) :: View.t()
  def present(%Row{} = row) do
    # ownership: the preview row names this track, and whoever handed it in
    # already decided about it -- the panel through `Access.track_access/2`,
    # the gateway by a grant `allowed?/2` re-checks on every request, the
    # server by the row it is carrying out. Read only to find the project
    # whose defaults apply.
    track = Tracks.get_track(row.track_id)

    defaults =
      case track do
        %Track{project_id: project_id} -> Store.defaults(project_id)
        nil -> nil
      end

    config = row.config || defaults
    running_config = if row.desired == :running, do: Row.applied(row) || config, else: config
    why = unavailable_for(running_config) || row.unavailable

    %View{
      available: why == nil,
      unavailable_reason: why,
      config: config,
      override: row.config,
      state: display_state(row, track),
      keeps_awake: keeps_awake?(row, config),
      error: row.error,
      logs: row.logs,
      url: preview_url(row, running_config, why)
    }
  end

  defp display_state(%Row{state: :ready} = row, _track),
    do: if(Row.plain?(row), do: :running, else: :ready)

  # A start on a machine the track row still calls asleep is a wake first
  # (`Ravix.Previews.open/3`), and the page says so rather than "starting":
  # the header reads the same row, so the two cannot disagree about it.
  defp display_state(%Row{state: :starting}, %Track{} = track),
    do: if(Ravix.Tracks.asleep?(track), do: :waking, else: :starting)

  defp display_state(row, _track), do: row.state

  defp keeps_awake?(%Row{desired: :running} = row, _config), do: Row.plain?(row)
  defp keeps_awake?(_row, config), do: match?(%{readiness_path: nil}, config)

  defp preview_url(row, %{readiness_path: path}, nil) when is_binary(path),
    do: Previews.origin(row)

  defp preview_url(_row, _config, _why), do: nil

  defp unavailable_for(%{readiness_path: nil}), do: Previews.run_unavailable()
  defp unavailable_for(_config), do: Previews.unavailable()

  @doc "The track and project behind an open, live preview; a conflict otherwise."
  @spec assert_open(String.t()) ::
          {:ok, %{track: Track.t(), project: Project.t()}} | {:error, Previews.reason()}
  def assert_open(track_id) do
    # ownership: no door before this one -- it is the door for the preview
    # flow. It answers whether there is a live track and project behind a
    # preview at all, and every caller goes on to check the person
    # separately (`Access.track_access/2`, or a grant bound to a session).
    track = Tracks.get_track(track_id)
    project = track && Projects.live_project(track.project_id)

    cond do
      track == nil or track.closed_at != nil -> closed()
      project == nil or project.archived_at != nil -> closed()
      match?(%Row{cleanup: true}, Store.get(track_id)) -> closed()
      true -> {:ok, %{track: track, project: project}}
    end
  end

  defp closed, do: {:error, {:conflict, "closed_track", "This track is closed or being retired."}}

  # ── lease, destination ───────────────────────────────────────────────

  @doc "Somebody is looking at the preview: renew the viewing lease."
  @spec touch(String.t()) :: :ok | {:error, Previews.reason()}
  def touch(track_id) do
    with {:ok, _} <- assert_open(track_id) do
      # The two fields this owns, and nothing else. It used to read the row
      # under `FOR UPDATE` and write all nineteen back, because the record
      # was one jsonb document and there was no way to write part of it; a
      # `publish_ready` that committed in between went back to `:starting`
      # and the gateway kept sending the reader to the start page. Now the
      # fields are columns and the update names them.
      now = Clock.now_ms()
      lease = now + Previews.lease_ms()

      if Store.update(track_id, last_activity: now, lease_until: lease) == 0 do
        # No row yet: make one, then set the lease on it.
        Store.ensure(track_id)
        Store.update(track_id, last_activity: now, lease_until: lease)
      end

      :ok
    end
  end

  @doc """
  The row the gateway may tunnel to, once the project's machine is up and
  is still the one the service was defined on. A machine that changed
  restarts the service in the background and refuses this request, so the
  browser opens the preview again once the replacement is ready.
  """
  @spec destination(String.t()) :: {:ok, Row.t()} | {:error, Previews.reason()}
  def destination(track_id) do
    with {:ok, %{track: track, project: project}} <- assert_open(track_id),
         {:ok, %Machine{sandbox_id: actual_sandbox}, actual_sprite} <- locate(project, track) do
      case Store.get(track_id) do
        %Row{sprite: ^actual_sprite, sandbox_id: ^actual_sandbox} = row -> {:ok, row}
        _ -> replaced(track_id)
      end
    end
  end

  # End existing connections and defer traffic until reconciliation has
  # retired the previous service and passed readiness on the replacement.
  defp replaced(track_id) do
    Task.Supervisor.start_child(
      Ravix.TaskSupervisor,
      Ravix.Trace.link(fn ->
        start_service(track_id, :restart)
      end)
    )

    {:error,
     {:unavailable, "preview_replaced",
      "The workspace changed. Open the preview again while its service restarts."}}
  end

  # The machine and the sprite in front of it: two answers from two calls,
  # so they are two values rather than a map that looks like a `Machine`
  # with a field `Machine` cannot have.
  defp locate(project, track) do
    case Ravix.Tracks.machine_of_track(project, track) do
      {:ok, %Machine{sandbox_id: sandbox_id} = machine} ->
        case Ravix.Tracks.sprite_for(sandbox_id) do
          sprite when is_binary(sprite) ->
            {:ok, machine, sprite}

          _ ->
            {:error, {:unavailable, "This workspace does not expose a Sprite."}}
        end

      {:ok, nil} ->
        {:error, {:conflict, "no_machine", "The workspace is not available."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── intent: start, stop, configure ───────────────────────────────────

  @doc """
  Start a track's service and wait until it is ready, failed, or superseded.

  `:restart` recreates the service rather than reusing one that is already
  defined and running. Runs for up to a minute; callers that answer a
  request start it in a task and read `info/1`.
  """
  @spec start_service(String.t(), Previews.start_mode()) :: :ok | {:error, Previews.reason()}
  def start_service(track_id, mode \\ :start) when mode in [:start, :restart] do
    with {:ok, {_outcome, generation}} <- begin(track_id, mode),
         do: carry_out(track_id, generation, mode)
  end

  @doc """
  Record the intent to run, and say whether this call started something.

  The first half of `start_service/2`, for a caller that answers somebody
  before the service is up: once this returns, `info/1` says `:starting`
  (or `:waking`), and whoever follows the track has been told.

  `:joined` means a start of this same generation is already under way ---
  a second click on Open, say --- and the caller should wait on that one
  rather than set another going. `:restart` never joins: it is asked for
  precisely because what is running should not be kept.
  """
  @spec begin(String.t(), Previews.start_mode()) ::
          {:ok, {:started | :joined, non_neg_integer()}} | {:error, Previews.reason()}
  def begin(track_id, mode \\ :start) when mode in [:start, :restart] do
    with {:ok, _} <- assert_open(track_id),
         nil <- unavailable_error(track_id),
         :ok <- touch(track_id) do
      {:ok, outcome} = Repo.transaction(fn -> want_running(track_id, mode) end)
      publish(track_id)
      {:ok, outcome}
    end
  end

  @doc """
  The second half of `start_service/2`: run the start `begin/2` recorded, and
  wait until it is ready, failed, or superseded. A start of the same
  generation already in flight is joined rather than queued behind.
  """
  @spec carry_out(String.t(), non_neg_integer(), Previews.start_mode()) ::
          :ok | {:error, Previews.reason()}
  def carry_out(track_id, generation, mode) when mode in [:start, :restart],
    do: Server.run(track_id, {:ensure_running, generation, mode})

  @doc """
  A start that could not get as far as the service --- the machine would not
  wake --- recorded as failed with its reason, if `generation` is still the
  one on record. Nothing retries it; the next open or run does.
  """
  @spec abandon(String.t(), non_neg_integer(), String.t()) :: :ok
  def abandon(track_id, generation, message) when is_binary(message) do
    # `Server.update/2` asks again inside its transaction; this only spares it
    # a row that has already moved on.
    case Store.get(track_id) do
      %Row{generation: ^generation} = row ->
        Server.update(row, state: :failed, desired: :stopped, error: message, lease_until: 0)

      _moved_on ->
        :ok
    end
  end

  # Inside a transaction: record the intent to run, under a new generation
  # unless it is already the intent, and return the generation on record
  # with whether a start of it is already under way.
  defp want_running(track_id, mode) do
    # Locked, so two clicks landing together cannot both see "not running
    # yet" and both start.
    Store.ensure(track_id)
    %Row{} = row = Store.lock(track_id)

    if mode == :restart or row.desired != :running do
      Store.save!(%Row{
        row
        | desired: :running,
          state: :starting,
          error: nil,
          unavailable: nil,
          stop_pending: false,
          generation: row.generation + 1,
          started_at: Clock.now_ms()
      })

      {:started, row.generation + 1}
    else
      {if(row.state == :starting, do: :joined, else: :started), row.generation}
    end
  end

  defp unavailable_error(track_id) do
    case unavailable_for(info(track_id).config) do
      nil -> nil
      why -> {:error, {:unavailable, why}}
    end
  end

  # The row to stop, or nil when the caller decided against a different one.
  defp stoppable(track_id, expected) do
    case Store.get(track_id) do
      %Row{generation: generation} = row when is_nil(expected) or generation == expected -> row
      _gone_or_moved_on -> nil
    end
  end

  defp mark_stopped(nil, _track_id, _mode), do: nil

  defp mark_stopped(%Row{} = row, track_id, mode) do
    Store.save!(%Row{
      row
      | desired: :stopped,
        state: :stopped,
        lease_until: 0,
        generation: row.generation + 1,
        cleanup: mode == :cleanup or row.cleanup,
        stop_pending: true
    })

    Store.revoke(track_id)
    Store.get(track_id)
  end

  @doc """
  Stop a track's service.

  `:cleanup` says the track is done for good: the agent grant goes, the
  service is deleted, and the port is released. A stop that cannot reach
  Sprites stays `stop_pending` for the reconciler.

  `expected` is the generation the caller decided against. The reconciler
  decides from a snapshot and can be queued behind a slow startup, so by the
  time it gets here somebody may have opened the preview again; stopping on
  the strength of the old snapshot would revoke the grants they were just
  issued and leave the page saying Stopped with no error. A generation that
  has moved means the decision was about a preview that no longer exists, so
  it is dropped. `nil` stops whatever is current.
  """
  @spec stop_service(String.t(), Previews.stop_mode(), non_neg_integer() | nil) ::
          :ok | {:error, Previews.reason()}
  def stop_service(track_id, mode \\ :stop, expected \\ nil) when mode in [:stop, :cleanup] do
    {:ok, current} =
      Repo.transaction(fn ->
        if mode == :cleanup, do: Store.revoke_agent(track_id)
        track_id |> stoppable(expected) |> mark_stopped(track_id, mode)
      end)

    if current, do: publish(track_id)

    case current do
      nil ->
        :ok

      row ->
        changes =
          [state: :stopped, error: nil, stop_pending: false] ++
            if(mode == :cleanup,
              do: [sprite: nil, sandbox_id: nil, port: nil, applied_config: nil],
              else: []
            )

        Server.run(track_id, {:retire, row, mode, changes})
    end
  end

  @doc "Save a track's configuration override (nil restores the project default). Stops the service."
  @spec configure(String.t(), Row.config() | nil) :: :ok | {:error, Previews.reason()}
  def configure(track_id, config) do
    with {:ok, _} <- assert_open(track_id) do
      {:ok, next} =
        Repo.transaction(fn ->
          %Row{} = row = Store.ensure(track_id)

          # The last start's failure was about the configuration being
          # replaced: "No run script configured" is not true once one is.
          next = %Row{
            row
            | config: config,
              desired: :stopped,
              state: :stopped,
              error: nil,
              generation: row.generation + 1,
              lease_until: 0,
              stop_pending: true
          }

          Store.save!(next)
          Store.revoke(track_id)
          next
        end)

      publish(track_id)

      Server.run(track_id, {:retire, next, :stop, [stop_pending: false]})
    end
  end

  @doc "Read the service's log tail into the row, when there is a running service to read."
  @spec refresh_logs(String.t()) :: :ok | {:error, Previews.reason()}
  def refresh_logs(track_id) do
    cfg = Sprites.config()

    case Store.get(track_id) do
      %Row{sprite: sprite, desired: :running} = row when is_binary(sprite) and cfg != nil ->
        with {:ok, current} <- destination(track_id),
             true <- current.sandbox_id == row.sandbox_id and current.sprite == sprite,
             {:ok, logs} <- Sprites.service_logs(cfg, sprite, row.service) do
          Server.update(row, logs: logs)
        else
          false -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  @doc """
  Does the app answer on its readiness path? One GET over the sprite
  tunnel with the preview's own Host, three seconds, any 2xx or 3xx.
  """
  @spec ready?(Row.t(), String.t()) :: boolean()
  def ready?(%Row{sprite: sprite, port: port} = row, path)
      when is_binary(sprite) and is_integer(port) do
    host =
      case Ravix.Config.previews() do
        nil -> row.hostname
        cfg -> "#{row.hostname}.#{cfg.domain}#{cfg.public_port}"
      end

    case Tunnel.open(Sprites.config(), sprite, port, timeout: @probe_ms) do
      {:ok, tunnel} -> probe(tunnel, path, host)
      _ -> false
    end
  end

  def ready?(_row, _path), do: false

  defp probe(tunnel, path, host) do
    case Tunnel.HTTP.request(tunnel, "GET", path, [{"host", host}], nil,
           headers_timeout: @probe_ms
         ) do
      {:ok, status, _headers, _body} -> status >= 200 and status < 400
      {:error, _} -> false
    end
  rescue
    _ -> false
  after
    Tunnel.close(tunnel)
  end

  # ── the wider world ──────────────────────────────────────────────────

  @doc "A project is being rebuilt or archived: remove every track's service (failures retry)."
  @spec retire_project(String.t()) :: :ok
  def retire_project(project_id) do
    # ownership: `Ravix.Projects.Machine.quiesce/1` is retiring this project
    # behind `Access.project_of/2` and asked for its previews to go with it;
    # naming its tracks, open or closed, is how they are found -- a preview
    # outlives its track being closed until something retires it.
    track_ids =
      project_id
      |> Tracks.tracks_of(:all)
      |> Enum.filter(&(&1.sandbox_layout == :shared))
      |> Enum.map(& &1.id)

    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      track_ids,
      Ravix.Trace.link_each(&stop_service(&1, :cleanup)),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end
end
