defmodule Ravix.Workspaces.MoveProjectTest do
  @moduledoc """
  Moving a project between workspaces: its owner only, only into a
  workspace where they are an owner or admin, never onto a project of the
  same repository. Tracks, legacy members and permission rows stay; private
  tracks stay private; open pages are told after the commit.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use Ravix.DataCase, async: false

  import Ravix.Factory

  alias Ravix.Accounts.Access
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.Projects.Project
  alias Ravix.Tracks.TrackPermission
  alias Ravix.Workspaces
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    owner = insert_user(login: "owner")
    boss = insert_user(login: "boss")
    teammate = insert_user(login: "teammate")
    legacy = insert_user(login: "legacy")

    {:ok, personal} = Store.ensure_personal_workspace(owner)
    {:ok, acme} = Workspaces.create(owner, "Acme")
    {:ok, beta} = Workspaces.create(boss, "Beta")
    :ok = Store.add_member(beta.id, owner.id, :admin, boss.id)
    :ok = Store.add_member(beta.id, teammate.id, :member, boss.id)
    {:ok, gamma} = Workspaces.create(boss, "Gamma")
    :ok = Store.add_member(gamma.id, owner.id, :member, boss.id)

    project = insert_project(user: owner, name: "app", repo_full_name: "owner/app")
    1 = Store.move_project(project.id, acme.id)
    project = Repo.get!(Project, project.id)
    insert_project_member(project, legacy)

    open = insert_track(project: project, visibility: :project, created_by: owner.id)
    private = insert_track(project: project, visibility: :private, created_by: owner.id)

    %{
      owner: owner,
      boss: boss,
      teammate: teammate,
      legacy: legacy,
      personal: personal,
      acme: acme,
      beta: beta,
      gamma: gamma,
      project: project,
      open: open,
      private: private
    }
  end

  defp reload(%Project{id: id}), do: Repo.get!(Project, id)

  test "the owner's targets are their owner and admin workspaces but the current one", ctx do
    assert {:ok, %{current: current, targets: targets}} =
             Workspaces.move_targets(ctx.owner, ctx.project.id)

    assert current.id == ctx.acme.id
    assert Enum.map(targets, & &1.id) == [ctx.personal.id, ctx.beta.id]

    assert {:error, :not_found} = Workspaces.move_targets(ctx.legacy, ctx.project.id)
    assert {:error, :not_found} = Workspaces.move_targets(ctx.boss, ctx.project.id)
  end

  test "the owner moves it into a workspace they administer, keeping tracks and grants", ctx do
    Repo.insert!(%TrackPermission{
      track_id: ctx.private.id,
      user_id: ctx.teammate.id,
      workspace_id: ctx.acme.id,
      granted_by_user_id: ctx.owner.id,
      created_at: DateTime.utc_now()
    })

    Hub.subscribe(ctx.project.id)
    Hub.subscribe_workspace(ctx.acme.id)
    Hub.subscribe_workspace(ctx.beta.id)

    refute Access.visible_track?(ctx.teammate.id, ctx.open, ctx.project)

    assert {:ok, %Project{workspace_id: beta_id}} =
             Workspaces.move_project(ctx.owner, ctx.project.id, ctx.beta.id)

    assert beta_id == ctx.beta.id

    # Every open page on the project and on both workspaces re-reads.
    assert_receive {:hub, %Event{name: :people, project_id: project_id, track_id: nil}}
    assert project_id == ctx.project.id
    assert_receive {:workspace_hub, acme_id, :members}
    assert_receive {:workspace_hub, ^beta_id, :members}
    assert acme_id == ctx.acme.id

    moved = reload(ctx.project)
    assert moved.user_id == ctx.owner.id
    assert Repo.get!(Ravix.Tracks.Track, ctx.open.id).project_id == moved.id
    assert Repo.get!(Ravix.Tracks.Track, ctx.private.id).project_id == moved.id

    # The legacy member keeps their grant and is not promoted into Beta.
    assert {:ok, %{role: :member}} = Access.project_access(ctx.legacy, moved.id)
    assert Store.membership(ctx.beta.id, ctx.legacy.id) == nil
    assert Access.visible_track?(ctx.legacy.id, ctx.open, moved)

    # Beta's members see the workspace-visible track, not the private one.
    assert Access.visible_track?(ctx.teammate.id, ctx.open, moved)
    refute Access.visible_track?(ctx.teammate.id, ctx.private, moved)
    assert Access.visible_track?(ctx.owner.id, ctx.private, moved)

    # The permission row is kept as it was, and counts only in Acme.
    assert [%TrackPermission{workspace_id: acme_row}] = Repo.all(TrackPermission)
    assert acme_row == ctx.acme.id
  end

  test "a legacy project moves out of the legacy layout", ctx do
    legacy_project = insert_project(user: ctx.owner, repo_full_name: "owner/legacy")

    assert {:ok, moved} = Workspaces.move_project(ctx.owner, legacy_project.id, ctx.personal.id)
    assert moved.workspace_id == ctx.personal.id
    assert moved.normalized_repo_full_name == "owner/legacy"
  end

  test "anybody but the owner is refused, a workspace admin included", ctx do
    assert {:error, :not_found} = Workspaces.move_project(ctx.legacy, ctx.project.id, ctx.beta.id)
    assert {:error, :not_found} = Workspaces.move_project(ctx.boss, ctx.project.id, ctx.beta.id)
    assert reload(ctx.project).workspace_id == ctx.acme.id
  end

  test "a workspace where the owner is only a member, or not one, is refused", ctx do
    assert {:error, {:forbidden, _}} =
             Workspaces.move_project(ctx.owner, ctx.project.id, ctx.gamma.id)

    {:ok, stranger} = Store.ensure_personal_workspace(ctx.boss)

    assert {:error, :not_found} =
             Workspaces.move_project(ctx.owner, ctx.project.id, stranger.id)

    assert {:error, {:conflict, "same_workspace", _}} =
             Workspaces.move_project(ctx.owner, ctx.project.id, ctx.acme.id)

    assert reload(ctx.project).workspace_id == ctx.acme.id
  end

  test "a target that already has the repository is refused, pointing to its project", ctx do
    existing = insert_project(user: ctx.boss, name: "Beta app", repo_full_name: "Owner/App")
    1 = Store.move_project(existing.id, ctx.beta.id)

    assert {:error, {:repository_taken, %{id: id, name: "Beta app", workspace: "Beta"}}} =
             Workspaces.move_project(ctx.owner, ctx.project.id, ctx.beta.id)

    assert id == existing.id
    assert reload(ctx.project).workspace_id == ctx.acme.id
  end

  test "with the switch off nothing moves", ctx do
    Application.put_env(:ravix, :workspace_access, false)
    assert {:error, :not_found} = Workspaces.move_project(ctx.owner, ctx.project.id, ctx.beta.id)
    assert {:error, :not_found} = Workspaces.move_targets(ctx.owner, ctx.project.id)
  end

  test "a project moved or archived since it was read is not found", ctx do
    assert {:error, :not_found} =
             Store.move_owned_project(ctx.project.id, ctx.owner.id, nil, ctx.beta.id)

    assert {:error, :not_found} =
             Store.move_owned_project(ctx.project.id, ctx.boss.id, ctx.acme.id, ctx.beta.id)
  end
end
