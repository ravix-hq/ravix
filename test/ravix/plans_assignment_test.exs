defmodule Ravix.PlansAssignmentTest do
  use Ravix.DataCase, async: true
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.{Fountain, Plans, Tooling}
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Plans.{Assignment, Item}
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{Authorization, OAuth}
  alias Ravix.Tracks.Track
  alias RavixWeb.Tooling.MCP

  setup do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: nil, installation_id: nil)
    {p, _, _} = principal(user)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Release",
        "summary" => "Ship together",
        "items" => [
          %{
            "id" => "api",
            "title" => "API",
            "brief" => "Own the API",
            "acceptance" => "Tests pass"
          },
          %{"id" => "ui", "title" => "UI", "brief" => "Own the UI"}
        ]
      })

    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "test-key") end)
    %{user: user, project: project, p: p, plan: plan}
  end

  test "opening tracks preserves plan origin and queues coordinated prompts exactly once", %{
    p: p,
    user: user,
    plan: plan
  } do
    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "POST", path: "/api/conversations"}, {201, [], %{data: %{id: "conv-api"}}}},
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "POST", path: "/api/conversations"}, {201, [], %{data: %{id: "conv-ui"}}}}
      ])

    stub(Fountain, :client, fn -> client end)
    assignments = [%{"item_id" => "api"}, %{"item_id" => "ui"}]
    assert {:ok, %{items: [api, ui]}} = Assignment.assign(user, p, plan.id, assignments, "batch")

    assert %{origin_kind: :plan, origin_plan_id: plan_id, origin_item_id: "api"} =
             Repo.get!(Track, api.track_id)

    assert plan_id == plan.id
    prompt = QueueStore.get(api.task.id).body["prompt"]

    for text <- [
          "Ship together",
          "Own the API",
          "Own the UI",
          "Tests pass",
          ui.track_id,
          "draft PR",
          "Do not merge"
        ],
        do: assert(prompt =~ text)

    assert {:ok, retried} = Assignment.assign(user, p, plan.id, assignments, "batch")
    assert hd(retried["items"])["track_id"] == api.track_id
    assert length(FakeTransport.calls(client)) == 4

    assert {:error, {:conflict, "request_id_used", _}} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "api"}], "batch")

    assert {:error, {:conflict, "item_assigned", _}} =
             Assignment.assign(user, p, plan.id, assignments, "another")
  end

  test "a member's new track uses the owner's subscription", %{
    user: owner,
    project: project,
    plan: plan
  } do
    Repo.update!(Ecto.Changeset.change(owner, credential_set_id: "owner-set"))
    member = insert_user(credential_set_id: "member-set")
    insert_project_member(project, member)
    {principal, _, _} = principal(member)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "member-conversation"}}}}
      ])

    stub(Fountain, :client, fn -> client end)

    expect(Fountain, :update_agent, fn _, agent_id, body ->
      assert agent_id == project.agent_id
      assert body["inference_credential_id"] == "owner-set"
      {:ok, %{}}
    end)

    assert {:ok, %{items: [%{track_id: id}]}} =
             Assignment.assign(member, principal, plan.id, [%{"item_id" => "api"}], "member")

    assert Repo.get!(Track, id).created_by_login == member.login
  end

  test "existing open tracks must belong to the same project; browser receipts require a live session",
       %{user: user, project: project, plan: plan, p: p} do
    track = insert_track(project: project, conversation_id: "existing")
    other = insert_track(project: insert_project(user: user))
    closed = insert_track(project: project, closed_at: DateTime.utc_now())

    for id <- [other.id, closed.id, "missing"] do
      assert {:error, :not_found} =
               Assignment.assign(
                 user,
                 p,
                 plan.id,
                 [%{"item_id" => "api", "track_id" => id}],
                 "bad-#{id}"
               )
    end

    {token, _} = insert_session(user)
    browser = Authorization.browser(user, Ravix.Crypto.sha256(token))

    assert {:ok, %{items: [%{track_id: id, task: task}]}} =
             Assignment.assign(
               user,
               browser,
               plan.id,
               [%{"item_id" => "api", "track_id" => track.id}],
               "browser"
             )

    assert id == track.id
    assert Repo.get!(Ravix.Tooling.Task, task.id).client_id == nil
    Ravix.Accounts.end_session(browser.session_hash)

    assert {:error, :unauthenticated} =
             Assignment.assign(user, browser, plan.id, [%{"item_id" => "ui"}], "revoked")

    assert {:error, {:forbidden, _}} =
             Assignment.assign(
               user,
               Map.put(p, :actor, {:track_agent, track.id}),
               plan.id,
               [%{"item_id" => "ui"}],
               "agent"
             )
  end

  test "blocked, archived, invalid, inaccessible and unconfirmed assignments do not provision twice",
       %{user: user, project: project, plan: plan, p: p} do
    assert {:ok, _} =
             Plans.update(user, plan.id, 1, %{
               "items" => [
                 %{"id" => "api", "title" => "API"},
                 %{"id" => "ui", "title" => "UI", "dependencies" => ["api"]}
               ]
             })

    assert {:error, {:conflict, "item_blocked", _}} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "ui"}], "blocked")

    assert {:error, :not_found} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "missing"}], "missing")

    assert {:error, {:unprocessable, _, _}} = Assignment.assign(user, p, plan.id, [], "empty")

    assert {:error, {:unprocessable, _, _}} =
             Assignment.assign(
               user,
               p,
               plan.id,
               [%{"item_id" => "api"}, %{"item_id" => "api"}],
               "dupe"
             )

    guest = insert_user()
    track = insert_track(project: project)
    insert_track_member(track, guest)
    {gp, _, _} = principal(guest)

    assert {:error, :not_found} =
             Assignment.assign(guest, gp, plan.id, [%{"item_id" => "api"}], "guest")

    assert {:error, :unauthenticated} =
             Assignment.assign(guest, p, plan.id, [%{"item_id" => "api"}], "mismatch")

    assert {:ok, _} = Plans.update(user, plan.id, 2, %{"archived" => true})

    assert {:error, {:conflict, "plan_archived", _}} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "api"}], "archived")

    assert {:ok, _} = Plans.update(user, plan.id, 3, %{"archived" => false})
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", nil) end)

    assert {:ok, %{items: [%{error: "assignment_unconfirmed"}]}} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "api"}], "failure")

    assert Repo.get!(Item, "api").assignment_request == "failure"
    assert {:ok, _} = Assignment.assign(user, p, plan.id, [%{"item_id" => "api"}], "failure")

    assert {:error, {:conflict, "operation_unconfirmed", _}} =
             Assignment.assign(user, p, plan.id, [%{"item_id" => "ui"}], "blocked")
  end

  test "MCP plan tools enforce both scopes and current membership and revocation", %{
    user: user,
    project: project,
    plan: plan,
    p: p
  } do
    assert {:ok, %{title: "Release", items: [_, _]}} =
             Tooling.call(p, "get_plan", %{"plan_id" => plan.id})

    assert {:ok, %{items: [_]}} = Tooling.call(p, "list_plans", %{"project_id" => project.id})

    assert {:ok, %{version: 2}} =
             Tooling.call(p, "update_plan", %{
               "plan_id" => plan.id,
               "expected_version" => 1,
               "summary" => "Updated"
             })

    assert {:ok, %{body: "Observation"}} =
             Tooling.call(p, "note_item", %{"item_id" => "api", "body" => "Observation"})

    assert {:ok, %{title: "Another"}} =
             Tooling.call(p, "create_plan", %{
               "project_id" => project.id,
               "title" => "Another",
               "items" => []
             })

    {read, _, _} = principal(user, "mcp", ["plans:read"])

    assert {:ok, %{tools: tools}} =
             MCP.call(read, %{"id" => 1, "method" => "tools/list"})

    assert Enum.map(tools, & &1.name) == ["get_plan", "list_plans"]
    {write, _, _} = principal(user, "mcp", ["plans:write"])

    assert {:ok, %{tools: tools}} =
             MCP.call(write, %{"id" => 1, "method" => "tools/list"})

    refute Enum.any?(tools, &(&1.name == "assign_items"))

    assert {:error, {:forbidden, _}} =
             Tooling.call(write, "assign_items", %{
               "plan_id" => plan.id,
               "assignments" => [%{"item_id" => "api"}],
               "request_id" => "scoped"
             })

    OAuth.disconnect(user, p.grant.id)
    assert {:error, :unauthenticated} = Tooling.call(p, "get_plan", %{"plan_id" => plan.id})
  end
end
