defmodule Ravix.GitHubPlanPullsTest do
  use ExUnit.Case, async: true
  alias Ravix.{Clock, GitHub}
  alias Ravix.GitHub.Shapes
  alias Ravix.GitHubFake, as: Fake

  test "exact Plan-Item lines count anywhere outside fenced code, in order, once each" do
    assert Shapes.pull_ref(%{
             "body" => "Summary\n\nPlan-Item: a\r\nPlan-Item: B_2\r\nPlan-Item: a\n"
           }).plan_item_ids == ["a", "B_2"]

    # A footer after the list (an agent harness's attribution) must not unlink it.
    assert Shapes.pull_ref(%{
             "body" =>
               "Plan-Item: first\n\nWhat changed.\n\nPlan-Item: second\n\n🤖 Generated with a tool"
           }).plan_item_ids == ["first", "second"]

    # A documented example in a fence is not a link; the real line after it is.
    assert Shapes.pull_ref(%{
             "body" =>
               "Use a trailer:\n\n```\nPlan-Item: example-item-id\n```\n\n~~~\nPlan-Item: tilde\n~~~\nPlan-Item: real"
           }).plan_item_ids == ["real"]

    for body <- [
          nil,
          "More prose mentioning Plan-Item: a inline",
          "```\nPlan-Item: a\n```",
          "```elixir\nPlan-Item: a",
          "> Plan-Item: a",
          "Plan-Item: a b",
          "Plan-Item: ../a",
          "Plan-Item: " <> String.duplicate("a", 101)
        ] do
      assert Shapes.pull_ref(%{"body" => body}).plan_item_ids == []
    end
  end

  test "repository batch filters head repos, caches, and conditionally revalidates" do
    app = Fake.app()
    Clock.freeze(1_000_000)

    Fake.install([
      Fake.token_route(app),
      {"GET", "/repos/o/r/pulls",
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)

         assert conn.query_params == %{
                  "state" => "all",
                  "sort" => "updated",
                  "direction" => "desc",
                  "per_page" => "100",
                  "page" => "1"
                }

         case Plug.Conn.get_req_header(conn, "if-none-match") do
           [] ->
             conn
             |> Plug.Conn.put_resp_header("etag", "\"items\"")
             |> Req.Test.json([
               raw(1, "o/r", "Plan-Item: a"),
               raw(2, "fork/r", "Plan-Item: a"),
               raw(3, "o/r", "ordinary PR")
             ])

           ["\"items\""] ->
             Plug.Conn.send_resp(conn, 304, "")
         end
       end}
    ])

    assert {:ok,
            %{pulls: [%Shapes.PullRef{number: 1, plan_item_ids: ["a"]}], complete: true} = batch} =
             GitHub.plan_pulls(app, 1, "o/r")

    assert Fake.request_count("/repos/") == 1
    assert {:ok, ^batch} = GitHub.plan_pulls(app, 1, "o/r")
    assert Fake.request_count() == 0
    Clock.freeze(1_300_001)
    assert {:ok, ^batch} = GitHub.plan_pulls(app, 1, "o/r")
    assert Fake.request_count("/repos/") == 1
    assert {:error, {:unconfigured, :github}} = GitHub.plan_pulls(nil, 1, "o/r")
  end

  test "pagination is bounded to three cached pages and signals incomplete evidence" do
    app = Fake.app()

    Fake.install([
      Fake.token_route(app),
      {"GET", "/repos/o/r/pulls",
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         page = String.to_integer(conn.query_params["page"])
         assert page in 1..3
         Req.Test.json(conn, Enum.map(1..100, &raw((page - 1) * 100 + &1, "o/r", "Plan-Item: a")))
       end}
    ])

    assert {:ok, %{pulls: pulls, complete: false}} = GitHub.plan_pulls(app, 1, "o/r")
    assert length(pulls) == 300
    assert Fake.request_count("/repos/") == 3
    assert {:ok, %{pulls: ^pulls}} = GitHub.plan_pulls(app, 1, "o/r")
    assert Fake.request_count() == 0
  end

  test "a page error is returned rather than treated as no linked PRs" do
    app = Fake.app()

    Fake.install([
      Fake.token_route(app),
      {"GET", "/repos/o/r/pulls", {503, %{message: "unavailable"}}}
    ])

    assert {:error, %GitHub.Error{status: 503}} = GitHub.plan_pulls(app, 1, "o/r")
  end

  defp raw(number, repo, body),
    do: %{
      number: number,
      body: body,
      state: "open",
      head: %{ref: "feature", repo: %{full_name: repo}}
    }
end
