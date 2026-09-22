defmodule RavixWeb.AuthControllerTest do
  use RavixWeb.ConnCase, async: true
  use Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.{Auth, Session}
  alias Ravix.Crypto
  alias Ravix.GitHubFake, as: Fake
  alias Ravix.Repo
  alias RavixWeb.Live.Hooks
  alias RavixWeb.Plugs.CurrentUser

  # The one sentence for a deployment with no GitHub App lives in
  # `RavixWeb.Error`; the controller answers it under its stable code.
  @no_github RavixWeb.Error.from({:unconfigured, :github}).message

  setup do
    app = Fake.app()
    stub(Ravix.Config, :github, fn -> app end)
    stub(Ravix.Config, :public_url, fn -> "https://ravix.test" end)
    %{app: app}
  end

  defp github_signs_in do
    Fake.install([
      {"POST", "/login/oauth/access_token", %{access_token: "oauth-token"}},
      {"GET", "/user", %{id: 3, login: "new-user", name: nil, avatar_url: ""}}
    ])
  end

  defp state_of(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  # Begin a sign-in as a fresh browser: the state GitHub will echo back, and
  # the attempt cookie that browser now holds.
  defp signin(conn) do
    response = get(conn, "/auth/github")
    location = redirected_to(response, 302)
    state = state_of(location)
    cookie = response.resp_cookies[Auth.cookie_name(state)]
    %{state: state, cookie: cookie, path: "/api/auth/callback?state=#{state}&code=code"}
  end

  # ── GET /auth/github ─────────────────────────────────────────────────

  describe "GET /auth/github" do
    test "sends the browser to GitHub with a state, and binds the attempt to a cookie", %{
      conn: conn
    } do
      response = get(conn, "/auth/github")
      location = redirected_to(response, 302)
      assert String.starts_with?(location, "https://github.test/login/oauth/authorize?")
      state = state_of(location)
      assert Auth.valid_state?(state)
      assert location =~ URI.encode_www_form("https://ravix.test/api/auth/callback")

      assert %{value: secret, path: "/api/auth/callback", http_only: true, max_age: 900} =
               cookie = response.resp_cookies["ravix_oauth_" <> state]

      assert cookie[:same_site] == "Lax"
      refute cookie[:secure]
      assert %{kind: :signin} = Accounts.take_state(Crypto.sha256("#{state}:#{secret}"))
    end

    test "the cookie is Secure behind a TLS-terminating proxy", %{conn: conn} do
      response = conn |> put_req_header("x-forwarded-proto", "https") |> get("/auth/github")
      state = response |> redirected_to() |> state_of()
      assert %{secure: true} = response.resp_cookies["ravix_oauth_" <> state]
    end

    test "is a 503 in the TypeScript's words when there is no GitHub App", %{conn: conn} do
      stub(Ravix.Config, :github, fn -> nil end)
      response = get(conn, "/auth/github")
      assert json_response(response, 503) == %{"error" => "no_github", "message" => @no_github}
    end
  end

  # ── GET /api/auth/callback ───────────────────────────────────────────

  describe "GET /api/auth/callback" do
    test "requires its own browser secret and rejects replay", %{conn: conn} do
      github_signs_in()
      mine = signin(conn)
      other = signin(build_conn())

      for cookie <- [nil, other.cookie, %{mine.cookie | value: "wrong"}] do
        request =
          if cookie,
            do: put_req_cookie(build_conn(), Auth.cookie_name(mine.state), cookie.value),
            else: build_conn()

        response = get(request, mine.path)
        assert redirected_to(response) == "/?error=stale_signin"
        assert get_session(response, :session_token) == nil
      end

      assert Fake.request_count("/login/oauth/access_token") == 0

      success =
        build_conn()
        |> put_req_cookie(Auth.cookie_name(mine.state), mine.cookie.value)
        |> get(mine.path)

      assert redirected_to(success) == "/"
      assert token = get_session(success, :session_token)
      assert Accounts.session_user(Crypto.sha256(token)).login == "new-user"
      # The attempt's cookie is cleared on the way out.
      assert %{max_age: 0, path: "/api/auth/callback"} =
               success.resp_cookies[Auth.cookie_name(mine.state)]

      replay =
        build_conn()
        |> put_req_cookie(Auth.cookie_name(mine.state), mine.cookie.value)
        |> get(mine.path)

      assert redirected_to(replay) == "/?error=stale_signin"
      assert get_session(replay, :session_token) == nil
      assert Fake.request_count("/login/oauth/access_token") == 1
    end

    test "independent tabs can finish sign-in in either order", %{conn: conn} do
      github_signs_in()
      first = signin(conn)
      second = signin(build_conn())

      for attempt <- [second, first] do
        response =
          build_conn()
          |> put_req_cookie(Auth.cookie_name(first.state), first.cookie.value)
          |> put_req_cookie(Auth.cookie_name(second.state), second.cookie.value)
          |> get(attempt.path)

        assert redirected_to(response) == "/"
        assert get_session(response, :session_token)
      end

      assert Fake.request_count("/login/oauth/access_token") == 2
    end

    test "the signed-in browser is recognised by the plug on its next request", %{conn: conn} do
      github_signs_in()
      mine = signin(conn)

      signed_in =
        build_conn()
        |> put_req_cookie(Auth.cookie_name(mine.state), mine.cookie.value)
        |> get(mine.path)

      # A follow-up request from the same browser (recycled cookies) is authenticated:
      # `/api/auth/install` needs a person and answers with a redirect to GitHub.
      response = signed_in |> recycle() |> get("/api/auth/install")
      assert redirected_to(response) =~ "https://github.test/apps/test/installations/new?state="
    end

    test "GitHub declining, or an installation with nothing to exchange", %{conn: conn} do
      assert redirected_to(get(conn, "/api/auth/callback")) == "/?error=github_declined"

      assert redirected_to(get(conn, "/api/auth/callback?installation_id=9&setup_action=install")) ==
               "/?installed=1"
    end

    test "answers 503 when there is no GitHub App", %{conn: conn} do
      stub(Ravix.Config, :github, fn -> nil end)
      response = get(conn, "/api/auth/callback?code=c&state=s")
      assert %{"error" => "no_github"} = json_response(response, 503)
    end
  end

  # ── GET /api/auth/install ────────────────────────────────────────────

  describe "GET /api/auth/install" do
    test "a signed-in person goes to GitHub with a state and a bound cookie", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      response = get(conn, "/api/auth/install")
      location = redirected_to(response, 302)

      assert String.starts_with?(
               location,
               "https://github.test/apps/test/installations/new?state="
             )

      state = state_of(location)

      assert %{value: secret, path: "/api/auth/callback"} =
               response.resp_cookies["ravix_oauth_" <> state]

      assert %{kind: :install} = Accounts.take_state(Crypto.sha256("#{state}:#{secret}"))
    end

    test "a stranger is told to sign in", %{conn: conn} do
      response = get(conn, "/api/auth/install")

      assert json_response(response, 401) == %{
               "error" => "unauthenticated",
               "message" => "Sign in with GitHub."
             }
    end

    test "a session that has ended says so", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      :ok = Accounts.end_session(Crypto.sha256(get_session(conn, :session_token)))
      response = get(conn, "/api/auth/install")

      assert %{
               "error" => "unauthenticated",
               "message" => "That session has ended. Sign in again."
             } =
               json_response(response, 401)
    end

    test "is a 503 without a GitHub App, before asking who is here", %{conn: conn} do
      stub(Ravix.Config, :github, fn -> nil end)
      assert %{"error" => "no_github"} = json_response(get(conn, "/api/auth/install"), 503)
    end
  end

  # ── POST /auth/signout ───────────────────────────────────────────────

  describe "POST /auth/signout" do
    test "revokes the server session, drops the cookie, and leaves other browsers alone", %{
      conn: conn
    } do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      {other, _} = insert_session(user)
      token = get_session(conn, :session_token)

      response = post(conn, "/auth/signout")
      assert redirected_to(response) == "/"
      # The whole session is dropped on the way out, not just the token.
      assert response.private.plug_session_info == :drop
      refute Repo.get(Session, Crypto.sha256(token))
      assert Accounts.session_user(Crypto.sha256(other)).id == user.id

      # The browser that signed out is a stranger now.
      assert json_response(response |> recycle() |> get("/api/auth/install"), 401)
    end

    test "is harmless for a browser that was not signed in", %{conn: conn} do
      assert redirected_to(post(conn, "/auth/signout")) == "/"
    end
  end

  # ── GET /j/:token ────────────────────────────────────────────────────

  describe "GET /j/:token" do
    test "a stranger goes to GitHub first, with the link parked on the attempt", %{conn: conn} do
      response = get(conn, "/j/link-token")
      location = redirected_to(response, 303)
      assert String.starts_with?(location, "https://github.test/login/oauth/authorize?")
      state = state_of(location)

      assert %{value: secret, path: "/api/auth/callback"} =
               response.resp_cookies["ravix_oauth_" <> state]

      assert %{kind: :join, redirect: "link-token"} =
               Accounts.take_state(Crypto.sha256("#{state}:#{secret}"))
    end

    test "a stranger with no GitHub App to go to gets the 503", %{conn: conn} do
      stub(Ravix.Config, :github, fn -> nil end)
      assert %{"error" => "no_github"} = json_response(get(conn, "/j/link-token"), 503)
    end

    if Code.ensure_loaded?(Ravix.People) do
      # Inside the guard, with the tests that need it: on a tree without
      # `Ravix.People` there is no struct to name.
      alias Ravix.People.LinkTarget

      test "somebody signed in is asked, and the GET claims nothing", %{conn: conn} do
        %{conn: conn} = register_and_log_in_user(%{conn: conn})

        stub(Ravix.People, :link_target, fn "link-token", _user ->
          {:ok,
           %LinkTarget{
             kind: :track,
             project: "acme",
             project_view: %{
               name: "acme",
               display_name: "ana / acme",
               owner_login: "ana",
               role: :member
             },
             track: "Fix the bug",
             invited_by: "ana"
           }}
        end)

        # The regression this route exists to prevent (#16). A GET carries no
        # CSRF token and `SameSite=Lax` permits top-level navigation, so any
        # page a signed-in person visits could otherwise take an invite on
        # their behalf by sending them here.
        reject(&Ravix.People.claim_link/2)

        html = html_response(get(conn, "/j/link-token"), 200)

        # It says what is being joined, and who is asking.
        assert html =~ "Fix the bug"
        assert html =~ "acme"
        assert html =~ "@ana"

        # And the only thing that joins is a form that posts.
        assert html =~ ~s(method="post")
        assert html =~ ~s(action="/j/link-token")
        assert html =~ "_csrf_token"
      end

      test "a project link says so, without a track", %{conn: conn} do
        %{conn: conn} = register_and_log_in_user(%{conn: conn})

        stub(Ravix.People, :link_target, fn "link-token", _user ->
          {:ok,
           %LinkTarget{
             kind: :project,
             project: "acme",
             project_view: %{
               name: "acme",
               display_name: "ana / acme",
               owner_login: "ana",
               role: :member
             },
             track: nil,
             invited_by: nil
           }}
        end)

        html = html_response(get(conn, "/j/link-token"), 200)
        assert html =~ "Join a project"
        assert html =~ "acme"
        refute html =~ "Invited by"
      end

      test "a link that is gone lands on the error", %{conn: conn} do
        %{conn: conn} = register_and_log_in_user(%{conn: conn})
        stub(Ravix.People, :link_target, fn "gone", _user -> :error end)
        assert redirected_to(get(conn, "/j/gone"), 303) == "/?error=bad_invite"
      end
    else
      test "somebody signed in, on a tree without Ravix.People, is told the invite is bad", %{
        conn: conn
      } do
        %{conn: conn} = register_and_log_in_user(%{conn: conn})
        assert redirected_to(get(conn, "/j/link-token"), 303) == "/?error=bad_invite"
      end
    end
  end

  # ── POST /j/:token ───────────────────────────────────────────────────

  describe "POST /j/:token" do
    if Code.ensure_loaded?(Ravix.People) do
      test "takes the invite and lands on what it opened", %{conn: conn} do
        %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
        user_id = user.id
        stub(Ravix.People, :claim_link, fn ^user_id, "link-token" -> {:ok, "/p/p/t/t"} end)
        assert redirected_to(post(conn, "/j/link-token"), 303) == "/p/p/t/t"
      end

      test "a link that went away between the page and the button says so", %{conn: conn} do
        %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
        user_id = user.id
        stub(Ravix.People, :claim_link, fn ^user_id, "gone" -> :error end)
        assert redirected_to(post(conn, "/j/gone"), 303) == "/?error=bad_invite"
      end
    end

    test "a session that went away while the page was open keeps the link", %{conn: conn} do
      # Round the sign-in trip with the token parked, rather than losing it and
      # leaving somebody on an error page holding a link that still works.
      response = post(conn, "/j/link-token")
      location = redirected_to(response, 303)
      assert String.starts_with?(location, "https://github.test/login/oauth/authorize?")

      state = state_of(location)
      assert %{value: secret} = response.resp_cookies["ravix_oauth_" <> state]

      assert %{kind: :join, redirect: "link-token"} =
               Accounts.take_state(Crypto.sha256("#{state}:#{secret}"))
    end
  end

  # ── the plug and the hooks ───────────────────────────────────────────

  describe "RavixWeb.Plugs.CurrentUser" do
    test "assigns the session's user, and forgets a token whose session is gone", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      token = get_session(conn, :session_token)

      assert %{assigns: %{current_user: %{id: id}}} = CurrentUser.call(conn, [])
      assert id == user.id

      :ok = Accounts.end_session(Crypto.sha256(token))
      forgotten = CurrentUser.call(conn, [])
      assert forgotten.assigns.current_user == nil
      assert get_session(forgotten, :session_token) == nil
      assert forgotten.assigns.session_ended
      assert {:error, :session_ended} = CurrentUser.require_user(forgotten)

      stranger = CurrentUser.call(init_test_session(build_conn(), %{}), [])
      assert stranger.assigns.current_user == nil
      assert {:error, :unauthenticated} = CurrentUser.require_user(stranger)
    end
  end

  describe "RavixWeb.Live.Hooks" do
    test ":fetch_current_user assigns the user or nil and never halts", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      session = %{"session_token" => get_session(conn, :session_token)}

      assert {:cont, socket} = Hooks.on_mount(:fetch_current_user, %{}, session, socket())
      assert socket.assigns.current_user.id == user.id

      assert {:cont, socket} = Hooks.on_mount(:fetch_current_user, %{}, %{}, socket())
      assert socket.assigns.current_user == nil

      assert {:cont, socket} =
               Hooks.on_mount(:fetch_current_user, %{}, %{"session_token" => "stale"}, socket())

      assert socket.assigns.current_user == nil
    end

    test ":require_authenticated_user halts a stranger with a redirect home", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      session = %{"session_token" => get_session(conn, :session_token)}

      assert {:cont, socket} = Hooks.on_mount(:require_authenticated_user, %{}, session, socket())
      assert socket.assigns.current_user.id == user.id

      assert {:halt, socket} = Hooks.on_mount(:require_authenticated_user, %{}, %{}, socket())
      assert socket.assigns.current_user == nil
      assert {:redirect, %{to: "/"}} = socket.redirected
    end

    test "a user already on the socket is not looked up again", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      session = %{"session_token" => get_session(conn, :session_token)}
      :ok = Accounts.end_session(Crypto.sha256(session["session_token"]))

      preassigned = Phoenix.Component.assign(socket(), :current_user, user)

      assert {:cont, socket} =
               Hooks.on_mount(:require_authenticated_user, %{}, session, preassigned)

      assert socket.assigns.current_user.id == user.id
    end

    defp socket,
      do: %Phoenix.LiveView.Socket{
        endpoint: RavixWeb.Endpoint,
        router: RavixWeb.Router,
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }
  end
end
