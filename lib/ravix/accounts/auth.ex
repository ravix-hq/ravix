defmodule Ravix.Accounts.Auth do
  @moduledoc """
  Signing in, which here is two round trips to GitHub rather than one.

  **Authorize** gets an identity: who you are, and a token that speaks as
  you. **Install** gets access: which repositories ravix may see. They are
  separate on purpose and in that order, because the second one is a
  decision a person makes about their code and it should be made by somebody
  the app can already name.

  A person can be signed in with no installation. That is not a broken state
  and the UI does not treat it as one: it is the state everybody is in for
  the ten seconds between the two, and the state anybody who declines stays
  in. `viewer.has_installation` is how the shell knows which of the two home
  screens to render.

  Every attempt is keyed twice. The URL carries a `state`; the database row
  is keyed on `sha256(state <> ":" <> secret)` where `secret` lives only in a
  cookie the browser that started the attempt holds, scoped to the callback
  path. One cookie per attempt lets sign-in and invite links coexist in
  several tabs, and a callback copied into another browser cannot replace
  its session: without the secret, the state is never found and the code is
  never exchanged. That is the whole of `server/oauth.ts`.

  This module is `server/auth.ts` and `server/oauth.ts` without the HTTP:
  `RavixWeb.AuthController` sets and reads the cookies and the session and
  performs the redirects these functions decide on.
  """

  alias Ravix.Accounts
  alias Ravix.Accounts.User
  alias Ravix.{Config, Crypto, GitHub}
  alias Ravix.GitHub.Error, as: GitHubError

  @typedoc "A round trip begun: the state for the URL, the secret for the cookie."
  @type attempt :: %{state: String.t(), secret: String.t()}

  @typedoc "What the callback settled: a session to create, or only somewhere to send the browser."
  @type outcome ::
          {:ok,
           %{
             token: String.t(),
             user: User.t(),
             redirect: String.t(),
             joined: %{tracks: [map()], projects: [map()]}
           }}
          | {:redirect, String.t()}
          | {:error, {:unavailable, String.t()} | term()}

  @no_github "This Ravix deployment has no GitHub App configured, so it cannot see repositories."

  # How long the per-attempt cookie lives, in seconds. Matches the state row.
  @cookie_max_age_s 15 * 60

  # The context that owns invitations and links; see `claim_invites/2` below.
  @people Ravix.People

  @doc "Where GitHub sends a browser back to. Registered on the App; must match exactly."
  @spec callback_url() :: String.t()
  def callback_url, do: Config.public_url() <> "/api/auth/callback"

  @doc "The GitHub App, or the refusal that says what is missing."
  @spec github() :: {:ok, Config.GitHubApp.t()} | {:error, {:unavailable, String.t()}}
  def github do
    case Config.github() do
      nil -> {:error, {:unavailable, @no_github}}
      app -> {:ok, app}
    end
  end

  @doc """
  Begin a round trip of `kind` (`"signin"`, `"install"`, `"join"`) that
  lands at `redirect` afterwards (a link token for `join`, nil otherwise).

  Stores the row and returns the state for the URL and the secret the
  controller puts in the attempt's cookie (see `cookie_name/1`).
  """
  @spec begin(String.t(), String.t() | nil) ::
          {:ok, attempt()} | {:error, {:unavailable, String.t()}}
  def begin(kind, redirect) do
    with {:ok, _app} <- github() do
      state = Crypto.random_token(18)
      secret = Crypto.random_token()
      :ok = Accounts.put_state(state_key(state, secret), kind, redirect)
      {:ok, %{state: state, secret: secret}}
    end
  end

  @doc "The cookie that binds an attempt to the browser that began it."
  @spec cookie_name(String.t()) :: String.t()
  def cookie_name(state), do: "ravix_oauth_" <> state

  @doc "The options every attempt cookie is set and cleared with; the path is the callback's."
  @spec cookie_options(boolean()) :: keyword()
  def cookie_options(https?) do
    [
      path: "/api/auth/callback",
      http_only: true,
      same_site: "Lax",
      max_age: @cookie_max_age_s,
      secure: https?
    ]
  end

  @doc "Whether `state` is one this server minted: 18 random bytes as base64url."
  @spec valid_state?(term()) :: boolean()
  def valid_state?(state) when is_binary(state), do: Regex.match?(~r/^[A-Za-z0-9_-]{24}$/, state)
  def valid_state?(_), do: false

  @doc "Where a browser goes to sign in, carrying `state`."
  @spec authorize_url(String.t()) :: {:ok, String.t()} | {:error, {:unavailable, String.t()}}
  def authorize_url(state) do
    with {:ok, app} <- github(), do: {:ok, GitHub.authorize_url(app, callback_url(), state)}
  end

  @doc "Where a browser goes to install the App, carrying `state` so the return trip is recognisable."
  @spec install_url(String.t() | nil) :: {:ok, String.t()} | {:error, {:unavailable, String.t()}}
  def install_url(state) do
    with {:ok, app} <- github(), do: {:ok, GitHub.install_url(app, state)}
  end

  @doc """
  GitHub coming back, from either round trip.

  Both land here. The sign-in flow arrives with `code` and our `state`; the
  installation flow arrives with `installation_id` and `setup_action` and,
  because the App's setup URL is this same path, sometimes with a `code` as
  well. Handling them in one place is what makes "install, then sign in" and
  "sign in, then install" both end at the same screen.

  `params` is the query as GitHub sent it; `browser_secret` is the value of
  this attempt's cookie, or nil when the browser did not have one. The
  answer is either a session to create with where to send it, or a redirect
  with no session:

    * no `code`: `/?installed=1` when an installation was granted, else
      `/?error=github_declined`;
    * a state the cookie does not unlock, already used, or expired:
      `/?error=stale_signin`;
    * GitHub refusing the exchange: `/?error=github_<status>`.

  On success: the user is upserted with the token encrypted, invitations
  waiting on their GitHub id become memberships (`Ravix.People.claim_invites/2`),
  and the redirect is where that points. A `join` trip lands back on its invite
  page rather than through it -- an invitation addressed to your GitHub id is
  one somebody sent *you*, but a link is a credential whoever holds it can be
  navigated into, so taking it stays a separate, explicit POST (#16).
  """
  @spec callback(map(), String.t() | nil) :: outcome()
  def callback(params, browser_secret) do
    with {:ok, app} <- github() do
      settle(app, param(params, "code"), param(params, "state"), browser_secret, params)
    end
  end

  # An installation with no code: the person was already signed in and just
  # granted repository access. Nothing to exchange; send them back in.
  defp settle(_app, nil, _state, _secret, params) do
    if param(params, "installation_id"),
      do: {:redirect, "/?installed=1"},
      else: {:redirect, "/?error=github_declined"}
  end

  # Require the initiating browser's secret before consuming the one-use
  # state. A callback copied into another browser cannot replace its session.
  defp settle(app, code, state, secret, params) do
    case take(state, secret) do
      nil -> {:redirect, "/?error=stale_signin"}
      parked -> exchange(app, code, parked, param(params, "installation_id"))
    end
  end

  @doc "End the session a token names. Idempotent."
  @spec sign_out(String.t() | nil) :: :ok
  def sign_out(nil), do: :ok
  def sign_out(token) when is_binary(token), do: Accounts.end_session(Crypto.sha256(token))

  # ── the pieces ───────────────────────────────────────────────────────

  defp take(state, secret) when is_binary(secret) and secret != "" do
    if valid_state?(state), do: Accounts.take_state(state_key(state, secret)), else: nil
  end

  defp take(_state, _secret), do: nil

  defp exchange(app, code, parked, installation_id) do
    with {:ok, token} <- GitHub.exchange_code(app, code, callback_url()),
         {:ok, profile} <- GitHub.viewer(app, token) do
      establish(token, profile, parked, installation_id)
    else
      {:error, %GitHubError{status: status}} ->
        {:redirect, "/?error=" <> URI.encode_www_form("github_#{status || 0}")}

      {:error, :unconfigured} ->
        {:error, {:unavailable, @no_github}}
    end
  end

  defp establish(token, profile, parked, installation_id) do
    github_id = to_string(profile.id)

    with {:ok, user} <-
           Accounts.upsert_user(%{
             github_id: github_id,
             login: profile.login,
             name: profile.name,
             avatar_url: profile.avatar_url,
             token_enc: Crypto.encrypt(token)
           }) do
      session_token = Crypto.random_token()

      :ok =
        Accounts.create_session(
          user.id,
          Crypto.sha256(session_token),
          Config.session_max_age_ms()
        )

      # Anything that was waiting for this person becomes real on the sign-in
      # that proves who they are, and not before. Two sources: invitations
      # sent to their GitHub account before they had one here, and the link
      # that sent them to GitHub in the first place.
      joined = claim_invites(user.id, github_id)
      redirect = landing(parked, joined, user.id, installation_id)
      {:ok, %{token: session_token, user: user, redirect: redirect, joined: joined}}
    end
  end

  # Back to the invite, not into it. Signing in through a link used to claim it
  # on the way past, which made the sign-in and the joining one act that nobody
  # was asked about separately; now both routes end on the same page, and the
  # membership is only ever written by its POST (#16).
  defp landing(%{kind: "join", redirect: link}, _joined, _user_id, _installation_id)
       when is_binary(link) do
    "/j/" <> link
  end

  # One invitation is worth landing on; several is a decision, so the rail is
  # the better place to make it. A project counts as one thing to arrive at
  # even when it brought several tracks with it, and it wins over a track:
  # whoever sent it meant the machine rather than a branch of it.
  defp landing(_parked, %{projects: [project], tracks: []}, _user_id, _installation_id),
    do: "/p/#{project.id}"

  defp landing(_parked, %{projects: [], tracks: [track]}, _user_id, _installation_id),
    do: "/p/#{track.project_id}/t/#{track.id}"

  defp landing(_parked, _joined, _user_id, installation_id),
    do: if(installation_id, do: "/?installed=1", else: "/")

  # `Ravix.People` is another context, built alongside this one. It is named
  # through an attribute (a dynamic call the compiler does not resolve) and
  # only called when it is loaded, so this module compiles and the callback
  # still completes on a tree without it; the result then is simply that
  # nothing was waiting for this person.
  defp claim_invites(user_id, github_id) do
    if people_exports?(:claim_invites, 2),
      do: @people.claim_invites(user_id, github_id),
      else: %{tracks: [], projects: []}
  end

  defp people_exports?(fun, arity),
    do: Code.ensure_loaded?(@people) and function_exported?(@people, fun, arity)

  defp state_key(state, secret), do: Crypto.sha256(state <> ":" <> secret)

  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
