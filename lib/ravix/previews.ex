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

  The functions defined here take the signed-in user and go through
  `Ravix.Accounts.Access` first, apart from configuration (`unavailable/0`,
  `parse_config/1`, the timings) and the gateway's section below, which runs
  before there is a signed-in caller: `origin/1`, `by_host/1`, `allowed?/2`
  and the delegates beside them. Naming those three here is what keeps that
  list from growing quietly. Row access with no user in hand is
  `Ravix.Previews.Store`; the service's id-only lifecycle (start, stop,
  configure, retire, and the questions the gateway asks) is
  `Ravix.Previews.Lifecycle`, and a context calling either says which door
  it already went through.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Analytics
  alias Ravix.Clock
  alias Ravix.Crypto
  alias Ravix.Previews.{Agent, Config, Grant, Lifecycle, Row, Server, Store, View}
  alias Ravix.Redact
  alias Ravix.Sprites
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.Track

  @lease_ms 90_000
  @idle_ms 5 * 60_000
  @ticket_ms 60_000

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

  @typedoc """
  Whether a start reuses the service already defined for this track or
  recreates it. A word rather than a flag, because `start_service(id, true)`
  said nothing at the call site about which of the two it meant.
  """
  @type start_mode :: :start | :restart

  @typedoc """
  Whether a stop leaves the service defined for the next start, or tears the
  track's preview down for good --- the grant, the service and the port.
  """
  @type stop_mode :: :stop | :cleanup

  @typedoc """
  Whether reading a grant also spends it; see `Ravix.Previews.Store`.

  Named again here because the gateway reads grants and lives in
  `lib/ravix_web/`, where `Ravix.Credo.Architecture` refuses a store --- and
  a typespec is a mention.
  """
  @type disposition :: Store.disposition()

  @typedoc """
  A browser grant; see `Ravix.Previews.Grant`.

  Named again here for the same reason as `disposition/0`: the gateway
  reads grants and lives in `lib/ravix_web/`, where a store may not be
  mentioned, and a typespec is a mention.
  """
  @type grant :: Grant.t()

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

  # ── the agent's helper ───────────────────────────────────────────────

  @doc "Install the preview helper for a delivered turn (`prepareAgentPreview`)."
  @spec prepare_agent_preview(map()) :: String.t()
  defdelegate prepare_agent_preview(prompt), to: Agent, as: :prepare

  @doc "The helper script the agent runs (`agentPreviewScript`)."
  @spec agent_preview_script(String.t(), String.t()) :: String.t()
  defdelegate agent_preview_script(url, token), to: Agent, as: :script

  # ── the preview gateway's questions ──────────────────────────────────
  #
  # `RavixWeb.PreviewGateway` runs before there is a signed-in caller: it has
  # a hostname, a cookie and a ticket, and works out from those whether the
  # browser holding them may be let through. So these take no user, and they
  # are here rather than in the gateway's adapter because the adapter is in
  # `lib/ravix_web/` and reaching the row layer -- `Store` or `Lifecycle` --
  # from there is the one thing `Ravix.Credo.Architecture` will not allow,
  # comment or no comment. The gateway asks a context; the context reads
  # the rows. Nothing in `lib/ravix/` calls these: a context goes to
  # `Lifecycle` or `Store` itself and says which door it came through.

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

  @doc "A browser grant by hash, consumed if asked. A ticket is single-use."
  @spec grant_by_hash(String.t(), String.t(), Grant.kind(), disposition()) :: grant() | nil
  defdelegate grant_by_hash(hash, track_id, kind, disposition), to: Store, as: :get_grant

  @doc "Record a browser grant against the session that opened it."
  @spec record_grant(grant()) :: :ok | {:error, Ecto.Changeset.t()}
  defdelegate record_grant(grant), to: Store, as: :grant

  @doc "The track and project behind an open, live preview; a conflict otherwise."
  @spec assert_open(String.t()) ::
          {:ok, %{track: Track.t(), project: Ravix.Projects.Project.t()}} | {:error, reason()}
  defdelegate assert_open(track_id), to: Lifecycle

  @doc "A track's `PreviewInfo`, creating its (stopped) row on first sight."
  @spec info(String.t()) :: View.t()
  defdelegate info(track_id), to: Lifecycle

  @doc "Somebody is looking at the preview: renew the viewing lease."
  @spec touch(String.t()) :: :ok | {:error, reason()}
  defdelegate touch(track_id), to: Lifecycle

  @doc "The row the gateway may tunnel to; see `Ravix.Previews.Lifecycle.destination/1`."
  @spec destination(String.t()) :: {:ok, Row.t()} | {:error, reason()}
  defdelegate destination(track_id), to: Lifecycle

  @doc "Start the service the gateway was asked for; see `Ravix.Previews.Lifecycle.start_service/2`."
  @spec start_service(String.t()) :: :ok | {:error, reason()}
  defdelegate start_service(track_id), to: Lifecycle

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
  @spec allowed?(Row.t(), grant()) :: boolean()
  def allowed?(%Row{} = row, %Grant{} = grant) do
    with %{} <- Store.get_grant(grant.hash, row.track_id, grant.kind, :peek),
         %{} = user <- Ravix.Accounts.session_user(grant.session_hash),
         {:ok, %{track: %{closed_at: nil}}} <- Access.track_access(user, row.track_id) do
      not match?(%Row{cleanup: true}, Store.get(row.track_id))
    else
      _ -> false
    end
  end

  # ── what the panel asks for ──────────────────────────────────────────

  @doc "The info for a track the user may see."
  @spec status(User.t(), String.t()) :: {:ok, View.t()} | {:error, reason()}
  def status(%User{} = user, track_id) do
    with {:ok, _track} <- open_track(user, track_id), do: {:ok, Lifecycle.info(track_id)}
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
    do: launch(user, track_id, session_hash, :start)

  @doc "As `open/3`, but tears the running service down first."
  @spec restart(User.t(), String.t(), String.t() | nil) :: {:ok, View.t()} | {:error, reason()}
  def restart(%User{} = user, track_id, session_hash),
    do: launch(user, track_id, session_hash, :restart)

  defp launch(user, track_id, session_hash, mode) do
    with {:ok, track} <- open_track(user, track_id),
         {:ok, url} <- mint_ticket(track_id, session_hash) do
      Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
        # `user` is captured deliberately. This page has already returned by the
        # time the service answers, so the outcome is only knowable here -- and
        # without carrying who asked, a failed preview would be an event with
        # nobody attached to it, which is the one thing `Analytics.track/3`
        # refuses to file.
        report(user, track, mode, Lifecycle.start_service(track_id, mode))
      end)

      {:ok, %View{Lifecycle.info(track_id) | open_url: url}}
    end
  end

  defp report(user, track, mode, outcome) do
    {event, extra} =
      case outcome do
        :ok -> {:preview_started, %{}}
        {:error, reason} -> {:preview_failed, %{"ravix.reason" => Redact.reason(reason)}}
      end

    Analytics.track(
      user,
      event,
      track
      |> Analytics.repo(nil)
      |> Map.merge(extra)
      |> Map.put("ravix.mode", mode)
    )
  end

  @doc "Stop the track's preview service."
  @spec stop(User.t(), String.t()) :: {:ok, View.t()} | {:error, reason()}
  def stop(%User{} = user, track_id) do
    with {:ok, _track} <- open_track(user, track_id),
         :ok <- Lifecycle.stop_service(track_id),
         do: {:ok, Lifecycle.info(track_id)}
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
         :ok <- Lifecycle.refresh_logs(track_id),
         do: {:ok, Lifecycle.info(track_id)}
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
         :ok <- Lifecycle.configure(track_id, parsed),
         do: {:ok, Lifecycle.info(track_id)}
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
               Store.grant(%Grant{
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

  @doc "The owner's defaults."
  @spec defaults(User.t(), String.t()) :: {:ok, Row.config() | nil} | {:error, reason()}
  def defaults(%User{} = user, project_id) do
    with {:ok, _project} <- Access.project_of(user, project_id),
         do: {:ok, Store.defaults(project_id)}
  end

  @doc """
  Save the owner's defaults (a raw map, or
  nil to clear) and stop every track that runs on them.
  """
  @spec set_defaults(User.t(), String.t(), map() | nil) ::
          {:ok, Row.config() | nil} | {:error, reason()}
  def set_defaults(%User{} = user, project_id, config) do
    with {:ok, _project} <- Access.project_of(user, project_id),
         {:ok, config} <- parse_config(config) do
      Store.set_defaults(project_id, config)

      # ownership: `set_defaults/3` opened with `Access.project_of/2` on this
      # project; these are the tracks the new default reaches, open or closed,
      # because a preview outlives its track being closed until something
      # retires it.
      affected =
        for %Track{id: track_id} <- Tracks.tracks_of(project_id, :all),
            match?(%Row{config: nil}, Store.get(track_id)),
            do: track_id

      Ravix.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(affected, &Lifecycle.stop_service/1,
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

      {:ok, Store.defaults(project_id)}
    end
  end

  # ── configuration ────────────────────────────────────────────────────

  @doc """
  A `Ravix.Previews.Config` out of user input, or the changeset saying which
  fields are wrong and why.

  Every field is checked, so a form with three bad boxes is corrected once
  rather than three times; `RavixWeb.Live.Form.refuse/2` puts each sentence
  on the input it belongs to. `nil` means "use the level below", which is a
  value rather than a refusal.

  Keys may be strings or atoms, `readiness_path` or `readinessPath`; see
  `Ravix.Previews.Config` for why both arrive.
  """
  @spec parse_config(term()) :: {:ok, Config.t() | nil} | {:error, Ecto.Changeset.t()}
  defdelegate parse_config(value), to: Config, as: :parse
end
