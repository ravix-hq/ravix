defmodule Ravix.MergedProjectLifecycleTest do
  use Ravix.DataCase, async: true
  import Mimic
  setup :verify_on_exit!

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Projects.Deletion
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Tracks.Sandbox
  alias Ravix.Tracks.Sandbox.Store

  test "the last shared track retires only its retained machine and releases its own fence" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> true end)
    project = insert_project()
    resource = insert_project_resource(project)
    bound = Projects.for_resource(project, resource.id)
    sibling = insert_track(project: project)
    first = insert_track(project: project, resource_id: resource.id)
    last = insert_track(project: project, resource_id: resource.id)

    assert {:ok, :ok} = Store.close_shared(first, bound)
    assert Store.operations(first.id) == []
    assert {:ok, :ok} = Store.close_shared(last, bound)
    [operation] = Store.operations(last.id)

    assert {:error, {:conflict, "machine_cleanup_pending", _}} =
             Store.shared_open(bound, fn -> flunk("retiring resource admitted a new track") end)

    assert :allowed = Store.shared_open(project, fn -> :allowed end)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/sandboxes"},
         {200, [],
          %{
            data: [
              %{
                id: "canonical-machine",
                agent_id: project.agent_id,
                environment_id: project.environment_id,
                vault_id: project.vault_id
              },
              %{
                id: "retained-machine",
                agent_id: resource.agent_id,
                environment_id: resource.environment_id,
                vault_id: resource.vault_id
              }
            ]
          }}},
        {%{method: "DELETE", path: "/api/sandboxes/retained-machine"}, {204, [], ""}},
        {%{method: "GET", path: "/api/sandboxes/retained-machine"},
         {200, [], %{data: %{id: "retained-machine", status: "terminated"}}}}
      ])

    Sandbox.advance(client, operation.id)

    assert Store.get_operation(operation.id).phase == "done"
    assert :allowed = Store.shared_open(bound, fn -> :allowed end)
    assert Store.get_track(sibling.id).closed_at == nil
    assert Repo.reload!(resource).vault_id == resource.vault_id
    assert Repo.reload!(project).agent_id == project.agent_id
  end

  test "project deletion records independent cleanup for every retained shared machine" do
    project = insert_project()
    resource = insert_project_resource(project)
    first = insert_track(project: project)
    second = insert_track(project: project, resource_id: resource.id)

    assert {:ok, :ok} = Projects.request_deletion(project)
    assert Store.get_track(first.id).closed_at
    assert Store.get_track(second.id).closed_at
    [canonical] = Store.operations(first.id)
    [retained] = Store.operations(second.id)
    assert canonical.resource_ids["agent_id"] == project.agent_id
    assert retained.resource_ids["agent_id"] == resource.agent_id
    assert retained.resource_ids["shared_tracks"] == [second.id]
    assert canonical.resource_ids["shared_tracks"] == [first.id]
    refute Store.project_clean?(project.id)
  end

  test "merged default machines honor retirement even outside the maintenance rollout" do
    stub(Ravix.Config, :retire_shared_machines?, fn -> false end)
    stub(Ravix.Config, :dedicated_rollout?, fn -> false end)
    project = insert_project()
    insert_project_resource(project)
    Projects.set_retiring(project, true)

    assert {:error, {:conflict, "machine_cleanup_pending", _}} =
             Store.shared_open(project, fn -> flunk("retiring machine admitted a new track") end)
  end

  test "deletion removes every original provider resource before archiving the project" do
    project = insert_project()
    resource = insert_project_resource(project)
    assert {:ok, :ok} = Projects.request_deletion(project)

    routes =
      for source <- [project, resource],
          {kind, id} <- [
            {"agents", source.agent_id},
            {"vaults", source.vault_id},
            {"environments", source.environment_id}
          ],
          is_binary(id) do
        {%{method: "DELETE", path: "/api/#{kind}/#{id}"}, {204, [], ""}}
      end

    Deletion.advance(FakeTransport.client(routes), project)
    assert Repo.reload!(project).archived_at
    assert Repo.reload!(resource).runtime_agents_retiring
  end
end
