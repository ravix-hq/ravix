defmodule Ravix.GitHubReadsTest do
  use ExUnit.Case, async: true

  alias Ravix.{Clock, GitHub}
  alias Ravix.GitHub.{Error, HTTP}
  alias Ravix.GitHubFake, as: Fake

  setup do
    Clock.freeze(1_000_000)
    on_exit(fn -> Clock.freeze(nil) end)
    %{app: Fake.app()}
  end

  test "picker reads share data, revalidate with ETag, and replace changed data", %{app: app} do
    counter = :counters.new(1, [])

    Fake.install([
      {"GET", "/user/installations",
       fn conn ->
         :counters.add(counter, 1, 1)

         case :counters.get(counter, 1) do
           1 ->
             assert Plug.Conn.get_req_header(conn, "if-none-match") == []

             conn
             |> Plug.Conn.put_resp_header("etag", "\"v1\"")
             |> Req.Test.json(%{installations: [%{id: 1}]})

           2 ->
             assert Plug.Conn.get_req_header(conn, "if-none-match") == ["\"v1\""]
             Plug.Conn.send_resp(conn, 304, "")

           3 ->
             assert Plug.Conn.get_req_header(conn, "if-none-match") == ["\"v1\""]

             conn
             |> Plug.Conn.put_resp_header("etag", "\"v2\"")
             |> Req.Test.json(%{installations: [%{id: 2}]})
         end
       end}
    ])

    assert {:ok, [%{id: 1}]} = GitHub.installations_for(app, "user")
    assert {:ok, [%{id: 1}]} = GitHub.installations_for(app, "user")
    assert Fake.request_count() == 1
    Clock.freeze(1_030_001)
    assert {:ok, [%{id: 1}]} = GitHub.installations_for(app, "user")
    assert {:ok, [%{id: 1}]} = GitHub.installations_for(app, "user")
    assert Fake.request_count() == 1
    Clock.freeze(1_060_002)
    assert {:ok, [%{id: 2}]} = GitHub.installations_for(app, "user")
    assert Fake.request_count() == 1
  end

  test "concurrent picker opens share each page and user credentials stay isolated", %{app: app} do
    owner = self()

    Fake.install([
      {"GET", "/user/installations/1/repositories",
       fn conn ->
         send(owner, {:reading, self()})

         receive do
           :release -> :ok
         end

         Req.Test.json(conn, %{repositories: [%{full_name: "o/r"}]})
       end}
    ])

    tasks = for _ <- 1..12, do: Task.async(fn -> GitHub.repositories(app, "first", 1) end)
    assert_receive {:reading, reader}
    send(reader, :release)
    assert Enum.all?(Enum.map(tasks, &Task.await/1), &match?({:ok, [_]}, &1))
    assert Fake.request_count() == 1
    other = Task.async(fn -> GitHub.repositories(app, "second", 1) end)
    assert_receive {:reading, reader}
    send(reader, :release)
    assert {:ok, [_]} = Task.await(other)
    assert Fake.request_count() == 1
  end

  test "fresh repository access bypasses display data and revoked access never returns stale success",
       %{app: app} do
    Fake.install([
      {"GET", "/user/installations/1/repositories", %{repositories: [%{full_name: "o/r"}]}}
    ])

    assert {:ok, [_]} = GitHub.repositories(app, "user", 1)

    Fake.install([
      {"GET", "/user/installations/1/repositories", {401, %{message: "Bad credentials"}}}
    ])

    assert {:error, %Error{status: 401}} = GitHub.repositories(app, "user", 1, :fresh)
    Clock.freeze(1_030_001)
    assert {:error, %Error{status: 401}} = GitHub.repositories(app, "user", 1)
    assert Fake.request_count() == 3
  end

  test "last-modified validators, absent validators and unexpected 304 responses", %{app: app} do
    Fake.install([
      {"GET", "/modified",
       fn conn ->
         case Plug.Conn.get_req_header(conn, "if-modified-since") do
           [] ->
             conn
             |> Plug.Conn.put_resp_header("last-modified", "Mon, 01 Jan 2024 00:00:00 GMT")
             |> Req.Test.json(%{value: 1})

           ["Mon, 01 Jan 2024 00:00:00 GMT"] ->
             Plug.Conn.send_resp(conn, 304, "")
         end
       end},
      {"GET", "/unconditional", %{value: 2}},
      {"GET", "/unexpected", fn conn -> Plug.Conn.send_resp(conn, 304, "") end}
    ])

    opts = [user_token: "user", cache_ttl: 30_000]

    for path <- ["/modified", "/unconditional"],
        do: assert({:ok, _} = HTTP.request(app, :get, path, opts))

    Clock.freeze(1_030_001)
    assert {:ok, %{"value" => 1}} = HTTP.request(app, :get, "/modified", opts)
    assert {:ok, %{"value" => 2}} = HTTP.request(app, :get, "/unconditional", opts)
    assert {:error, %Error{status: 304}} = HTTP.request(app, :get, "/unexpected", opts)
    assert Fake.request_count() == 5
  end

  test "transient failures back off without returning stale data", %{app: app} do
    Fake.install([{"GET", "/unavailable", {502, %{message: "Unavailable"}}}])
    opts = [user_token: "user", cache_ttl: 30_000]
    assert {:error, %Error{status: 502}} = HTTP.request(app, :get, "/unavailable", opts)
    Clock.freeze(1_030_001)
    assert {:error, %Error{status: 502}} = HTTP.request(app, :get, "/unavailable", opts)
    assert Fake.request_count() == 1
    Clock.freeze(1_060_001)
    assert {:error, %Error{status: 502}} = HTTP.request(app, :get, "/unavailable", opts)
    assert Fake.request_count() == 1
  end

  test "representation, API host and app are part of the cache key", %{app: app} do
    Fake.install([{"GET", "/read", %{}}])
    opts = [user_token: "user", cache_ttl: 30_000]
    assert {:ok, _} = HTTP.request(app, :get, "/read", opts)
    assert {:ok, _} = HTTP.request(app, :get, "/read", opts ++ [accept: "application/json"])
    assert {:ok, _} = HTTP.request(%{app | api_url: "https://other.test"}, :get, "/read", opts)
    assert {:ok, _} = HTTP.request(%{app | app_id: "other"}, :get, "/read", opts)
    assert Fake.request_count() == 4
  end
end
