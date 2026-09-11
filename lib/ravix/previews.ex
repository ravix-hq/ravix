defmodule Ravix.Previews do
  @moduledoc """
  Track previews: one private HTTP service per track, inside its sprite.

  A preview is a Sprites service running the track's app on a port the
  track holds, reached only through the gateway (`RavixWeb.PreviewGateway`)
  on the track's own hostname under `PREVIEW_DOMAIN`. This context is the
  `Previews` class of `server/previews.ts` and its routes: what the track
  page asks (status, open, restart, stop, logs, configure), what the
  project settings ask (defaults), what the gateway asks (assert open, the
  destination, touch), and what the tracks and projects contexts ask when a
  track closes or a project is rebuilt (retire everything, save what fails
  for retry).

  The rules the README states:

    * A viewer holds a ninety-second lease, refreshed by the page's
      heartbeat; while it is held the reconciler keeps the sprite's activity
      task alive. Five minutes without activity stops the service.
    * Failed startup stops automatic retries until another open or restart.
    * Browser access is a one-minute single-use ticket exchanged for a
      twelve-hour session grant, revoked with the membership.
    * Closing a track, rebuilding or archiving a project removes its
      services; failed cleanup is saved for retry.

  Every operation that changes intent is written to the row here, before
  the per-track `Ravix.Previews.Server` carries it out, so the reconciler
  (`Ravix.Previews.Reconciler`) can pick up after a restart from the
  database alone.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Crypto
  alias Ravix.Previews.{Agent, Clock, Row, Server, Store, View}
  alias Ravix.Projects.Project
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Sprites
  alias Ravix.Sprites.Tunnel
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.Track

  @lease_ms 90_000
  @idle_ms 5 * 60_000
  @ticket_ms 60_000
  @probe_ms 3_000

  @typedoc """
  Everything a preview call can refuse with, and nothing else.

  It ended in `| term()` until this was written out, which is why
  `:preview_server_down` reached people as "Something went wrong on the Ravix
  server" for as long as it did: nothing could say the sentence was missing.
  """
  @type reason ::
          :not_found
          | :preview_server_down
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t()}
          | {:unavailable, String.t(), String.t()}

  @doc "The lease a heartbeat renews, in milliseconds."
  @spec lease_ms() :: pos_integer()
  def lease_ms, do: @lease_ms

  @doc "How long without activity before a running preview is stopped."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms

  @doc """
  The supervision tree the previews need, for `Ravix.Application`.

  The reconciler is wrapped: its pass is "never twice for one track", which on
  more than one instance means it has to run on exactly one of them (ADR 0003).
  Every instance starts the watcher; one of them ends up starting the tick.
  """
  @spec child_specs() :: [{module(), keyword()} | module()]
  def child_specs do
    Server.child_specs() ++
      [{Ravix.Cluster.Singleton, key: "previews.reconciler", child: Ravix.Previews.Reconciler}]
  end

  # ── availability and presentation ────────────────────────────────────

  @doc "Why previews cannot run on this deployment, or nil when they can."
  @spec unavailable() :: String.t() | nil
  def unavailable do
    cond do
      Sprites.config() == nil ->
        "Previews unavailable: SPRITES_TOKEN is not configured."

      Ravix.Config.previews() == nil ->
        "Previews unavailable: PREVIEW_DOMAIN and gateway routing are not configured."

      Ravix.Config.fountain().key == nil ->
        "Previews unavailable: Fountain is not configured."

      true ->
        nil
    end
  end

  @doc "The browser origin of a preview row, or nil when `PREVIEW_DOMAIN` is unset."
  @spec origin(Row.t()) :: String.t() | nil
  def origin(%Row{hostname: hostname}) do
    case Ravix.Config.previews() do
      nil ->
        nil

      %{protocol: protocol, domain: domain, public_port: port} ->
        "#{protocol}://#{hostname}.#{domain}#{port}"
    end
  end

  @doc "A track's `PreviewInfo`, creating its (stopped) row on first sight."
  @spec info(String.t()) :: View.t()
  def info(track_id), do: track_id |> Store.ensure() |> present()

  @doc "`PreviewInfo` for a row: the track's override or the project default, and the row's state."
  @spec present(Row.t()) :: View.t()
  def present(%Row{} = row) do
    why = unavailable() || row.unavailable

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
      url: if(why, do: nil, else: origin(row))
    }
  end

  @doc "The track and project behind an open, live preview; a conflict otherwise."
  @spec assert_open(String.t()) ::
          {:ok, %{track: Track.t(), project: Project.t()}} | {:error, reason()}
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
  @spec touch(String.t()) :: :ok | {:error, reason()}
  def touch(track_id) do
    with {:ok, _} <- assert_open(track_id) do
      Repo.transaction(fn ->
        # Merge the two fields this owns onto a locked read rather than
        # writing back the whole row it saw. Every other writer already works
        # this way; writing the read-in row wholesale meant a `publish_ready`
        # that committed in between was reverted to `:starting`, and the
        # gateway kept sending the reader back to the start page.
        %Row{} = row = Store.ensure(track_id)
        %Row{} = fresh = Store.lock(track_id) || row
        now = Clock.now_ms()
        Store.save!(%Row{fresh | last_activity: now, lease_until: now + @lease_ms})
      end)

      :ok
    end
  end

  @doc """
  The row the gateway may tunnel to, once the project's machine is up and
  is still the one the service was defined on. A machine that changed
  restarts the service in the background and refuses this request, so the
  browser opens the preview again once the replacement is ready.
  """
  @spec destination(String.t()) :: {:ok, Row.t()} | {:error, reason()}
  def destination(track_id) do
    with {:ok, %{project: project}} <- assert_open(track_id),
         {:ok, actual} <- locate(project) do
      case Store.get(track_id) do
        %Row{sprite: sprite, sandbox_id: sandbox_id} = row
        when sprite == actual.sprite and sandbox_id == actual.sandbox_id ->
          {:ok, row}

        _ ->
          replaced(track_id)
      end
    end
  end

  # End existing connections and defer traffic until reconciliation has
  # retired the previous service and passed readiness on the replacement.
  defp replaced(track_id) do
    Task.Supervisor.start_child(Ravix.TaskSupervisor, fn -> start_service(track_id, true) end)

    {:error,
     {:unavailable, "preview_replaced",
      "The workspace changed. Open the preview again while its service restarts."}}
  end

  defp locate(project) do
    case Ravix.Tracks.machine_of(project) do
      {:ok, %{sandbox_id: sandbox_id}} ->
        case Ravix.Tracks.sprite_for(sandbox_id) do
          sprite when is_binary(sprite) ->
            {:ok, %{sandbox_id: sandbox_id, sprite: sprite}}

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
  Start (or with `restart?`, recreate) a track's service and wait until it
  is ready, failed, or superseded. Runs for up to a minute; callers that
  answer a request start it in a task and read `info/1`.
  """
  @spec start_service(String.t(), boolean()) :: :ok | {:error, reason()}
  def start_service(track_id, restart? \\ false) do
    with {:ok, _} <- assert_open(track_id),
         nil <- unavailable_error(),
         :ok <- touch(track_id) do
      {:ok, generation} = Repo.transaction(fn -> want_running(track_id, restart?) end)
      Server.run(track_id, {:ensure_running, generation, restart?})
    end
  end

  # Inside a transaction: record the intent to run, under a new generation
  # unless it is already the intent, and return the generation on record.
  defp want_running(track_id, restart?) do
    %Row{} = row = Store.ensure(track_id)

    if restart? or row.desired != :running do
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
    case unavailable() do
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

  defp mark_stopped(nil, _track_id, _cleanup?), do: nil

  defp mark_stopped(%Row{} = row, track_id, cleanup?) do
    Store.save!(%Row{
      row
      | desired: :stopped,
        state: :stopped,
        lease_until: 0,
        generation: row.generation + 1,
        cleanup: cleanup? or row.cleanup,
        stop_pending: true
    })

    Store.revoke(track_id)
    Store.get(track_id)
  end

  @doc """
  Stop a track's service. With `cleanup?`, the track is done for good: the
  agent grant goes, the service is deleted, and the port is released. A
  stop that cannot reach Sprites stays `stop_pending` for the reconciler.

  `expected` is the generation the caller decided against. The reconciler
  decides from a snapshot and can be queued behind a slow startup, so by the
  time it gets here somebody may have opened the preview again; stopping on
  the strength of the old snapshot would revoke the grants they were just
  issued and leave the page saying Stopped with no error. A generation that
  has moved means the decision was about a preview that no longer exists, so
  it is dropped. `nil` stops whatever is current.
  """
  @spec stop_service(String.t(), boolean(), non_neg_integer() | nil) :: :ok | {:error, reason()}
  def stop_service(track_id, cleanup? \\ false, expected \\ nil) do
    {:ok, current} =
      Repo.transaction(fn ->
        if cleanup?, do: Store.revoke_agent(track_id)
        track_id |> stoppable(expected) |> mark_stopped(track_id, cleanup?)
      end)

    case current do
      nil ->
        :ok

      row ->
        changes =
          [state: :stopped, error: nil, stop_pending: false] ++
            if(cleanup?,
              do: [sprite: nil, sandbox_id: nil, port: nil, applied_config: nil],
              else: []
            )

        Server.run(track_id, {:retire, row, cleanup?, changes})
    end
  end

  @doc "Save a track's configuration override (nil restores the project default). Stops the service."
  @spec configure(String.t(), Row.config() | nil) :: :ok | {:error, reason()}
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

      Server.run(track_id, {:retire, next, false, [stop_pending: false]})
    end
  end

  @doc "Read the service's log tail into the row, when there is a running service to read."
  @spec refresh_logs(String.t()) :: :ok | {:error, reason()}
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
    # its previews to go with it; naming its tracks is how they are found.
    track_ids = track_ids_of(project_id)

    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(track_ids, &stop_service(&1, true),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  @doc "Drop a track's browser grants (one user's, or everyone's)."
  @spec revoke(String.t(), String.t() | nil) :: :ok
  def revoke(track_id, user_id \\ nil), do: Store.revoke(track_id, user_id)

  @doc "Drop a track's agent grant (one user's, or whoever holds it)."
  @spec revoke_agent(String.t(), String.t() | nil) :: :ok
  def revoke_agent(track_id, user_id \\ nil), do: Store.revoke_agent(track_id, user_id)

  @doc "Install the preview helper for a delivered turn (`prepareAgentPreview`)."
  @spec prepare_agent_preview(map()) :: String.t()
  defdelegate prepare_agent_preview(prompt), to: Agent, as: :prepare

  @doc "The helper script the agent runs (`agentPreviewScript`)."
  @spec agent_preview_script(String.t(), String.t()) :: String.t()
  defdelegate agent_preview_script(url, token), to: Agent, as: :script

  # Every track of a project, open or closed: a preview outlives the track
  # being closed until something retires it, so both halves matter here.
  #
  # ownership: both callers established the project first -- `retire_project/1`
  # is the projects context asking, and `set_defaults/3` went through
  # `Access.project_of/2`.
  defp track_ids_of(project_id) do
    project_id |> Tracks.tracks_of(true) |> Enum.map(& &1.id)
  end

  # ── the preview gateway's questions ──────────────────────────────────
  #
  # `RavixWeb.PreviewGateway` runs before there is a signed-in caller: it has
  # a hostname, a cookie and a ticket, and works out from those whether the
  # browser holding them may be let through. So these take no user, and they
  # are here rather than in the gateway's adapter because the adapter is in
  # `lib/ravix_web/` and reaching the row layer from there is the one thing
  # `Ravix.Credo.Architecture` will not allow, comment or no comment. The
  # gateway asks a context; the context reads the rows.

  @doc "The preview a hostname belongs to, or `:error` for a name that is not one of ours."
  @spec by_host(String.t()) :: {:ok, Row.t()} | :error
  def by_host(name) do
    case Store.by_host(name) do
      %Row{} = row -> {:ok, row}
      nil -> :error
    end
  end

  @doc "The preview row for a track, without ensuring one exists."
  @spec row(String.t()) :: Row.t() | nil
  defdelegate row(track_id), to: Store, as: :get

  @doc "A browser or agent grant by hash, consumed if asked. A ticket is single-use."
  @spec grant_by_hash(String.t(), String.t(), atom(), boolean()) :: map() | nil
  defdelegate grant_by_hash(hash, track_id, kind, consume?), to: Store, as: :get_grant

  @doc "Record a browser grant against the session that opened it."
  @spec record_grant(map()) :: :ok | {:error, Ecto.Changeset.t()}
  defdelegate record_grant(grant), to: Store, as: :grant

  @doc """
  The track a preview belongs to, for the back-link the gateway renders.

  Unscoped on purpose, and safely: the caller reached it by resolving a
  preview hostname it was already allowed onto, and the two fields read from
  it are the ids that build a URL back to the track.
  """
  # ownership: `RavixWeb.PreviewGateway` has already put this request through
  # `allowed?/2` above, which re-asks `Access.track_access/2` for the person
  # holding the grant. This read only names the track that answer was about.
  @spec track(String.t()) :: Track.t() | nil
  defdelegate track(track_id), to: Ravix.Tracks.Store, as: :get_track

  @doc """
  Whether a grant still admits its holder.

  Four things have to hold at once, and they are re-asked on every request
  rather than trusted from the one that minted the grant: the grant exists,
  the Ravix session behind it is alive, that person still has access to the
  track, the track is open, and the preview is not being torn down. A
  membership revoked a second ago closes the preview a second later.
  """
  @spec allowed?(Row.t(), map()) :: boolean()
  def allowed?(%Row{} = row, grant) do
    with %{} <- Store.get_grant(grant.hash, row.track_id, grant.kind, false),
         %{} = user <- Ravix.Accounts.session_user(grant.session_hash),
         {:ok, %{track: %{closed_at: nil}}} <- Access.track_access(user, row.track_id) do
      not match?(%Row{cleanup: true}, Store.get(row.track_id))
    else
      _ -> false
    end
  end

  # ── the routes ───────────────────────────────────────────────────────

  @doc "`GET /api/tracks/:id/preview`: the info for a track the user may see."
  @spec status(User.t(), String.t()) :: {:ok, View.t()} | {:error, reason()}
  def status(%User{} = user, track_id) do
    with {:ok, _track} <- open_track(user, track_id), do: {:ok, info(track_id)}
  end

  @doc """
  Start the track's preview and mint the caller a way in.

  The service starts in the background, because bringing an app up on a cold
  machine takes longer than a click should: the caller gets the info and the
  `open_url` straight away, and the page watches the row for readiness. The
  URL is a one-minute ticket for `session_hash`, the caller's own Ravix
  session, so a link that leaks is a link that has already expired.
  """
  @spec open(User.t(), String.t(), String.t() | nil) :: {:ok, View.t()} | {:error, reason()}
  def open(%User{} = user, track_id, session_hash),
    do: launch(user, track_id, session_hash, false)

  @doc "As `open/3`, but tears the running service down first."
  @spec restart(User.t(), String.t(), String.t() | nil) :: {:ok, View.t()} | {:error, reason()}
  def restart(%User{} = user, track_id, session_hash),
    do: launch(user, track_id, session_hash, true)

  defp launch(user, track_id, session_hash, restart?) do
    with {:ok, _track} <- open_track(user, track_id),
         {:ok, url} <- mint_ticket(track_id, session_hash) do
      Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
        start_service(track_id, restart?)
      end)

      {:ok, %View{info(track_id) | open_url: url}}
    end
  end

  @doc "Stop the track's preview service."
  @spec stop(User.t(), String.t()) :: {:ok, View.t()} | {:error, reason()}
  def stop(%User{} = user, track_id) do
    with {:ok, _track} <- open_track(user, track_id),
         :ok <- stop_service(track_id),
         do: {:ok, info(track_id)}
  end

  @doc """
  Re-read the service's log tail.

  Persisted failure logs remain available without waking an idle machine, so
  this answers for a stopped preview too -- with what it last said, which is
  the thing somebody pressing Logs after a crash is asking for.
  """
  @spec logs(User.t(), String.t()) :: {:ok, View.t()} | {:error, reason()}
  def logs(%User{} = user, track_id) do
    with {:ok, _track} <- open_track(user, track_id),
         :ok <- refresh_logs(track_id),
         do: {:ok, info(track_id)}
  end

  @doc """
  Save the track's configuration override, or `nil` to restore the project
  default. Stops the service, since what it was running is no longer what
  the track asks for.
  """
  @spec save_config(User.t(), String.t(), term()) :: {:ok, View.t()} | {:error, reason()}
  def save_config(%User{} = user, track_id, config) do
    with {:ok, _track} <- open_track(user, track_id),
         {:ok, parsed} <- parse_config(config),
         :ok <- configure(track_id, parsed),
         do: {:ok, info(track_id)}
  end

  @doc """
  A one-minute, single-use ticket for the caller's session, as the URL the
  browser opens: `/__ravix/open#<ticket>` on the preview's origin.
  """
  @spec open_ticket(User.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def open_ticket(%User{} = user, track_id, session_hash) do
    with {:ok, _track} <- open_track(user, track_id), do: mint_ticket(track_id, session_hash)
  end

  defp mint_ticket(_track_id, nil),
    do: {:error, {:unprocessable, "session", "Open preview controls from a signed-in session."}}

  defp mint_ticket(track_id, session_hash) do
    row = Store.ensure(track_id)

    case origin(row) do
      nil ->
        {:error, {:unavailable, "PREVIEW_DOMAIN is not configured."}}

      origin ->
        ticket = Crypto.random_token()

        with :ok <-
               Store.grant(%{
                 hash: Crypto.sha256(ticket),
                 track_id: track_id,
                 session_hash: session_hash,
                 expires: Clock.now_ms() + @ticket_ms,
                 kind: :ticket
               }) do
          {:ok, "#{origin}/__ravix/open##{ticket}"}
        end
    end
  end

  defp open_track(user, track_id) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id) do
      if track.closed_at,
        do: {:error, {:conflict, "closed_track", "This track is closed."}},
        else: {:ok, track}
    end
  end

  @doc "`GET /api/projects/:id/preview`: the owner's defaults."
  @spec defaults(User.t(), String.t()) :: {:ok, Row.config() | nil} | {:error, reason()}
  def defaults(%User{} = user, project_id) do
    with {:ok, _project} <- Access.project_of(user, project_id),
         do: {:ok, Store.defaults(project_id)}
  end

  @doc """
  `PUT /api/projects/:id/preview`: save the owner's defaults (a raw map, or
  nil to clear) and stop every track that runs on them.
  """
  @spec set_defaults(User.t(), String.t(), map() | nil) ::
          {:ok, Row.config() | nil} | {:error, reason()}
  def set_defaults(%User{} = user, project_id, config) do
    with {:ok, _project} <- Access.project_of(user, project_id),
         {:ok, config} <- parse_config(config) do
      Store.set_defaults(project_id, config)

      # ownership: `set_defaults/3` opened with `Access.project_of/2` on this
      # project; these are the tracks the new default reaches.
      affected =
        for track_id <- track_ids_of(project_id),
            not match?(%Row{config: %{}}, Store.get(track_id)),
            do: track_id

      Ravix.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(affected, &stop_service/1,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      {:ok, Store.defaults(project_id)}
    end
  end

  # ── configuration ────────────────────────────────────────────────────

  @doc """
  A `PreviewConfig` out of user input (`parsePreviewConfig`): a relative
  directory inside the track, a non-empty command, and an HTTP path for
  readiness. Keys may be strings or atoms, `readiness_path` or
  `readinessPath`. Nil means "use the project default".
  """
  @spec parse_config(term()) :: {:ok, Row.config() | nil} | {:error, reason()}
  def parse_config(nil), do: {:ok, nil}

  def parse_config(%{} = value) do
    value = Row.normalize_keys(value)
    directory = value["directory"]
    command = value["command"]
    path = value["readiness_path"]

    cond do
      not valid_directory?(directory) ->
        unprocessable("preview_directory", "Choose a relative app directory inside this track.")

      not valid_command?(command) ->
        unprocessable(
          "preview_command",
          "Supply a startup command that honors $PORT and fails if that port is occupied."
        )

      not valid_path?(path) ->
        unprocessable(
          "preview_readiness",
          "Readiness must be an HTTP path on this app, such as /health."
        )

      true ->
        directory = String.trim(directory)

        {:ok,
         %{
           directory: if(directory == "", do: ".", else: directory),
           command: String.trim(command),
           readiness_path: path
         }}
    end
  end

  def parse_config(_other), do: unprocessable("preview_config", "Supply a preview configuration.")

  defp unprocessable(code, message), do: {:error, {:unprocessable, code, message}}

  defp valid_directory?(directory) do
    is_binary(directory) and String.length(directory) <= 1000 and
      not String.starts_with?(directory, "/") and
      ".." not in String.split(directory, "/") and
      not Regex.match?(~r/[\x00-\x1f]/, directory)
  end

  defp valid_command?(command) do
    is_binary(command) and String.trim(command) != "" and String.length(command) <= 8000 and
      not String.contains?(command, <<0>>)
  end

  defp valid_path?(path) do
    is_binary(path) and String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      String.length(path) <= 1000 and not Regex.match?(~r/[\x00-\x20#\\]/, path)
  end
end
