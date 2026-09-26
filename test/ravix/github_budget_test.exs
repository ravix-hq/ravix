defmodule Ravix.GitHubBudgetTest do
  use ExUnit.Case, async: true

  alias Ravix.{Clock, GitHub}
  alias Ravix.GitHub.{Cache, Error, HTTP}
  alias Ravix.GitHubFake, as: Fake

  setup do
    Clock.freeze(1_000_000)
    on_exit(fn -> Clock.freeze(nil) end)
    %{app: Fake.app()}
  end

  test "user cooldown covers installations, repositories and identity, without blocking another user",
       %{app: app} do
    Fake.install([
      {"GET", "/user/installations",
       {403, [{"retry-after", "120"}], %{message: "secondary rate limit"}}},
      {"GET", "/user", %{id: 2, login: "other"}}
    ])

    assert {:error, %Error{retry_at_ms: until}} = GitHub.installations_for(app, "user-one")
    assert until == 1_120_000
    assert {:error, %Error{retry_at_ms: ^until}} = GitHub.repositories(app, "user-one", 42)
    assert {:error, %Error{retry_at_ms: ^until}} = GitHub.viewer(app, "user-one")
    assert {:ok, _} = GitHub.viewer(app, "user-two")
    assert Fake.request_count() == 2

    Clock.freeze(until)
    assert {:ok, _} = GitHub.viewer(app, "user-one")
    assert Fake.request_count() == 1
  end

  test "last successful response blocks the next request until reset", %{app: app} do
    Fake.install([
      {"GET", "/last",
       {200, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1200"}], %{ok: true}}}
    ])

    assert {:ok, %{"ok" => true}} = HTTP.request(app, :get, "/last", user_token: "user")

    assert {:error, %Error{retry_at_ms: 1_200_000}} =
             HTTP.request(app, :get, "/never", user_token: "user")

    assert Fake.request_count() == 1
  end

  test "ordinary forbidden and malformed budget headers do not install cooldowns", %{app: app} do
    Fake.install([
      {"GET", "/forbidden", {403, %{message: "Forbidden"}}},
      {"GET", "/ok",
       {200, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "bad"}], %{ok: true}}}
    ])

    assert {:error, %Error{retry_at_ms: nil}} =
             HTTP.request(app, :get, "/forbidden", user_token: "user")

    assert {:ok, _} = HTTP.request(app, :get, "/ok", user_token: "user")
    assert {:ok, _} = HTTP.request(app, :get, "/ok", user_token: "user")
    assert Fake.request_count() == 3
  end

  test "out-of-order node updates cannot shorten a user's cooldown", %{app: app} do
    scope = Cache.user_scope("secret")
    refute inspect(scope) =~ "secret"
    long = %Error{status: 429, retry_at_ms: 1_500_000}
    short = %Error{status: 429, retry_at_ms: 1_100_000}
    Cache.put_rate_limit(app.app_id, scope, long.retry_at_ms, long)
    send(Cache, {:rate_limit, app.app_id, scope, short.retry_at_ms, short})
    GenServer.call(Cache, :ping)
    assert {:ok, 1_500_000, ^long} = Cache.rate_limit(app.app_id, scope)
  end
end
