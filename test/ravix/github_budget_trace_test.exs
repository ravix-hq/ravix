defmodule Ravix.GitHubBudgetTraceTest do
  use Ravix.TraceCase, async: false

  alias Ravix.GitHub.HTTP
  alias Ravix.GitHubFake, as: Fake

  test "response budget and local refusal are observable without credentials" do
    app = Fake.app()
    reset = div(Ravix.Clock.now_ms(), 1000) + 600

    Fake.install([
      {"GET", "/budget",
       {200,
        [
          {"x-ratelimit-limit", "5000"},
          {"x-ratelimit-remaining", "0"},
          {"x-ratelimit-used", "5000"},
          {"x-ratelimit-reset", to_string(reset)}
        ], %{}}}
    ])

    assert {:ok, _} = HTTP.request(app, :get, "/budget", user_token: "secret-user-credential")
    recorded = await_span("github.request")
    attrs = attributes(recorded)
    assert attrs["http.response.status_code"] == 200
    assert attrs["github.budget_scope"] == :user
    assert attrs["github.rate_limit.remaining"] == 0
    assert attrs["github.rate_limit.limit"] == 5000
    assert attrs["github.rate_limit.used"] == 5000
    assert attrs["github.rate_limit.reset"] == reset
    refute inspect(recorded) =~ "secret-user-credential"
    assert {:error, _} = HTTP.request(app, :get, "/budget", user_token: "secret-user-credential")
    assert attributes(await_span("github.request"))["ravix.rate_limited"] == true
    assert Fake.request_count() == 1
  end
end
