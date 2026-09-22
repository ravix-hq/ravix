defmodule Ravix.ToolingTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Projects.Project
  alias Ravix.Tooling
  alias Ravix.Tooling.OAuth
  alias Ravix.Tracks.Track
  import Ravix.ToolingFixture

  setup do
    user = insert_user()
    {p, _, _} = principal(user)
    %{user: user, p: p}
  end

  test "project and track listings identify the owner without renaming or leaking rows", %{
    user: owner,
    p: owner_principal
  } do
    project = insert_project(user: owner, name: "ravix")
    track = insert_track(project: project)
    sibling = insert_track(project: project)
    member = insert_user()
    guest = insert_user()
    insert_project_member(project, member)
    insert_track_member(track, guest)
    hidden = insert_project(user: insert_user(), name: "ravix")
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    for {user, ids} <- [
          {owner, [track.id, sibling.id]},
          {member, [track.id, sibling.id]},
          {guest, [track.id]}
        ] do
      {p, _, _} = principal(user)
      assert {:ok, %{items: [listed]}} = Tooling.call(p, "list_projects", %{})
      assert listed.id == project.id
      assert listed.name == "ravix"
      assert listed.owner_login == owner.login

      assert {:ok, %{items: tracks}} =
               Tooling.call(p, "list_tracks", %{"project_id" => project.id})

      assert Enum.sort(Enum.map(tracks, & &1.id)) == Enum.sort(ids)
      assert Enum.all?(tracks, &(&1.owner_login == owner.login))
      assert {:error, :not_found} = Tooling.call(p, "list_tracks", %{"project_id" => hidden.id})
    end

    assert {:ok, %{items: []}} =
             Tooling.call(elem(principal(insert_user()), 0), "list_projects", %{})

    assert {:ok, %{items: [%{name: "ravix"}]}} =
             Tooling.call(owner_principal, "list_projects", %{})
  end

  test "project creation returns a public receipt and repeated calls do not provision twice", %{
    p: p
  } do
    client =
      fountain([
        {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
        {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
        {%{method: "GET", path: "/api/catalog"},
         {200, [], %{data: %{runtimes: ["codex"], models: %{codex: ["openai/test-model"]}}}}},
        {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
      ])

    args = %{"name" => "Desktop", "request_id" => "create-project-1"}
    assert {:ok, result} = Tooling.call(p, "create_project", args)
    assert Repo.get!(Project, result.id).name == "Desktop"
    refute Map.has_key?(result, :vault_id)
    assert {:ok, retried} = Tooling.call(p, "create_project", args)
    assert retried["id"] == result.id
    assert length(FakeTransport.calls(client)) == 4

    assert {:error, {:conflict, "request_id_used", _}} =
             Tooling.call(p, "create_project", %{args | "name" => "Another"})

    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    assert {:ok, %{items: [project]}} = Tooling.call(p, "list_projects", %{})
    assert project.id == result.id
  end

  test "a refused or ambiguous creation is not repeated blindly", %{p: p} do
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", nil) end)
    args = %{"name" => "Desktop", "request_id" => "create-project-1"}
    assert {:error, {:unconfigured, :fountain}} = Tooling.call(p, "create_project", args)

    assert {:error, {:conflict, "operation_unconfirmed", _}} =
             Tooling.call(p, "create_project", args)
  end

  test "tracks open through the existing context and a track guest cannot create a sibling", %{
    p: p,
    user: user
  } do
    project = insert_project(user: user)
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)

    client =
      fountain([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "new-conversation"}}}}
      ])

    args = %{
      "project_id" => project.id,
      "branch_name" => "desktop-task",
      "request_id" => "open-track"
    }

    assert {:ok, result} = Tooling.call(p, "create_track", args)
    assert Repo.get!(Track, result.id).title == "ravix/desktop-task"
    assert result.branch == "ravix/desktop-task"
    assert {:ok, retry} = Tooling.call(p, "create_track", args)
    assert retry["id"] == result.id
    assert length(FakeTransport.calls(client)) == 2
    guest = insert_user()
    insert_track_member(Repo.get!(Track, result.id), guest)
    {guest_p, _, _} = principal(guest)
    assert {:error, :not_found} = Tooling.call(guest_p, "create_track", args)
    insert_project_member(project, guest)

    assert {:error, :not_found} =
             Tooling.call(guest_p, "update_project_settings", %{
               "project_id" => project.id,
               "settings" => %{},
               "request_id" => "x"
             })
  end

  test "MCP creation rejects invalid and closed-track branch names", %{p: p, user: user} do
    project = insert_project(user: user)
    insert_track(project: project, branch: "ravix/spent", closed_at: DateTime.utc_now())
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)

    for {name, code} <- [{"two words", "invalid_branch"}, {"spent", "branch_taken"}] do
      assert {:error, {:unprocessable, ^code, _}} =
               Tooling.call(p, "create_track", %{
                 "project_id" => project.id,
                 "branch_name" => name,
                 "request_id" => name
               })
    end
  end

  test "settings return keys without secret values and updates persist through owner access", %{
    p: p,
    user: user
  } do
    project =
      insert_project(user: user, environment_id: "env", vault_id: "vault", agent_id: "agent")

    fountain([
      {%{method: "GET", path: "/api/environments/env"},
       {200, [], %{data: %{setup_script: "echo hello", packages: %{apt: ["git"]}}}}},
      {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: %{runtimes: []}}}},
      {%{method: "GET", path: "/api/environments/env/secrets"},
       {200, [], %{data: [%{key: "TOKEN", value: "must-not-escape"}]}}},
      {%{method: "GET", path: "/api/vaults/vault/secrets"}, {200, [], %{data: []}}}
    ])

    assert {:ok, settings} =
             Tooling.call(p, "get_project_settings", %{"project_id" => project.id})

    assert settings.env_keys == ["TOKEN"]
    refute Jason.encode!(settings) =~ "must-not-escape"

    assert {:ok, %{updated: true}} =
             Tooling.call(p, "update_project_settings", %{
               "project_id" => project.id,
               "settings" => %{"name" => "Renamed"},
               "request_id" => "rename"
             })

    assert Repo.get!(Project, project.id).name == "Renamed"

    assert {:error, {:unprocessable, _, _}} =
             Tooling.call(p, "update_project_settings", %{
               "project_id" => project.id,
               "settings" => %{"secret" => %{}},
               "request_id" => "secret"
             })
  end

  test "transcript reads are paged, scoped and recheck revocation after the provider responds", %{
    p: p,
    user: user
  } do
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation")
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)

    expect(Fountain, :events_page, fn _, "conversation", opts ->
      assert opts[:after] == 10
      assert opts[:limit] == 3

      {:ok,
       %{
         events: [%{"id" => 11, "kind" => "output", "data" => "hello", "private_field" => "omit"}],
         next_cursor: 11,
         has_more: true
       }}
    end)

    assert {:ok, %{events: [event], next_cursor: 11, has_more: true}} =
             Tooling.call(p, "read_track", %{"track_id" => track.id, "after" => 10, "limit" => 3})

    refute Map.has_key?(event, "private_field")

    expect(Fountain, :events_page, fn _, _, _ ->
      OAuth.disconnect(user, p.grant.id)
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    assert {:error, :unauthenticated} = Tooling.call(p, "read_track", %{"track_id" => track.id})
  end

  test "project and track lists preserve track-only membership", %{p: p, user: user} do
    project = insert_project()
    allowed = insert_track(project: project)
    insert_track(project: project)
    insert_track_member(allowed, user)
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Ravix.MachineCache, :environment, fn _, _ -> {:ok, %{}} end)

    assert {:ok, %{items: [track]}} =
             Tooling.call(p, "list_tracks", %{"project_id" => project.id})

    assert track.id == allowed.id
    assert {:ok, %{id: id}} = Tooling.call(p, "get_track", %{"track_id" => allowed.id})
    assert id == allowed.id

    assert {:error, :not_found} =
             Tooling.call(p, "get_project_settings", %{"project_id" => project.id})

    assert {:error, _} = Tooling.call(p, "list_repositories", %{})
  end

  defp fountain(expectations) do
    client = FakeTransport.client(expectations)
    stub(Fountain, :client, fn -> client end)
    client
  end
end
