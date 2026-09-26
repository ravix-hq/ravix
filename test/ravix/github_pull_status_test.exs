defmodule Ravix.GitHubPullStatusTest do
  use ExUnit.Case, async: true

  alias Ravix.{Clock, GitHub}
  alias Ravix.GitHub.{Cache, HTTP}
  alias Ravix.GitHubFake, as: Fake

  @track %{created_at: ~U[2026-01-01 00:00:00Z], origin_number: nil}

  test "cached PR evidence is filtered for each track and invalidated after opening a PR" do
    app = Fake.app()

    raw = %{
      number: 1,
      head: %{ref: "branch"},
      state: "closed",
      created_at: "2025-01-01T00:00:00Z"
    }

    Fake.install([
      Fake.token_route(app),
      {"GET", "/repos/o/r/pulls", [raw]},
      {"POST", "/repos/o/r/pulls",
       %{raw | number: 2, state: "open", created_at: "2026-02-01T00:00:00Z"}}
    ])

    assert {:ok, nil} = GitHub.pull_for_track(app, 1, "o/r", "branch", @track)

    assert {:ok, %{number: 1}} =
             GitHub.pull_for_track(app, 1, "o/r", "branch", %{@track | origin_number: 1})

    assert Fake.request_count("/repos/") == 1

    assert {:ok, _} =
             GitHub.open_pull(app, 1, "o/r", %{
               head: "branch",
               base: "main",
               title: "PR",
               body: "",
               draft: false
             })

    Fake.requests()

    Fake.install([
      {"GET", "/repos/o/r/pulls",
       [%{raw | number: 2, state: "open", created_at: "2026-02-01T00:00:00Z"}]}
    ])

    assert {:ok, %{number: 2}} = GitHub.pull_for_track(app, 1, "o/r", "branch", @track)
    assert Fake.request_count() == 1
  end

  test "a generation change leaves old callers settled but cannot overwrite newer data" do
    app = Fake.app()
    owner = self()

    Fake.install([
      {"GET", "/read",
       fn conn ->
         send(owner, {:read, self()})

         receive do
           {:answer, value} -> Req.Test.json(conn, %{value: value})
         end
       end}
    ])

    opts = [installation_id: 1, auth: "Bearer test", cache_ttl: 30_000]
    old = Task.async(fn -> HTTP.request(app, :get, "/read", opts) end)
    assert_receive {:read, old_reader}
    Cache.invalidate_reads(app.app_id, 1)
    new = Task.async(fn -> HTTP.request(app, :get, "/read", opts) end)
    assert_receive {:read, new_reader}
    send(new_reader, {:answer, "new"})
    assert {:ok, %{"value" => "new"}} = Task.await(new)
    send(old_reader, {:answer, "old"})
    assert {:ok, %{"value" => "old"}} = Task.await(old)
    assert {:ok, %{"value" => "new"}} = HTTP.request(app, :get, "/read", opts)
    assert Fake.request_count() == 2
  end

  test "another instance's invalidation advances the local read generation without rebroadcast" do
    app = Fake.app()
    Phoenix.PubSub.subscribe(Ravix.PubSub, "github:rate_limit")
    assert Cache.read_generation(app.app_id, 1) == 0
    Cache.invalidate_reads(app.app_id, 1)
    assert_receive {:reads_changed, id, 1}
    assert id == app.app_id
    send(Cache, {:reads_changed, app.app_id, 1})
    GenServer.call(Cache, :ping)
    assert Cache.read_generation(app.app_id, 1) == 2
    refute_received {:reads_changed, _, _}
  end

  test "PR status revalidates after five minutes and an unconfigured app is explicit" do
    app = Fake.app()
    Clock.freeze(1_000_000)
    Fake.install([Fake.token_route(app), {"GET", "/repos/o/r/pulls", []}])
    assert {:ok, nil} = GitHub.pull_for_track(app, 1, "o/r", "branch", @track)
    Fake.requests()
    Clock.freeze(1_300_001)
    assert {:ok, nil} = GitHub.pull_for_track(app, 1, "o/r", "branch", @track)
    assert Fake.request_count("/repos/") == 1

    assert {:error, {:unconfigured, :github}} =
             GitHub.pull_for_track(nil, 1, "o/r", "branch", @track)
  end
end
