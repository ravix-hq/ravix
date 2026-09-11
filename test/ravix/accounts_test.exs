defmodule Ravix.AccountsTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.{OAuthState, Session, User}
  alias Ravix.Crypto
  alias Ravix.GitHubFake, as: Fake

  # ── users ────────────────────────────────────────────────────────────

  describe "upsert_user/1" do
    test "creates on first sign-in and refreshes the profile on the next, keeping the id" do
      assert {:ok, %User{} = first} =
               Accounts.upsert_user(%{
                 github_id: "1",
                 login: "owner",
                 name: "Owner",
                 avatar_url: nil,
                 token_enc: Crypto.encrypt("t1")
               })

      assert first.github_id == "1"
      assert first.created_at
      assert first.last_seen_at

      assert {:ok, %User{} = again} =
               Accounts.upsert_user(%{
                 github_id: "1",
                 login: "renamed",
                 name: nil,
                 avatar_url: "https://a/1",
                 token_enc: Crypto.encrypt("t2")
               })

      assert again.id == first.id
      assert again.login == "renamed"
      assert again.name == nil
      assert again.avatar_url == "https://a/1"
      assert {:ok, "t2"} = Accounts.user_token(again)
      assert DateTime.compare(again.last_seen_at, first.last_seen_at) in [:gt, :eq]
      assert again.created_at == first.created_at
      assert Repo.aggregate(User, :count) == 1
    end

    test "requires a login" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.upsert_user(%{github_id: "2", login: nil, token_enc: "x"})
    end
  end

  describe "get_user/1 and user_by_login/1" do
    test "by id, and by login regardless of case" do
      user = insert_user(login: "Ana")
      assert Accounts.get_user(user.id).id == user.id
      assert Accounts.get_user("nope") == nil
      assert Accounts.get_user(nil) == nil
      assert Accounts.user_by_login("ana").id == user.id
      assert Accounts.user_by_login("ANA").id == user.id
      assert Accounts.user_by_login("joana") == nil
    end
  end

  describe "search_users/3" do
    test "matches login or name, never the caller, prefix matches first" do
      me = insert_user(login: "ana-me")
      ana = insert_user(login: "ana", name: "Ana")
      joana = insert_user(login: "joana", name: "Jo")
      banana = insert_user(login: "zed", name: "Banana Split")
      _other = insert_user(login: "bob", name: "Bob")

      logins = Accounts.search_users("ana", me.id) |> Enum.map(& &1.login)
      assert logins == ["ana", "joana", "zed"]
      refute me.login in logins

      assert [%User{id: id}] = Accounts.search_users("ANA", me.id, 1)
      assert id == ana.id
      assert Accounts.search_users("jo", me.id) |> Enum.map(& &1.id) == [joana.id]
      assert Accounts.search_users("split", me.id) |> Enum.map(& &1.id) == [banana.id]
      assert Accounts.search_users("nobody", me.id) == []
    end

    test "wildcards in the term are literal, not a way to ask for everyone" do
      me = insert_user(login: "asker")
      insert_user(login: "alice")
      insert_user(login: "bob")

      logins = fn q ->
        Accounts.search_users(q, me.id) |> Enum.map(& &1.login) |> Enum.sort()
      end

      # `People.search/2` refuses an empty query precisely so nobody can ask
      # for the whole userbase. A bare wildcard walked straight past that
      # guard into `ILIKE '%%%'`, which matches every row, and the ranking
      # made the result walkable a letter at a time.
      assert logins.("%") == []
      assert logins.("_") == []
      assert logins.("a%") == []

      # An ordinary term still works.
      assert logins.("ali") == ["alice"]
      assert logins.("bo") == ["bob"]
    end
  end

  describe "user_token/1" do
    test "decrypts the stored token, and asks for a new sign-in otherwise" do
      assert {:ok, "gho_x"} = Accounts.user_token(insert_user(token_enc: Crypto.encrypt("gho_x")))
      assert {:error, :no_token} = Accounts.user_token(insert_user(token_enc: nil))
      assert {:error, :no_token} = Accounts.user_token(insert_user(token_enc: "v1.garbage"))

      other_secret = Crypto.encrypt("gho_y", "somebody-elses-secret-here")
      assert {:error, :no_token} = Accounts.user_token(insert_user(token_enc: other_secret))
    end
  end

  # ── sessions ─────────────────────────────────────────────────────────

  describe "sessions" do
    test "a created session resolves to its user until it is ended" do
      user = insert_user()
      hash = Crypto.sha256("token")
      assert :ok = Accounts.create_session(user.id, hash, 60_000)
      assert %Session{expires_at: expires} = Repo.get(Session, hash)
      assert DateTime.diff(expires, DateTime.utc_now(), :second) in 55..61

      assert %User{id: id} = Accounts.session_user(hash)
      assert id == user.id
      assert Accounts.session_user(Crypto.sha256("other")) == nil
      assert Accounts.session_user(nil) == nil

      assert :ok = Accounts.end_session(hash)
      assert Accounts.session_user(hash) == nil
      assert :ok = Accounts.end_session(hash)
    end

    test "an expired session is refused and deleted on the read that finds it" do
      user = insert_user()
      {token, _} = insert_session(user, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      hash = Crypto.sha256(token)
      assert Repo.get(Session, hash)
      assert Accounts.session_user(hash) == nil
      refute Repo.get(Session, hash)
    end

    test "signing one browser out leaves the others signed in" do
      user = insert_user()
      {a, _} = insert_session(user)
      {b, _} = insert_session(user)
      :ok = Accounts.end_session(Crypto.sha256(a))
      assert Accounts.session_user(Crypto.sha256(a)) == nil
      assert Accounts.session_user(Crypto.sha256(b)).id == user.id
    end
  end

  # ── the two GitHub round trips ───────────────────────────────────────

  describe "put_state/3 and take_state/1" do
    test "a state is taken once" do
      assert :ok = Accounts.put_state("s1", "signin", nil)
      assert %{kind: :signin, redirect: nil} = Accounts.take_state("s1")
      assert Accounts.take_state("s1") == nil
      assert Accounts.take_state("never") == nil
      assert Accounts.take_state(nil) == nil
    end

    test "putting a state again replaces its kind and redirect" do
      :ok = Accounts.put_state("s2", "signin", nil)
      :ok = Accounts.put_state("s2", "join", "link-token")
      assert %{kind: :join, redirect: "link-token"} = Accounts.take_state("s2")
    end

    test "a state older than fifteen minutes is worthless and gets swept" do
      old = DateTime.add(DateTime.utc_now(), -16, :minute)
      insert_oauth_state(state: "old", kind: "signin", created_at: old)
      insert_oauth_state(state: "swept", kind: "signin", created_at: old)

      assert Accounts.take_state("old") == nil

      :ok = Accounts.put_state("fresh", "signin", nil)
      refute Repo.get(OAuthState, "swept")
      assert Repo.get(OAuthState, "fresh")
    end
  end

  # ── what the shell needs before it renders ───────────────────────────

  describe "session_info/1" do
    test "with no GitHub App there is nowhere to sign in and nobody is anybody" do
      stub(Ravix.Config, :github, fn -> nil end)
      stub(Ravix.Config, :sprites, fn -> nil end)
      stub(Ravix.Config, :fountain, fn -> %Ravix.Config.Fountain{url: "https://f", key: nil} end)

      assert Accounts.session_info(nil) == %{
               viewer: nil,
               sign_in_url: "",
               install_url: "",
               capabilities: %{exec: false, github: false, vaults: false}
             }

      user = insert_user(token_enc: Crypto.encrypt("gho_x"))
      assert %{viewer: %{has_installation: false}} = Accounts.session_info(user)
    end

    test "with one, the viewer's installation is asked of GitHub live" do
      app = Fake.app()
      stub(Ravix.Config, :github, fn -> app end)

      stub(Ravix.Config, :sprites, fn ->
        %Ravix.Config.Sprites{token: "t", base_url: "https://s"}
      end)

      stub(Ravix.Config, :fountain, fn -> %Ravix.Config.Fountain{url: "https://f", key: "k"} end)

      Fake.install([
        {"GET", "/user/installations",
         %{installations: [%{id: 1, account: %{login: "ravix-hq", avatar_url: nil}}]}}
      ])

      user =
        insert_user(
          github_id: "77",
          login: "me",
          name: "Me",
          avatar_url: "https://a/me",
          token_enc: Crypto.encrypt("gho_me")
        )

      assert %{
               viewer: %{
                 id: "77",
                 login: "me",
                 name: "Me",
                 avatar_url: "https://a/me",
                 has_installation: true
               },
               sign_in_url: "/auth/github",
               install_url: "https://github.test/apps/test/installations/new",
               capabilities: %{exec: true, github: true, vaults: true}
             } = Accounts.session_info(user)

      assert Fake.request_count("/user/installations") == 1
    end

    test "a revoked token is not fatal to the session: the viewer simply has no installation" do
      app = Fake.app()
      stub(Ravix.Config, :github, fn -> app end)
      Fake.install([{"GET", "/user/installations", {401, %{message: "Bad credentials"}}}])

      user = insert_user(token_enc: Crypto.encrypt("gho_revoked"))
      assert %{viewer: %{has_installation: false}} = Accounts.session_info(user)

      # And a user with no token at all does not even ask.
      assert %{viewer: %{has_installation: false}} =
               Accounts.session_info(insert_user(token_enc: nil))

      assert Fake.request_count("/user/installations") == 1
    end
  end
end
