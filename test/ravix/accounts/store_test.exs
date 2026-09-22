defmodule Ravix.Accounts.StoreTest do
  use Ravix.DataCase, async: true

  alias Ravix.Accounts.Store
  alias Ravix.Accounts.User

  describe "get_user/1" do
    test "by id, and nil for an unknown or malformed one" do
      user = insert_user(login: "Ana")
      assert Store.get_user(user.id).id == user.id
      assert Store.get_user("nope") == nil
      assert Store.get_user(nil) == nil
      assert Store.get_user(42) == nil
    end
  end

  describe "user_by_login/1" do
    test "by login regardless of case" do
      user = insert_user(login: "Ana")
      assert Store.user_by_login("ana").id == user.id
      assert Store.user_by_login("ANA").id == user.id
      assert Store.user_by_login("joana") == nil
    end

    test "an ambiguous login is nobody, not a guess" do
      # `login` cannot be unique: GitHub frees a name the moment somebody
      # renames, so a stale `dana` and the new `dana` can both be here. The
      # removal path refuses rather than picking one of them.
      insert_user(login: "dana", github_id: "1")
      insert_user(login: "Dana", github_id: "2")
      assert Store.user_by_login("dana") == nil
    end
  end

  describe "search_users/3" do
    test "matches login or name, never the caller, prefix matches first" do
      me = insert_user(login: "ana-me")
      ana = insert_user(login: "ana", name: "Ana")
      joana = insert_user(login: "joana", name: "Jo")
      banana = insert_user(login: "zed", name: "Banana Split")
      _other = insert_user(login: "bob", name: "Bob")

      logins = Store.search_users("ana", me.id) |> Enum.map(& &1.login)
      assert logins == ["ana", "joana", "zed"]
      refute me.login in logins

      assert [%User{id: id}] = Store.search_users("ANA", me.id, 1)
      assert id == ana.id
      assert Store.search_users("jo", me.id) |> Enum.map(& &1.id) == [joana.id]
      assert Store.search_users("split", me.id) |> Enum.map(& &1.id) == [banana.id]
      assert Store.search_users("nobody", me.id) == []
    end

    test "wildcards in the term are literal, not a way to ask for everyone" do
      me = insert_user(login: "asker")
      insert_user(login: "alice")
      insert_user(login: "bob")

      logins = fn q ->
        Store.search_users(q, me.id) |> Enum.map(& &1.login) |> Enum.sort()
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
end
