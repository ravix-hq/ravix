defmodule Ravix.Workspaces.SettingsPagesTest do
  @moduledoc """
  RAV-73's context half: a workspace's projects as its Projects page lists
  them, leaving a workspace, and deleting one, each at the door
  (`Ravix.Accounts.Access`) with every role, and with somebody else's
  workspace.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use Ravix.DataCase, async: false

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
    admin = insert_user(login: "adm")
    member = insert_user(login: "mem")
    {:ok, personal} = Store.ensure_personal_workspace(owner)
    {:ok, team} = Workspaces.create(owner, "Acme")
    :ok = Store.add_member(team.id, admin.id, :admin, owner.id)
    :ok = Store.add_member(team.id, member.id, :member, owner.id)
    Ravix.Hub.subscribe_workspace(team.id)

    %{owner: owner, admin: admin, member: member, personal: personal, team: team}
  end

  defp in_workspace(project, workspace_id),
    do: project |> Ecto.Changeset.change(workspace_id: workspace_id) |> Repo.update!()

  describe "projects/2" do
    test "lists live projects by name with owner and everybody who reaches them", ctx do
      outsider = insert_user(login: "out")

      web =
        insert_project(user: ctx.admin, name: "web", repo_full_name: "acme/web")
        |> in_workspace(ctx.team.id)

      insert_project_member(web, outsider, role: :read)

      _api =
        insert_project(user: ctx.owner, name: "API", runtime: "codex")
        |> in_workspace(ctx.team.id)

      _archived =
        insert_project(user: ctx.owner, name: "gone", archived_at: DateTime.utc_now())
        |> in_workspace(ctx.team.id)

      _elsewhere = insert_project(user: ctx.owner, name: "mine") |> in_workspace(ctx.personal.id)

      assert {:ok, [api, web_row]} = Workspaces.projects(ctx.member, ctx.team.id)
      assert api.project.name == "API" and api.owner.id == ctx.owner.id and api.people == 3
      assert web_row.project.id == web.id and web_row.owner.login == "adm"
      # Three members, and the outsider granted Read directly.
      assert web_row.people == 4
    end

    test "is not found for a stranger, a made-up id, and with the switch off", ctx do
      stranger = insert_user()
      assert {:error, :not_found} = Workspaces.projects(stranger, ctx.team.id)
      assert {:error, :not_found} = Workspaces.projects(ctx.owner, "does-not-exist")

      Application.put_env(:ravix, :workspace_access, false)
      assert {:error, :not_found} = Workspaces.projects(ctx.owner, ctx.team.id)
    end
  end

  describe "leave/2" do
    test "a member leaves, loses their project grants there, and open pages hear it", ctx do
      project = insert_project(user: ctx.owner) |> in_workspace(ctx.team.id)
      insert_project_member(project, ctx.member, role: :read)

      assert :ok = Workspaces.leave(ctx.member, ctx.team.id)
      assert Store.membership(ctx.team.id, ctx.member.id) == nil
      assert Repo.get_by(Ravix.Projects.ProjectMember, user_id: ctx.member.id) == nil
      assert_receive {:workspace_hub, _id, :members}
      assert {:error, :not_found} = Workspaces.leave(ctx.member, ctx.team.id)
    end

    test "an owner leaves while another owner remains; the last owner cannot", ctx do
      assert {:error, {:conflict, "last_owner", message}} =
               Workspaces.leave(ctx.owner, ctx.team.id)

      assert message =~ "only owner"
      assert %{role: :owner} = Store.membership(ctx.team.id, ctx.owner.id)

      :ok = Workspaces.set_role(ctx.owner, ctx.team.id, ctx.admin.id, "owner")
      assert :ok = Workspaces.leave(ctx.owner, ctx.team.id)
      assert Store.membership(ctx.team.id, ctx.owner.id) == nil
    end

    test "nobody leaves their own personal workspace; a stranger's is not found", ctx do
      assert {:error, {:unprocessable, "personal", _}} =
               Workspaces.leave(ctx.owner, ctx.personal.id)

      assert {:error, :not_found} = Workspaces.leave(ctx.member, ctx.personal.id)
      assert %{role: :owner} = Store.membership(ctx.personal.id, ctx.owner.id)
    end

    test "is not behind the switch: taking access away is always safe", ctx do
      Application.put_env(:ravix, :workspace_access, false)
      assert :ok = Workspaces.leave(ctx.member, ctx.team.id)
    end
  end

  describe "delete/3" do
    test "an owner deletes an empty team workspace with its name typed", ctx do
      assert {:error, {:unprocessable, "confirm", _}} =
               Workspaces.delete(ctx.owner, ctx.team.id, "acme")

      assert {:error, {:unprocessable, "confirm", _}} =
               Workspaces.delete(ctx.owner, ctx.team.id, nil)

      assert Store.live_workspace(ctx.team.id)

      assert :ok = Workspaces.delete(ctx.owner, ctx.team.id, " Acme ")
      assert Store.live_workspace(ctx.team.id) == nil
      assert_receive {:workspace_hub, _id, :members}
      assert {:error, :not_found} = Workspaces.get(ctx.member, ctx.team.id)
      assert {:error, :not_found} = Workspaces.delete(ctx.owner, ctx.team.id, "Acme")
    end

    test "admins and members are refused; strangers and made-up ids are not found", ctx do
      stranger = insert_user()

      for user <- [ctx.admin, ctx.member] do
        assert {:error, {:forbidden, _}} = Workspaces.delete(user, ctx.team.id, "Acme")
      end

      assert {:error, :not_found} = Workspaces.delete(stranger, ctx.team.id, "Acme")
      assert {:error, :not_found} = Workspaces.delete(ctx.owner, "does-not-exist", "Acme")
      assert Store.live_workspace(ctx.team.id)
    end

    test "a workspace with a live project is kept until it is moved", ctx do
      project = insert_project(user: ctx.owner) |> in_workspace(ctx.team.id)

      assert {:error, {:conflict, "has_projects", message}} =
               Workspaces.delete(ctx.owner, ctx.team.id, "Acme")

      assert message == "Acme still has 1 project. Move or delete them first."
      assert Store.live_workspace(ctx.team.id)

      project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
      assert :ok = Workspaces.delete(ctx.owner, ctx.team.id, "Acme")
    end

    test "a personal workspace cannot be deleted", ctx do
      assert {:error, {:unprocessable, "personal", _}} =
               Workspaces.delete(ctx.owner, ctx.personal.id, ctx.personal.name)

      assert Store.live_workspace(ctx.personal.id)
    end

    test "an owner demoted before the lock is taken cannot finish it", ctx do
      assert {:error, :not_owner} = Store.archive_workspace(ctx.team.id, ctx.admin.id)
      assert {:error, :actor_gone} = Store.archive_workspace(ctx.team.id, insert_user().id)
      assert Store.live_workspace(ctx.team.id)
    end

    test "is refused with the switch off", ctx do
      Application.put_env(:ravix, :workspace_access, false)
      assert {:error, :not_found} = Workspaces.delete(ctx.owner, ctx.team.id, "Acme")
    end
  end
end
