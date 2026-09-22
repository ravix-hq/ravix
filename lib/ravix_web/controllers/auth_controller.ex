defmodule RavixWeb.AuthController do
  @moduledoc """
  The HTTP around signing in: the routes a browser follows rather than a page
  renders, and the one page it renders.

      GET  /auth/github          begin sign-in; redirect to GitHub
      GET  /api/auth/callback    GitHub coming back, from either round trip
      GET  /api/auth/install     go and grant repository access
      POST /auth/signout
      GET  /j/:token             what an invite link opens
      POST /j/:token             take it

  `/api/auth/callback` keeps its exact path because it is the callback URL
  registered on the GitHub App. `Ravix.Accounts.Auth` decides what each
  request means; this module owns the cookies: the Phoenix session that
  carries the session token, and the per-attempt `ravix_oauth_<state>`
  cookie scoped to the callback path that binds a round trip to the browser
  that began it (see `server/oauth.ts`). Every answer is a redirect, because
  these URLs are opened by a browser following GitHub, not by a fetch.

  Failures a person can do something about are query strings on `/`
  (`?error=stale_signin`, `?error=github_declined`), which the landing page
  reads. A deployment with no GitHub App answers 503 in the words the
  TypeScript used, since there is nothing to send the browser to.
  """

  use RavixWeb, :controller

  alias Ravix.Accounts.Auth
  alias RavixWeb.Error
  alias RavixWeb.Plugs.CurrentUser

  # The context that owns invite links; see `claim_link/2` below.
  @people Ravix.People

  @doc "`GET /auth/github`: mint an attempt and send the browser to GitHub."
  @spec github(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def github(conn, _params) do
    with {:ok, attempt} <- Auth.begin(:signin, nil),
         {:ok, url} <- Auth.authorize_url(attempt.state) do
      conn
      |> put_attempt_cookie(attempt)
      |> redirect(external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
    end
  end

  @doc """
  `GET /api/auth/callback`: GitHub coming back, from either round trip.

  The attempt's cookie is read before and cleared after, whatever the
  outcome: a used state has no cookie to keep, and a stale one had none
  worth keeping.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    conn = fetch_cookies(conn)
    state = Map.get(params, "state")
    secret = if Auth.valid_state?(state), do: conn.req_cookies[Auth.cookie_name(state)]

    case Auth.callback(params, secret) do
      {:ok, %{token: token, redirect: to}} ->
        to =
          if map_size(RavixWeb.ToolingOAuthController.pending(conn)) > 0,
            do: "/oauth/authorize",
            else: to

        conn
        |> clear_attempt_cookie(state)
        |> configure_session(renew: true)
        |> put_session(CurrentUser.session_key(), token)
        |> redirect(to: to)

      {:redirect, to} ->
        conn |> clear_attempt_cookie(state) |> redirect(to: to)

      {:error, reason} ->
        conn |> clear_attempt_cookie(state) |> Error.send_json(reason)
    end
  end

  @doc """
  `GET /api/auth/install`: a signed-in person going to grant repository
  access, with a state so the return trip is recognisable.

  A redirect rather than a link the page builds, because the state has to
  be minted server-side and handing the browser a URL it did not ask for is
  how an installation ends up attributed to the wrong account.
  """
  @spec install(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def install(conn, _params) do
    with {:ok, _app} <- Auth.github(),
         {:ok, _user} <- CurrentUser.require_user(conn),
         {:ok, attempt} <- Auth.begin(:install, nil),
         {:ok, url} <- Auth.install_url(attempt.state) do
      conn
      |> put_attempt_cookie(attempt)
      |> redirect(external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
    end
  end

  @doc "`POST /auth/signout`: the row is gone, the session is dropped, the browser goes home."
  @spec signout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signout(conn, _params) do
    :ok = Auth.sign_out(get_session(conn, CurrentUser.session_key()))

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  @doc """
  `GET /j/:token`: ask whether to follow an invite link, of either kind.

  Somebody signed in is shown what the link opens and joins it with the form's
  POST. Somebody who is not goes to GitHub first with the token parked as the
  attempt's redirect, and comes back to this same page
  (`Ravix.Accounts.Auth.callback/2`). A link that is gone or was never real
  lands on `/?error=bad_invite`.

  **This route makes no change of its own, and must not.** It used to claim the
  membership here: `protect_from_forgery` covers only non-GET requests and
  `SameSite=Lax` permits top-level navigation, so any page a signed-in person
  visited could send them to an invite link and have it taken silently (#16).
  What an attacker got was a project of their own composition sitting in
  somebody else's rail -- an in-app phishing surface on a trusted origin --
  rather than access to anything of the victim's, which is why this was rated
  low and fixed rather than embargoed.
  """
  @spec join(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def join(conn, %{"token" => token}) do
    case conn.assigns[:current_user] do
      nil ->
        with {:ok, attempt} <- Auth.begin(:join, token),
             {:ok, url} <- Auth.authorize_url(attempt.state) do
          conn
          |> put_attempt_cookie(attempt)
          |> put_status(:see_other)
          |> redirect(external: url)
        else
          {:error, reason} -> Error.send_json(conn, reason)
        end

      user ->
        case link_target(token, user) do
          {:ok, target} -> render(conn, :confirm, target: target, token: token)
          :error -> conn |> put_status(:see_other) |> redirect(to: "/?error=bad_invite")
        end
    end
  end

  @doc """
  `POST /j/:token`: take the invite.

  The membership is written here and nowhere else, behind
  `protect_from_forgery`. A signed-out post is somebody whose session went away
  while the page was open; send them round the sign-in trip rather than losing
  the link.
  """
  @spec claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim(conn, %{"token" => token}) do
    case conn.assigns[:current_user] do
      nil ->
        join(conn, %{"token" => token})

      user ->
        to =
          case claim_link(user.id, token) do
            {:ok, path} -> path
            _ -> "/?error=bad_invite"
          end

        conn |> put_status(:see_other) |> redirect(to: to)
    end
  end

  # `Ravix.People` is built alongside this controller; named through an
  # attribute so this compiles without it, in which case no link can be read
  # and none can be claimed.
  defp claim_link(user_id, token) do
    if people_exports?(:claim_link, 2), do: @people.claim_link(user_id, token), else: :error
  end

  defp link_target(token, user) do
    if people_exports?(:link_target, 2), do: @people.link_target(token, user), else: :error
  end

  defp people_exports?(fun, arity),
    do: Code.ensure_loaded?(@people) and function_exported?(@people, fun, arity)

  # ── the attempt cookie ─────────────────────────────────────────────

  defp put_attempt_cookie(conn, %{state: state, secret: secret}) do
    put_resp_cookie(conn, Auth.cookie_name(state), secret, Auth.cookie_options(https?(conn)))
  end

  defp clear_attempt_cookie(conn, state) do
    if Auth.valid_state?(state) do
      opts = conn |> https?() |> Auth.cookie_options() |> Keyword.delete(:max_age)
      delete_resp_cookie(conn, Auth.cookie_name(state), opts)
    else
      conn
    end
  end

  # Behind Render's proxy the scheme arrives as a header; locally it is the
  # connection's own.
  defp https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [proto | _] -> proto |> String.split(",") |> hd() |> String.trim() == "https"
      [] -> conn.scheme == :https
    end
  end
end
