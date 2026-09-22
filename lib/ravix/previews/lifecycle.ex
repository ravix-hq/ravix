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

  # ── what is there ────────────────────────────────────────────────────

  @doc "A track's `PreviewInfo`, creating its (stopped) row on first sight."
  @spec info(String.t()) :: View.t()
  def info(track_id), do: track_id |> Store.ensure() |> present()

  @doc "`PreviewInfo` for a row: the track's override or the project default, and the row's state."
  @spec present(Row.t()) :: View.t()
  def present(%Row{} = row) do
    why = Previews.unavailable() || row.unavailable

    # ownership: the preview row names this track, and the caller reached
    # the row by resolving a preview it was already allowed onto. Read only
    # to find the project whose defaults apply.
    defaults =
      case Tracks.get_track(row.track_id) do
        %Track{project_id: project_id} -> Store.defaults(project_id)
        nil -> nil
      end

    %View{
      available: why == nil,
      unavailable_reason: why,
      config: row.config || defaults,
      override: row.config,
      state: row.state,
      error: row.error,
      logs: row.logs,
      url: if(why, do: nil, else: Previews.origin(row))
    }
  end

  @doc "The track and project behind an open, live preview; a conflict otherwise."
  @spec assert_open(String.t()) ::
          {:ok, %{track: Track.t(), project: Project.t()}} | {:error, Previews.reason()}
  def assert_open(track_id) do
    # ownership: this *is* the door for the preview flow -- it answers whether
    # there is a live track and project behind a preview at all, and every
    # caller of it goes on to check the person separately.
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
    with {:ok, %{project: project}} <- assert_open(track_id),
         {:ok, %Machine{sandbox_id: actual_sandbox}, actual_sprite} <- locate(project) do
      case Store.get(track_id) do
        %Row{sprite: ^actual_sprite, sandbox_id: ^actual_sandbox} = row -> {:ok, row}
        _ -> replaced(track_id)
      end
    end
  end

  # End existing connections and defer traffic until reconciliation has
  # retired the previous service and passed readiness on the replacement.
  defp replaced(track_id) do
    Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
      start_service(track_id, :restart)
    end)

    {:error,
     {:unavailable, "preview_replaced",
      "The workspace changed. Open the preview again while its service restarts."}}
  end

  # The machine and the sprite in front of it: two answers from two calls,
  # so they are two values rather than a map that looks like a `Machine`
  # with a field `Machine` cannot have.
  defp locate(project) do
    case Ravix.Tracks.machine_of(project) do
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
    with {:ok, _} <- assert_open(track_id),
         nil <- unavailable_error(),
         :ok <- touch(track_id) do
      {:ok, generation} = Repo.transaction(fn -> want_running(track_id, mode) end)
      Server.run(track_id, {:ensure_running, generation, mode})
    end
  end

  # Inside a transaction: record the intent to run, under a new generation
  # unless it is already the intent, and return the generation on record.
  defp want_running(track_id, mode) do
    %Row{} = row = Store.ensure(track_id)

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
    end

    Store.get(track_id).generation
  end

  defp unavailable_error do
    case Previews.unavailable() do
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

          next = %Row{
            row
            | config: config,
              applied_config: nil,
              desired: :stopped,
              state: :stopped,
              generation: row.generation + 1,
              lease_until: 0,
              stop_pending: true
          }

          Store.save!(next)
          Store.revoke(track_id)
          next
        end)

      Server.run(track_id, {:retire, next, :stop, [stop_pending: false]})
    end
  end

  @doc "Read the service's log tail into the row, when there is a running service to read."
  @spec refresh_logs(String.t()) :: :ok | {:error, Previews.reason()}
  def refresh_logs(track_id) do
    cfg = Sprites.config()

    case Store.get(track_id) do
      %Row{sprite: sprite, desired: :running} = row when is_binary(sprite) and cfg != nil ->
        with {:ok, logs} <- Sprites.service_logs(cfg, sprite, row.service) do
          Server.update(row, logs: logs)
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
    # ownership: the projects context is retiring this project and asked for
    # its previews to go with it; naming its tracks, open or closed, is how
    # they are found -- a preview outlives its track being closed until
    # something retires it.
    track_ids = project_id |> Tracks.tracks_of(:all) |> Enum.map(& &1.id)

    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(track_ids, &stop_service(&1, :cleanup),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end
end
