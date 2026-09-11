defmodule RavixWeb.PreviewGateway.Backend do
  @moduledoc """
  Everything the gateway asks of the rest of Ravix.

  The TypeScript gateway reached into `ctx.db.previews`, `ctx.db`,
  `trackAccess` and the preview manager. Those are exactly the calls here,
  one callback each, so the gateway can be built and tested without the
  previews context and the context can implement them without knowing how
  the proxy works. `RavixWeb.PreviewGateway.RavixBackend` provides the
  module and it is configured as
  `config :ravix, preview_backend: RavixWeb.PreviewGateway.RavixBackend`.

  ## Why a port at all

  Because of what it keeps out of the test, not because of what it lets in.
  `test/ravix_web/preview_gateway_test.exs` stands up a real Bandit front,
  a real upstream app, real Mint clients and a real WebSocket relay, and
  runs `async: true` against no database. That is a proxy-machinery suite,
  and giving it rows would make it a database suite that happens to proxy.

  What the port does *not* buy is looser shapes. The callback types below
  were `%{... optional(atom()) => term()}` maps --- structural typing,
  wide enough that a fake could answer with a map literal and a struct
  would satisfy the same spec. That undid the `@enforce_keys` work
  everywhere else and had a known cost in this repository: a stub that
  answers with a map literal hides the template bug that only browser
  smoke then finds.

  So the shapes here are the production structs. The fake builds
  `%Ravix.Previews.Row{}`, `%Ravix.Tracks.Track{}` and
  `%Ravix.Accounts.User{}` --- none of which needs a database, only a
  `Repo` call does --- and a field added to one of them reaches the fake as
  a compile error or a missing key rather than as a `nil` the gateway reads
  as "not ready".
  """

  @typedoc "A track's preview record. `Ravix.Previews.Row`."
  @type row :: Ravix.Previews.Row.t()

  @typedoc "A browser or agent grant, as `Ravix.Previews.grant/0` names it for this side."
  @type grant :: Ravix.Previews.grant()

  @typedoc "The track the preview belongs to. `Ravix.Tracks.Track`."
  @type track :: Ravix.Tracks.Track.t()

  @typedoc "The signed-in person. `Ravix.Accounts.User`."
  @type user :: Ravix.Accounts.User.t()

  @typedoc """
  A refusal with an HTTP status. Anything else is a 502 (or, for
  `assert_open/1`, the 409 the TypeScript raised).
  """
  @type refusal :: RavixWeb.Error.t() | term()

  @doc "The preview row for the first label of a preview host (`ctx.db.previews.byHost`)."
  @callback resolve_host(name :: String.t()) :: {:ok, row()} | :error

  @doc "Refuse a closed track, archived project or preview being retired (`manager.assertOpen`)."
  @callback assert_open(track_id :: String.t()) :: :ok | {:error, refusal()}

  @doc "The current row for a track, re-read to notice a new generation (`ctx.db.previews.get`)."
  @callback preview(track_id :: String.t()) :: row() | nil

  @doc "An unexpired grant, deleted on the way out when `:consume` (`ctx.db.previews.getGrant`)."
  @callback get_grant(
              hash :: String.t(),
              track_id :: String.t(),
              kind :: :ticket | :session,
              disposition :: Ravix.Previews.disposition()
            ) ::
              grant() | nil

  @doc "The user behind an unexpired Ravix session (`ctx.db.sessionUser`)."
  @callback session_user(session_hash :: String.t()) :: user() | nil

  @doc "The track if the user may see it (`trackAccess`); `{:error, :not_found}` otherwise."
  @callback track_access(user(), track_id :: String.t()) :: {:ok, track()} | {:error, term()}

  @doc """
  Whether a session grant still stands: the grant exists, its Ravix session
  is alive, that user still has access to an open track, and the preview is
  not being cleaned up. Checked on every request and, for open streams, on
  every project event and every second.
  """
  @callback allowed?(row(), grant()) :: boolean()

  @doc "The track a row belongs to (`ctx.db.track`)."
  @callback track(track_id :: String.t()) :: track() | nil

  @doc "Store a session grant minted from a ticket (`ctx.db.previews.grant`)."
  @callback grant_session(grant()) :: :ok | {:error, term()}

  @doc "The status page's JSON (`manager.info`)."
  @callback info(track_id :: String.t()) :: Ravix.Previews.View.t()

  @doc "Someone is looking: extend the viewing lease (`manager.touch`)."
  @callback touch(track_id :: String.t()) :: :ok

  @doc "Start a stopped service; called in a supervised task (`manager.startService`)."
  @callback start_service(track_id :: String.t()) :: :ok | {:error, term()}

  @doc "Make sure the sprite is awake and the row names it (`manager.destination`)."
  @callback destination(track_id :: String.t()) :: {:ok, row()} | {:error, refusal()}

  @doc "`Ravix.Config.public_url/0`."
  @callback public_url() :: String.t()

  @doc "`Ravix.Config.previews/0`."
  @callback previews_config() :: Ravix.Config.Previews.t() | nil

  @doc "`Ravix.Config.sprites/0`; the tunnel's credentials."
  @callback sprites_config() :: Ravix.Config.Sprites.t() | nil
end
