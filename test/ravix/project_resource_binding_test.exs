defmodule Ravix.ProjectResourceBindingTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Access
  alias Ravix.Fountain.FakeTransport
  alias Ravix.MachineCache
  alias Ravix.Projects.{RuntimeAgents, Store}
  alias Ravix.Tracks.{Billing, Track}

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup do
    owner = insert_user()
    payer = insert_user()
    project = insert_project(user: owner)
    resource = insert_project_resource(project, user: payer, runtime: "codex")
    track = insert_track(project: project, resource_id: resource.id)
    %{owner: owner, payer: payer, project: project, resource: resource, track: track}
  end

  test "track access preserves canonical authorization and its original payer and provider identity",
       ctx do
    assert {:ok, %{role: :owner, project: bound}} = Access.track_access(ctx.owner, ctx.track.id)
    assert bound.id == ctx.project.id
    assert bound.user_id == ctx.owner.id
    assert bound.agent_id == ctx.resource.agent_id
    assert bound.environment_id == ctx.resource.environment_id
    assert bound.vault_id == ctx.resource.vault_id
    assert bound.resource_owner_id == ctx.payer.id
    assert Track.payer(ctx.track, bound) == {:legacy_owner, ctx.payer.id}
    assert {:ok, payer} = Billing.payer(ctx.track, bound)
    assert payer.id == ctx.payer.id
    assert {:error, :not_found} = Access.track_access(ctx.payer, ctx.track.id)

    private =
      insert_track(
        project: ctx.project,
        resource_id: ctx.resource.id,
        visibility: :private,
        created_by: ctx.payer.id
      )

    insert_project_member(ctx.project, ctx.payer)
    assert {:ok, %{project: private_project}} = Access.track_access(ctx.payer, private.id)
    assert private_project.agent_id == ctx.resource.agent_id
    assert {:error, :not_found} = Access.track_access(ctx.owner, private.id)
  end

  test "source credentials and home selection update only the retained resource", ctx do
    bound = Store.for_track(ctx.project, ctx.track)
    assert :ok = Store.set_credential_set(bound, "source-set")
    assert {:ok, "codex"} = Store.claim_shared_home(bound, "codex", bound.agent_id)
    assert Store.for_track(ctx.project, ctx.track).credential_set_id == "source-set"
    assert Store.for_track(ctx.project, ctx.track).shared_home_runtime == "codex"
    assert Store.get_project(ctx.project.id).credential_set_id == ctx.project.credential_set_id
    assert Store.get_project(ctx.project.id).shared_home_runtime == nil
    assert RuntimeAgents.owner(bound).id == ctx.payer.id
  end

  test "shared tracks on distinct resource bindings resolve their original machines", ctx do
    canonical_track = insert_track(project: ctx.project)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: ctx.resource.agent_id}},
         {200, [],
          %{
            data: [
              %{
                id: "source-c",
                sandbox_id: "source-box",
                status: "idle",
                inserted_at: "2026-10-01"
              }
            ]
          }}},
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: ctx.project.agent_id}},
         {200, [],
          %{
            data: [
              %{
                id: "canonical-c",
                sandbox_id: "canonical-box",
                status: "idle",
                inserted_at: "2026-10-02"
              }
            ]
          }}}
      ])

    assert {:ok, %{sandbox_id: "source-box"}} =
             MachineCache.machine_for_track(client, ctx.project, ctx.track)

    assert {:ok, %{sandbox_id: "canonical-box"}} =
             MachineCache.machine_for_track(client, ctx.project, canonical_track)
  end

  test "the project list includes active tracks from every retained machine", ctx do
    canonical = insert_track(project: ctx.project)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: ctx.resource.agent_id}},
         {200, [], %{data: []}}},
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: ctx.project.agent_id}},
         {200, [], %{data: []}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)

    views = Ravix.Tracks.list_many(ctx.owner, [ctx.project.id])

    assert Enum.sort(Enum.map(views[ctx.project.id], & &1.id)) ==
             Enum.sort([ctx.track.id, canonical.id])

    assert {:ok, same} = Ravix.Tracks.list(ctx.owner, ctx.project.id)
    assert Enum.map(same, & &1.id) == Enum.map(views[ctx.project.id], & &1.id)
  end

  test "machine-local slug and branch reservations coexist after consolidation", ctx do
    insert_track(project: ctx.project, slug: "same", branch: "ravix/same")

    source =
      insert_track(
        project: ctx.project,
        resource_id: ctx.resource.id,
        slug: "same",
        branch: "ravix/same"
      )

    assert source.closed_at == nil
    assert source.slug == "same"
    assert source.branch == "ravix/same"
  end

  test "changing canonical secrets does not invalidate another resource's dedicated work", ctx do
    attrs = [sandbox_layout: :dedicated, sandbox_state: :ready, setup_state: "complete"]
    canonical = insert_track([project: ctx.project] ++ attrs)
    retained = insert_track([project: ctx.project, resource_id: ctx.resource.id] ++ attrs)

    assert {:ok, 1} = Store.begin_secret_change(ctx.project.id)
    assert Repo.get!(Track, canonical.id).setup_error_code == "secrets_changed"
    assert Repo.get!(Track, retained.id).setup_state == "complete"
    assert Store.for_track(ctx.project, retained).secrets_generation == 0
  end

  test "adopting credentials charges the retained owner and persists only its binding", ctx do
    payer =
      ctx.payer
      |> Ecto.Changeset.change(credential_set_id: "original-owner-set")
      |> Repo.update!()

    bound = Store.for_track(ctx.project, ctx.track)

    client =
      FakeTransport.client([
        {%{method: "PUT", path: "/api/agents/#{ctx.resource.agent_id}"},
         fn request ->
           assert request.body["inference_credential_id"] == payer.credential_set_id
           {200, [], %{data: %{id: ctx.resource.agent_id}}}
         end}
      ])

    assert {:ok, agent_id} = RuntimeAgents.ensure(bound, client, "codex", bound.model)
    assert agent_id == ctx.resource.agent_id
    assert Store.for_track(ctx.project, ctx.track).credential_set_id == payer.credential_set_id
    assert Store.get_project(ctx.project.id).credential_set_id == ctx.project.credential_set_id
  end
end
