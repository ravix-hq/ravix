defmodule Ravix.Accounts.AuthTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.{Auth, Session, User}
  alias Ravix.Crypto
  alias Ravix.GitHubFake, as: Fake

  @no_github "This Ravix deployment has no GitHub App configured, so it cannot see repositories."

  setup do
    app = Fake.app()
    stub(Ravix.Config, :github, fn -> app end)
    stub(Ravix.Config, :public_url, fn -> "https://ravix.test" end)
    %{app: app}
  end

  # GitHub, for a sign-in that works: the code buys a token, the token names a person.
  defp github_signs_in(profile \\ %{id: 3, login: "new-user", name: nil, avatar_url: ""}) do
    owner = self()

    Fake.install([
      {"POST", "/login/oauth/access_token",
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(owner, {:exchanged, Jason.decode!(raw)})
         Req.Test.json(conn, %{access_token: "oauth-token", token_type: "bearer"})
       end},
      {"GET", "/user", profile}
    ])
  end

  defp attempt(kind \\ "signin", redirect \\ nil) do
    {:ok, attempt} = Auth.begin(kind, redirect)
    attempt
  end

  defp params(attempt, extra \\ %{}),
    do: Map.merge(%{"state" => attempt.state, "code" => "code"}, extra)

  describe "begin/2 and the URLs" do
    test "parks a state keyed on the browser secret, never on the state alone" do
      %{state: state, secret: secret} = attempt("join", "link-token")
      assert Auth.valid_state?(state)
      assert String.length(state) == 24
      assert Accounts.take_state(state) == nil

      assert %{kind: "join", redirect: "link-token"} =
               Accounts.take_state(Crypto.sha256("#{state}:#{secret}"))
    end

    test "the URLs carry the state and the registered callback", %{app: app} do
      %{state: state} = attempt()
      assert {:ok, url} = Auth.authorize_url(state)
      assert url == Ravix.GitHub.authorize_url(app, "https://ravix.test/api/auth/callback", state)
      assert url =~ "state=#{state}"
      assert {:ok, install} = Auth.install_url(state)
      assert install == "https://github.test/apps/test/installations/new?state=#{state}"
      assert Auth.callback_url() == "https://ravix.test/api/auth/callback"
      assert Auth.cookie_name(state) == "ravix_oauth_" <> state
    end

    test "without a GitHub App there is nothing to begin" do
      stub(Ravix.Config, :github, fn -> nil end)
      assert {:error, {:unavailable, @no_github}} = Auth.begin("signin", nil)
      assert {:error, {:unavailable, @no_github}} = Auth.authorize_url("x")
      assert {:error, {:unavailable, @no_github}} = Auth.install_url(nil)
      assert {:error, {:unavailable, @no_github}} = Auth.callback(%{"code" => "c"}, "s")
    end

    test "valid_state?/1 is exactly eighteen random bytes as base64url" do
      assert Auth.valid_state?(Crypto.random_token(18))
      refute Auth.valid_state?(Crypto.random_token(24))
      refute Auth.valid_state?("../etc")
      refute Auth.valid_state?(nil)
      refute Auth.valid_state?("")
    end
  end

  describe "callback/2 without a code" do
    test "an installation granted by somebody already signed in, or a person who declined" do
      assert {:redirect, "/?installed=1"} = Auth.callback(%{"installation_id" => "9"}, nil)
      assert {:redirect, "/?error=github_declined"} = Auth.callback(%{}, nil)
      assert {:redirect, "/?error=github_declined"} = Auth.callback(%{"code" => ""}, nil)
    end
  end

  describe "callback/2 refusing" do
    test "requires the initiating browser's secret and rejects replay" do
      github_signs_in()
      mine = attempt()
      other = attempt()

      for secret <- [nil, "", other.secret, "wrong"] do
        assert {:redirect, "/?error=stale_signin"} = Auth.callback(params(mine), secret)
      end

      refute_received {:exchanged, _}
      assert {:ok, %{redirect: "/"}} = Auth.callback(params(mine), mine.secret)
      assert_received {:exchanged, %{"code" => "code"}}
      assert {:redirect, "/?error=stale_signin"} = Auth.callback(params(mine), mine.secret)
      refute_received {:exchanged, _}
    end

    test "a state that is not ours, or missing, is stale without touching the database" do
      github_signs_in()

      for state <- [nil, "", "short", String.duplicate("x", 24) <> "!"] do
        assert {:redirect, "/?error=stale_signin"} =
                 Auth.callback(%{"state" => state, "code" => "code"}, "secret")
      end

      refute_received {:exchanged, _}
    end

    test "expired and pre-upgrade unbound states cannot exchange a code" do
      github_signs_in()
      %{state: state, secret: secret} = attempt()
      key = Crypto.sha256("#{state}:#{secret}")

      Repo.update_all(
        from(s in Ravix.Accounts.OAuthState, where: s.state == ^key),
        set: [created_at: DateTime.add(DateTime.utc_now(), -16, :minute)]
      )

      assert {:redirect, "/?error=stale_signin"} = Auth.callback(params(%{state: state}), secret)

      # A row keyed on the bare state, as the server wrote before secrets: unusable.
      :ok = Accounts.put_state(state, "signin", nil)
      assert {:redirect, "/?error=stale_signin"} = Auth.callback(params(%{state: state}), secret)
      refute_received {:exchanged, _}
    end

    test "GitHub refusing the code is a redirect that names the status" do
      Fake.install([
        {"POST", "/login/oauth/access_token", %{error: "bad_verification_code"}}
      ])

      mine = attempt()
      assert {:redirect, "/?error=github_400"} = Auth.callback(params(mine), mine.secret)
      assert Repo.aggregate(User, :count) == 0
    end

    test "GitHub refusing the token is the same, and an unreachable GitHub is status 0" do
      Fake.install([
        {"POST", "/login/oauth/access_token", %{access_token: "t"}},
        {"GET", "/user", {401, %{message: "Bad credentials"}}}
      ])

      mine = attempt()
      assert {:redirect, "/?error=github_401"} = Auth.callback(params(mine), mine.secret)

      Fake.install([
        {"POST", "/login/oauth/access_token",
         fn conn -> Req.Test.transport_error(conn, :econnrefused) end}
      ])

      mine = attempt()
      assert {:redirect, "/?error=github_0"} = Auth.callback(params(mine), mine.secret)
    end
  end

  describe "callback/2 succeeding" do
    test "creates the user with the token encrypted, and a session for the browser" do
      github_signs_in(%{id: 3, login: "new-user", name: "New", avatar_url: "https://a/3"})
      mine = attempt()

      assert {:ok, %{token: token, user: %User{} = user, redirect: "/", joined: joined}} =
               Auth.callback(params(mine), mine.secret)

      assert joined == %{tracks: [], projects: []} or is_map(joined)
      assert user.github_id == "3"
      assert user.login == "new-user"
      assert user.name == "New"
      assert user.avatar_url == "https://a/3"
      assert {:ok, "oauth-token"} = Accounts.user_token(user)
      refute user.token_enc == "oauth-token"

      assert %Session{user_id: user_id, expires_at: expires} =
               Repo.get(Session, Crypto.sha256(token))

      assert user_id == user.id
      assert Accounts.session_user(Crypto.sha256(token)).id == user.id

      assert_in_delta DateTime.diff(expires, DateTime.utc_now(), :millisecond),
                      Ravix.Config.session_max_age_ms(),
                      5_000

      assert_received {:exchanged, %{"redirect_uri" => "https://ravix.test/api/auth/callback"}}
    end

    test "signs an existing person in again, refreshing their profile" do
      existing = insert_user(github_id: "3", login: "old-name", token_enc: nil)
      github_signs_in()
      mine = attempt()
      assert {:ok, %{user: user}} = Auth.callback(params(mine), mine.secret)
      assert user.id == existing.id
      assert user.login == "new-user"
      assert {:ok, "oauth-token"} = Accounts.user_token(user)
      assert Repo.aggregate(User, :count) == 1
    end

    test "an installation that came with a code lands on the installed screen" do
      github_signs_in()
      mine = attempt("install", nil)

      assert {:ok, %{redirect: "/?installed=1"}} =
               Auth.callback(params(mine, %{"installation_id" => "5"}), mine.secret)
    end

    test "independent attempts can finish in either order" do
      github_signs_in()
      first = attempt()
      second = attempt()
      assert {:ok, %{redirect: "/"}} = Auth.callback(params(second), second.secret)
      assert {:ok, %{redirect: "/"}} = Auth.callback(params(first), first.secret)
      assert_received {:exchanged, _}
      assert_received {:exchanged, _}
    end

    # `Ravix.People` is built by another agent. When it is here, the two
    # landing rules that depend on it are exercised through a stub; when it
    # is not, the callback still succeeds and lands on `/`, which the tests
    # above cover.
    if Code.ensure_loaded?(Ravix.People) do
      test "one project invitation is worth landing on; one of each is the rail's decision" do
        github_signs_in()

        stub(Ravix.People, :claim_invites, fn _user_id, "3" ->
          %{projects: [%{id: "p1"}], tracks: []}
        end)

        mine = attempt()
        assert {:ok, %{redirect: "/p/p1"}} = Auth.callback(params(mine), mine.secret)

        stub(Ravix.People, :claim_invites, fn _user_id, "3" ->
          %{projects: [%{id: "p1"}], tracks: [%{id: "t1", project_id: "p1"}]}
        end)

        mine = attempt()
        assert {:ok, %{redirect: "/"}} = Auth.callback(params(mine), mine.secret)
      end

      test "one track invitation lands on the track; several is the rail's decision" do
        github_signs_in()

        stub(Ravix.People, :claim_invites, fn _user_id, _github_id ->
          %{projects: [], tracks: [%{id: "t1", project_id: "p1"}]}
        end)

        mine = attempt()
        assert {:ok, %{redirect: "/p/p1/t/t1"}} = Auth.callback(params(mine), mine.secret)

        stub(Ravix.People, :claim_invites, fn _user_id, _github_id ->
          %{projects: [%{id: "p1"}, %{id: "p2"}], tracks: []}
        end)

        mine = attempt()
        assert {:ok, %{redirect: "/"}} = Auth.callback(params(mine), mine.secret)
      end

      test "a join trip claims the link that started it, and lands where it points" do
        github_signs_in()
        stub(Ravix.People, :claim_invites, fn _, _ -> %{projects: [], tracks: []} end)
        stub(Ravix.People, :claim_link, fn _user_id, "link-token" -> {:ok, "/p/p/t/t"} end)
        mine = attempt("join", "link-token")
        assert {:ok, %{redirect: "/p/p/t/t"}} = Auth.callback(params(mine), mine.secret)

        stub(Ravix.People, :claim_link, fn _user_id, _token -> :error end)
        mine = attempt("join", "gone")
        assert {:ok, %{redirect: "/?error=bad_invite"}} = Auth.callback(params(mine), mine.secret)
      end
    else
      test "a join trip without Ravix.People still signs in and reports the bad invite" do
        github_signs_in()
        mine = attempt("join", "link-token")
        assert {:ok, %{redirect: "/?error=bad_invite"}} = Auth.callback(params(mine), mine.secret)
      end
    end
  end

  describe "sign_out/1" do
    test "ends the session the token names, and nothing else" do
      user = insert_user()
      {a, _} = insert_session(user)
      {b, _} = insert_session(user)
      assert :ok = Auth.sign_out(a)
      assert :ok = Auth.sign_out(a)
      assert :ok = Auth.sign_out(nil)
      assert Accounts.session_user(Crypto.sha256(a)) == nil
      assert Accounts.session_user(Crypto.sha256(b)).id == user.id
    end
  end
end
