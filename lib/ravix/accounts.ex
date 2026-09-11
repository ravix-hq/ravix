defmodule Ravix.Accounts do
  @moduledoc """
  People, and the two short-lived things that prove one is here.

  Fountain owns the truth about machines and conversations; this database
  owns the truth about people. Three tables: who signed in (`users`), which
  browsers are signed in as them (`sessions`, stored as SHA-256 hashes of the
  cookie token so a copy of the database is not a set of live sessions), and
  the one-use states the two GitHub round trips are keyed on
  (`oauth_states`).

  This is the port of the users, sessions and oauth_states half of
  `server/db.ts` plus `session` from `server/auth.ts`. The doors (who may
  touch which project or track) live in `Ravix.Accounts.Access`; the sign-in
  round trips in `Ravix.Accounts.Auth`.
  """

  import Ecto.Query

  alias Ravix.Accounts.{Capabilities, OAuthState, Session, SessionInfo, User, Viewer}
  alias Ravix.{Config, Crypto, GitHub, Repo}

  @typedoc "The signed-in person as the shell sees them; see `Ravix.Accounts.Viewer`."
  @type viewer :: Viewer.t()

  @typedoc "What this deployment can do; see `Ravix.Accounts.Capabilities`."
  @type capabilities :: Capabilities.t()

  @typedoc "What the shell needs before its first render; see `Ravix.Accounts.SessionInfo`."
  @type session_info :: SessionInfo.t()

  # How long a minted OAuth state is good for, in seconds. Fifteen minutes is
  # long enough to read GitHub's consent screen twice and short enough that a
  # state lifted from a log is not worth much.
  @state_max_age_s 15 * 60

  # ── users ────────────────────────────────────────────────────────────

  @doc """
  The user for a GitHub profile: created on first sign-in, refreshed after.

  Keyed on GitHub's numeric id, never the login: logins are renameable, and a
  login freed by a deleted account can be taken by somebody else. `login`,
  `name`, `avatar_url` and the encrypted token are overwritten on every
  sign-in and `last_seen_at` is bumped.
  """
  @spec upsert_user(%{
          required(:github_id) => String.t(),
          required(:login) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil,
          required(:token_enc) => String.t()
        }) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_user(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.take([:github_id, :login, :name, :avatar_url, :token_enc])
      |> Map.put(:last_seen_at, now)

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:login, :name, :avatar_url, :token_enc, :last_seen_at]},
      conflict_target: :github_id,
      returning: true
    )
  end

  @doc "A user by id, or nil."
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  @doc """
  A user by GitHub login, case-insensitively, or nil.

  Nil for an *ambiguous* login as much as an unknown one, and the difference
  is worth naming. `login` has no unique index and cannot have one: GitHub
  frees a name the moment somebody renames, and a row here is allowed to be
  stale until they next sign in, so a stale `dana` and the new owner of
  `dana` can both exist. Both callers are consequential -- one grants access
  to a track, the other takes it away -- and answering either with a guess is
  how "remove @dana" silently revokes the wrong account. The invite path
  falls through to GitHub, which answers by numeric id; the removal path
  refuses rather than picking.
  """
  @spec user_by_login(String.t()) :: User.t() | nil
  def user_by_login(login) when is_binary(login) do
    lowered = String.downcase(login)

    case Repo.all(from u in User, where: fragment("lower(?)", u.login) == ^lowered, limit: 2) do
      [%User{} = user] -> user
      _none_or_ambiguous -> nil
    end
  end

  @doc """
  People who have signed in here whose login or name contains `q`, for the
  invite box. Never the caller.

  This does mean the box will tell you who has signed in here, which is a
  trade this deployment has accepted. Confirming one login at a time is the
  whole of that trade, so the term's own `%` and `_` are escaped rather than
  left live: `People.search/2` refuses an empty query precisely so nobody can
  ask for the whole userbase, and a bare `%` walked straight past it into
  `ILIKE '%%%'`, which matches every row. Ordered so a prefix match beats a
  contains match, because somebody typing `ana` means `ana` before `joana`.
  """
  @spec search_users(String.t(), String.t(), pos_integer()) :: [User.t()]
  def search_users(q, exclude_user_id, limit \\ 8) do
    escaped = escape_like(q)
    like = "%#{escaped}%"
    prefix = "#{escaped}%"

    Repo.all(
      from u in User,
        where: u.id != ^exclude_user_id and (ilike(u.login, ^like) or ilike(u.name, ^like)),
        order_by: [
          asc: fragment("CASE WHEN ? ILIKE ? THEN 0 ELSE 1 END", u.login, ^prefix),
          asc: u.login
        ],
        limit: ^limit
    )
  end

  # `\\` first, or it would escape the escapes added after it.
  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  The user's GitHub OAuth token, decrypted. Used for anything read as *them*.

  `{:error, :no_token}` for a row with nothing stored or a ciphertext this
  deployment's secret did not write; either way the person signs in again.
  """
  @spec user_token(User.t()) :: {:ok, String.t()} | {:error, :no_token}
  def user_token(%User{token_enc: nil}), do: {:error, :no_token}

  def user_token(%User{token_enc: enc}) do
    case Crypto.decrypt(enc) do
      {:ok, plain} -> {:ok, plain}
      {:error, _} -> {:error, :no_token}
    end
  end

  # ── sessions ─────────────────────────────────────────────────────────

  @doc "A session row for `user_id`, keyed on the token's hash, expiring `max_age_ms` from now."
  @spec create_session(String.t(), String.t(), pos_integer()) :: :ok
  def create_session(user_id, token_hash, max_age_ms) do
    now = DateTime.utc_now()

    %Session{}
    |> Session.changeset(%{
      token_hash: token_hash,
      user_id: user_id,
      created_at: now,
      expires_at: DateTime.add(now, max_age_ms, :millisecond)
    })
    |> Repo.insert!()

    :ok
  end

  @doc """
  The user a session token hash belongs to, or nil.

  An expired row is deleted on the read that finds it, so the table never
  needs a sweeper and a stale cookie is refused exactly once.
  """
  @spec session_user(String.t()) :: User.t() | nil
  def session_user(token_hash) do
    case open_session(token_hash) do
      {:ok, user, _expires_at} -> user
      :error -> nil
    end
  end

  @doc """
  The same read, keeping the moment the session runs out.

  For a caller that will be asked "is this still signed in?" many times over
  and does not want to read the row for each: a session's expiry is a fact
  about the row that does not change once it is written, so a caller holding
  it can answer from the clock. What the clock cannot tell it is that the
  row was *deleted* -- signing out -- which is what `subscribe/1` is for.
  """
  @spec open_session(String.t()) :: {:ok, User.t(), DateTime.t()} | :error
  def open_session(token_hash) when is_binary(token_hash) do
    with %Session{} = session <- Repo.get(Session, token_hash),
         %Session{} = session <- live_session(session),
         %User{} = user <- get_user(session.user_id) do
      {:ok, user, session.expires_at}
    else
      _ -> :error
    end
  end

  def open_session(_), do: :error

  # An expired row is deleted on the read that finds it, so the table never
  # needs a sweeper and a stale cookie is refused exactly once.
  defp live_session(%Session{} = session) do
    if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt do
      session
    else
      Repo.delete_all(from s in Session, where: s.token_hash == ^session.token_hash)
      nil
    end
  end

  @doc "The topic a session's own end is announced on."
  @spec session_topic(String.t()) :: String.t()
  def session_topic(token_hash), do: "session:" <> token_hash

  @doc """
  Hear about this session ending, as `{:session_ended, token_hash}`.

  A page holding an answer about a session needs telling when the answer
  stops being true. Expiry it can see coming, because it is a time; being
  signed out somewhere else it cannot, so `end_session/1` says so.

  Best-effort, as everything on PubSub is, and so not the only thing
  standing between a signed-out browser and the page: a subscriber still
  re-reads on its own schedule. What this buys is that the usual case --
  somebody signing out in the next tab -- takes effect at once rather than
  whenever that schedule next comes round.
  """
  @spec subscribe_session(String.t()) :: :ok | {:error, term()}
  def subscribe_session(token_hash),
    do: Phoenix.PubSub.subscribe(Ravix.PubSub, session_topic(token_hash))

  @doc "Sign a browser out: the row is gone, whatever the cookie still says."
  @spec end_session(String.t()) :: :ok
  def end_session(token_hash) do
    Repo.delete_all(from s in Session, where: s.token_hash == ^token_hash)

    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      session_topic(token_hash),
      {:session_ended, token_hash}
    )

    :ok
  end

  # ── the two GitHub round trips ───────────────────────────────────────

  @doc """
  Park a state for a round trip: which kind (`:signin`, `:install`, `:join`)
  and where to land afterwards. States older than fifteen minutes are swept
  on every write, so the table stays the size of the last quarter hour.
  """
  @spec put_state(String.t(), OAuthState.kind(), String.t() | nil) :: :ok
  def put_state(state, kind, redirect) do
    cutoff = DateTime.add(DateTime.utc_now(), -@state_max_age_s, :second)
    Repo.delete_all(from s in OAuthState, where: s.created_at < ^cutoff)

    %OAuthState{}
    |> OAuthState.changeset(%{
      state: state,
      kind: kind,
      redirect: redirect,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:kind, :redirect, :created_at]},
      conflict_target: :state
    )

    :ok
  end

  @doc "Takes the state: one use only, which is what makes a replayed callback fail."
  @spec take_state(String.t()) :: %{kind: OAuthState.kind(), redirect: String.t() | nil} | nil
  def take_state(state) when is_binary(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@state_max_age_s, :second)

    case Repo.delete_all(from s in OAuthState, where: s.state == ^state, select: s) do
      {1, [%OAuthState{} = row]} ->
        if DateTime.compare(row.created_at, cutoff) == :lt,
          do: nil,
          else: %{kind: row.kind, redirect: row.redirect}

      _ ->
        nil
    end
  end

  def take_state(_), do: nil

  # ── what the shell needs before it renders ───────────────────────────

  @doc """
  `SessionInfo`: who is here, where to sign in, and what works on this
  deployment.

  One value rather than three (who am I, may I sign in, what works here)
  because the answer to all three changes together and a shell that renders
  from two of them has a frame where it disagrees with itself.

  `sign_in_url` is this server's `/auth/github`, not GitHub's authorize URL
  as the TypeScript returned: the state and its browser cookie are minted by
  the controller on that request, which is the one place a LiveView page
  cannot set a cookie from. `install_url` is GitHub's, as before.
  `viewer.has_installation` is asked live rather than stored, because it is
  a fact about GitHub that changes without telling us: somebody installs the
  App in another tab, or an admin removes it. A cached `true` here is a
  repository picker that renders empty with no explanation.
  """
  @spec session_info(User.t() | nil) :: session_info()
  def session_info(user_or_nil) do
    app = Config.github()

    %SessionInfo{
      viewer: viewer_of(user_or_nil, app),
      sign_in_url: if(app, do: "/auth/github", else: ""),
      install_url: if(app, do: GitHub.install_url(app), else: ""),
      capabilities: capabilities()
    }
  end

  @doc "What is switched on here, decided by the server's environment rather than by a build flag."
  @spec capabilities() :: capabilities()
  def capabilities do
    %Capabilities{
      exec: Config.sprites() != nil,
      github: Config.github() != nil,
      # Settled by configuration rather than probed per request: a Fountain
      # that does vaults today does them at midnight too.
      vaults: Config.fountain().key != nil
    }
  end

  defp viewer_of(nil, _app), do: nil

  defp viewer_of(%User{} = user, app) do
    %Viewer{
      id: user.github_id,
      login: user.login,
      name: user.name,
      avatar_url: user.avatar_url,
      has_installation: has_installation?(user, app)
    }
  end

  defp has_installation?(_user, nil), do: false

  defp has_installation?(%User{} = user, app) do
    with {:ok, token} <- user_token(user),
         {:ok, list} <- GitHub.installations_for(app, token) do
      list != []
    else
      # A revoked or expired user token. Not fatal to the session: the shell
      # shows the install prompt, and the first real call re-authenticates.
      _ -> false
    end
  end
end
