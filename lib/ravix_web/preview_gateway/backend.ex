defmodule RavixWeb.PreviewGateway.Backend do
  @moduledoc """
  Everything the gateway asks of the rest of Ravix.

  The TypeScript gateway reached into `ctx.db.previews`, `ctx.db`,
  `trackAccess` and the preview manager. Those are exactly the calls here,
  one callback each, so the gateway can be built and tested before the
  previews context exists and the context can implement them without
  knowing how the proxy works. `Ravix.Previews` provides the module and it is
  configured as `config :ravix, preview_backend: Ravix.Previews.Gateway`.

  Shapes the gateway reads (structs or maps, atom keys):

    * a preview row: `track_id`, `hostname`, `sprite`, `port`, `desired`
      (`:running | :stopped`), `state` (`:ready | :starting | :failed |
      :stopped`), `generation`
    * a grant: `hash`, `track_id`, `session_hash`, `expires` (ms), `kind`
      (`:ticket | :session`)
    * a track: `id`, `project_id`, `closed_at`
    * a user: `id`
  """

  @type row :: %{
          :track_id => String.t(),
          :hostname => String.t(),
          :sprite => String.t() | nil,
          :port => pos_integer() | nil,
          :desired => :running | :stopped,
          :state => atom(),
          :generation => integer(),
          optional(atom()) => term()
        }
  @type grant :: %{
          :hash => String.t(),
          :track_id => String.t(),
          :session_hash => String.t(),
          :expires => integer(),
          :kind => :ticket | :session,
          optional(atom()) => term()
        }
  @type track :: %{
          :id => String.t(),
          :project_id => String.t(),
          :closed_at => term(),
          optional(atom()) => term()
        }
  @type user :: %{:id => String.t(), optional(atom()) => term()}

  @typedoc """
  A refusal with an HTTP status. Anything else is a 502 (or, for
  `assert_open/1`, the 409 the TypeScript raised).
  """
  @type refusal ::
          %{:status => pos_integer(), :message => String.t(), optional(atom()) => term()} | term()

  @doc "The preview row for the first label of a preview host (`ctx.db.previews.byHost`)."
  @callback resolve_host(name :: String.t()) :: {:ok, row()} | :error

  @doc "Refuse a closed track, archived project or preview being retired (`manager.assertOpen`)."
  @callback assert_open(track_id :: String.t()) :: :ok | {:error, refusal()}

  @doc "The current row for a track, re-read to notice a new generation (`ctx.db.previews.get`)."
  @callback preview(track_id :: String.t()) :: row() | nil

  @doc "An unexpired grant, deleted on the way out when `consume?` (`ctx.db.previews.getGrant`)."
  @callback get_grant(
              hash :: String.t(),
              track_id :: String.t(),
              kind :: :ticket | :session,
              consume? :: boolean()
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
  @callback info(track_id :: String.t()) :: map()

  @doc "Someone is looking: extend the viewing lease (`manager.touch`)."
  @callback touch(track_id :: String.t()) :: :ok

  @doc "Start a stopped service; called in a supervised task (`manager.startService`)."
  @callback start_service(track_id :: String.t()) :: :ok | {:error, term()}

  @doc "Make sure the sprite is awake and the row names it (`manager.destination`)."
  @callback destination(track_id :: String.t()) :: {:ok, term()} | {:error, refusal()}

  @doc "`Ravix.Config.public_url/0`."
  @callback public_url() :: String.t()

  @doc "`Ravix.Config.previews/0`."
  @callback previews_config() :: Ravix.Config.previews() | nil

  @doc "`Ravix.Config.sprites/0`; the tunnel's credentials."
  @callback sprites_config() :: Ravix.Config.Sprites.t() | nil
end
