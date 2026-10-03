defmodule Ravix.Projects.ConsolidationTest do
  use Ravix.DataCase, async: false
  use Mimic
  import Ravix.Factory
  setup :verify_on_exit!
  alias Ravix.Plans.Plan
  alias Ravix.Projects.{Consolidation, Project}
  alias Ravix.Routines.Routine
  alias Ravix.Schedules.Schedule
  alias Ravix.Projects.Consolidation.Store
  alias Ravix.Tracks.Track

  setup do
    user = insert_user()
    {:ok, workspace} = Ravix.Workspaces.Store.ensure_personal_workspace(user)
    canonical = insert_project(user: user, repo_full_name: "Example/App")
    canonical = canonical |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
    donor = insert_project(user: user, repo_full_name: " example/app ")

    donor =
      donor
      |> Ecto.Changeset.change(
        workspace_id: workspace.id,
        legacy_duplicate_of: canonical.id,
        legacy_duplicate_at: DateTime.utc_now()
      )
      |> Repo.update!()

    %{user: user, workspace: workspace, canonical: canonical, donor: donor}
  end

  test "dry run inventories only duplicates in its workspace and writes nothing", ctx do
    other = insert_project(repo_full_name: "Example/App")

    assert {:ok, %{applied: false, groups: [group], merged: []}} =
             Consolidation.run(ctx.workspace.id)

    assert group.canonical_id == ctx.canonical.id
    assert group.donor_ids == [ctx.donor.id]
    assert Repo.get!(Project, ctx.donor.id).agent_id == ctx.donor.agent_id
    assert Repo.get!(Project, other.id).workspace_id == nil
  end

  test "merge preserves overlapping active worktrees, conversations, runtime agents and defaults",
       ctx do
    a =
      insert_track(
        project: ctx.canonical,
        slug: "same",
        branch: "same",
        conversation_id: "conversation-a"
      )

    b =
      insert_track(
        project: ctx.donor,
        slug: "same",
        branch: "same",
        conversation_id: "conversation-b"
      )

    insert_preview_default(ctx.canonical)
    insert_preview_default(ctx.donor)

    for project <- [ctx.canonical, ctx.donor] do
      Repo.query!(
        "INSERT INTO ravix.project_runtime_agents (project_id, runtime, agent_id) VALUES ($1, 'codex', $2)",
        [project.id, "extra-" <> project.id]
      )
    end

    assert {:ok, %{applied: true, merged: [%{removed_id: removed}]}} =
             Consolidation.run(ctx.workspace.id, apply: true)

    assert removed == ctx.donor.id
    moved = Repo.get!(Track, b.id)
    assert moved.project_id == ctx.canonical.id
    assert moved.closed_at == nil
    assert moved.conversation_id == b.conversation_id
    assert moved.workdir == b.workdir
    assert moved.slug == b.slug
    assert moved.branch == b.branch
    assert Repo.get!(Track, a.id).conversation_id == a.conversation_id

    assert %{rows: [[resource_id, owner, agent, environment, vault]]} =
             Repo.query!(
               "SELECT id, user_id, agent_id, environment_id, vault_id FROM ravix.project_resources WHERE project_id = $1",
               [ctx.canonical.id]
             )

    assert {resource_id, owner, agent, environment, vault} ==
             {ctx.donor.id, ctx.donor.user_id, ctx.donor.agent_id, ctx.donor.environment_id,
              ctx.donor.vault_id}

    assert %{rows: [[2]]} =
             Repo.query!("SELECT count(*) FROM ravix.preview_defaults WHERE project_id = $1", [
               ctx.canonical.id
             ])

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM ravix.project_runtime_agents WHERE project_id = $1",
               [ctx.canonical.id]
             )

    source = Ravix.Projects.Store.for_resource(ctx.canonical, ctx.donor.id)
    Ravix.Projects.Store.bind_runtime(source, "codex", "source-replaced", nil)
    assert [%{agent_id: "source-replaced"}] = Ravix.Projects.Store.runtime_agents(source)
    assert [%{agent_id: default_agent}] = Ravix.Projects.Store.runtime_agents(ctx.canonical)
    assert default_agent == "extra-" <> ctx.canonical.id
    Ravix.Projects.Store.forget_runtime(source, "codex")
    assert :ok = Ravix.Projects.Store.reserve_runtime(source, "codex", source.agent_id)
    assert [%{agent_id: ^default_agent}] = Ravix.Projects.Store.runtime_agents(ctx.canonical)

    assert {:ok, %{merged: []}} = Consolidation.run(ctx.workspace.id, apply: true)

    assert Repo.aggregate(from(p in Project, where: p.workspace_id == ^ctx.workspace.id), :count) ==
             1
  end

  test "guests retain their original visible tracks and direct roles without sibling access",
       ctx do
    guest = insert_user()
    insert_project_member(ctx.donor, guest, role: :read)
    track = insert_track(project: ctx.donor)
    private = insert_track(project: ctx.donor, visibility: :private)
    sibling = insert_track(project: ctx.canonical)
    insert_track_member(track, guest, role: :admin)
    insert_project_invite(ctx.donor)
    {_token, _link} = insert_project_link(ctx.donor)

    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)

    assert %{rows: [[id, "admin"]]} =
             Repo.query!("SELECT track_id, role FROM ravix.track_members WHERE user_id = $1", [
               guest.id
             ])

    assert id == track.id

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM ravix.track_members WHERE user_id = $1 AND track_id = ANY($2)",
               [guest.id, [private.id, sibling.id]]
             )

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM ravix.resource_invites WHERE resource_id = $1", [
               ctx.donor.id
             ])

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM ravix.resource_links WHERE resource_id = $1", [
               ctx.donor.id
             ])
  end

  test "historical canonical and donor links remain scoped to their original public tracks",
       ctx do
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    canonical_track = insert_track(project: ctx.canonical)
    donor_track = insert_track(project: ctx.donor)
    insert_track(project: ctx.canonical, visibility: :private)
    insert_track(project: ctx.donor, visibility: :private)
    {canonical_token, _} = insert_project_link(ctx.canonical)
    {donor_token, _} = insert_project_link(ctx.donor)
    canonical_guest = insert_user()
    donor_guest = insert_user()

    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)
    assert {:ok, _} = Ravix.People.link_target(donor_token, donor_guest)
    assert {:ok, _} = Ravix.People.claim_link(canonical_guest.id, canonical_token)
    assert {:ok, _} = Ravix.People.claim_link(donor_guest.id, donor_token)

    for {guest, track} <- [{canonical_guest, canonical_track}, {donor_guest, donor_track}] do
      assert %{rows: [[id]]} =
               Repo.query!("SELECT track_id FROM ravix.track_members WHERE user_id = $1", [
                 guest.id
               ])

      assert id == track.id
    end

    stub(Ravix.Config, :workspace_access?, fn -> true end)
    assert :retired = Ravix.People.claim_link(insert_user().id, donor_token)
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    assert :ok = Ravix.People.drop_project_link(ctx.user, ctx.canonical.id)
    assert :error = Ravix.People.claim_link(insert_user().id, donor_token)
    assert :error = Ravix.People.claim_link(insert_user().id, canonical_token)
  end

  test "historical login invitations grant only original visible tracks", ctx do
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    a = insert_track(project: ctx.canonical)
    b = insert_track(project: ctx.donor)
    guest = insert_user()
    insert_project_invite(ctx.canonical, github_id: guest.github_id)
    donor_guest = insert_user()
    insert_project_invite(ctx.donor, github_id: donor_guest.github_id)
    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)
    Ravix.People.Store.claim_invites(guest.id, guest.github_id)
    Ravix.People.Store.claim_invites(donor_guest.id, donor_guest.github_id)

    for {user, track} <- [{guest, a}, {donor_guest, b}] do
      assert %{rows: [[id]]} =
               Repo.query!("SELECT track_id FROM ravix.track_members WHERE user_id = $1", [
                 user.id
               ])

      assert id == track.id
    end
  end

  test "plans, schedules and webhook routines retain IDs, content, credentials and original resource",
       ctx do
    plan =
      %Plan{project_id: ctx.donor.id, created_by_login: ctx.user.login}
      |> Plan.changeset(%{title: "Release", summary: "Existing plan"})
      |> Repo.insert!()

    schedule =
      %Schedule{project_id: ctx.donor.id, user_id: ctx.user.id, next_run_at: DateTime.utc_now()}
      |> Schedule.changeset(%{name: "Review", prompt: "Existing scheduled prompt"})
      |> Repo.insert!()

    routine =
      %Routine{
        project_id: ctx.donor.id,
        user_id: ctx.user.id,
        credential_hash: Ravix.Crypto.sha256("fixture-token")
      }
      |> Routine.changeset(%{name: "Triage", prompt: "Existing webhook prompt"})
      |> Repo.insert!()

    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)

    for row <- [plan, schedule, routine] do
      assert Repo.reload!(row) == %{row | project_id: ctx.canonical.id, resource_id: ctx.donor.id}
    end
  end

  test "retained link remains discoverable and revocable through canonical settings", ctx do
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    insert_track(project: ctx.donor)
    {token, _} = insert_project_link(ctx.donor)
    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)

    assert {:ok, %Ravix.People.InviteLink{}} =
             Ravix.People.project_link(ctx.user, ctx.canonical.id)

    assert :ok = Ravix.People.drop_project_link(ctx.user, ctx.canonical.id)
    assert {:ok, nil} = Ravix.People.project_link(ctx.user, ctx.canonical.id)
    assert :error = Ravix.People.claim_link(insert_user().id, token)
  end

  test "a consolidated workspace rejects a repository duplicate even when normalized name is omitted",
       ctx do
    assert {:ok, _} = Consolidation.run(ctx.workspace.id, apply: true)
    extra = insert_project(user: ctx.user, repo_full_name: " EXAMPLE/APP ")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               "UPDATE ravix.projects SET workspace_id = $1, normalized_repo_full_name = NULL WHERE id = $2",
               [ctx.workspace.id, extra.id]
             )
  end

  test "cross-workspace and cross-repository pairs are rejected atomically", ctx do
    foreign = insert_project(repo_full_name: "Example/App")

    assert {:error, :different_workspace} =
             Store.merge(ctx.workspace.id, ctx.canonical.id, foreign.id)

    different =
      insert_project(user: ctx.user, repo_full_name: "example/another")
      |> Ecto.Changeset.change(workspace_id: ctx.workspace.id)
      |> Repo.update!()

    assert {:error, :different_repository} =
             Store.merge(ctx.workspace.id, ctx.canonical.id, different.id)

    assert Repo.get!(Project, different.id).repo_full_name == "example/another"
    assert Repo.get!(Project, ctx.donor.id).agent_id == ctx.donor.agent_id
  end
end
