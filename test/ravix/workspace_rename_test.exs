defmodule Ravix.WorkspaceRenameTest do
  @moduledoc """
  RAV-72: a workspace's name, which its owners and admins change from
  General in its settings. Its kind never changes.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use Ravix.DataCase, async: false

  import Ravix.Factory

  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Store, Workspace}

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
    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, team: team}
  end

  test "owners and admins rename; the name is trimmed and members hear of it", ctx do
    admin = insert_user()
    :ok = Store.add_member(ctx.team.id, admin.id, :admin, ctx.owner.id)
    Ravix.Hub.subscribe_workspace(ctx.team.id)

    assert {:ok, %Workspace{name: "Acme Labs", kind: :team}} =
             Workspaces.rename(ctx.owner, ctx.team.id, "  Acme Labs ")

    assert_receive {:workspace_hub, id, :members} when id == ctx.team.id

    assert {:ok, %Workspace{name: "Acme by admin"}} =
             Workspaces.rename(admin, ctx.team.id, "Acme by admin")

    assert Store.live_workspace(ctx.team.id).name == "Acme by admin"
  end

  test "a personal workspace is renamed by its person and stays personal", ctx do
    {:ok, personal} = Store.ensure_personal_workspace(ctx.owner)

    assert {:ok, %Workspace{name: "Mine", kind: :personal}} =
             Workspaces.rename(ctx.owner, personal.id, "Mine")
  end

  test "a member is refused, and strangers, unknown ids and the switch off are not found",
       ctx do
    member = insert_user()
    :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.owner.id)

    assert {:error, {:forbidden, _}} = Workspaces.rename(member, ctx.team.id, "Mine now")
    assert {:error, :not_found} = Workspaces.rename(insert_user(), ctx.team.id, "Mine now")
    assert {:error, :not_found} = Workspaces.rename(ctx.owner, Ecto.UUID.generate(), "X")

    Application.put_env(:ravix, :workspace_access, false)
    assert {:error, :not_found} = Workspaces.rename(ctx.owner, ctx.team.id, "Off")
    assert Store.live_workspace(ctx.team.id).name == "Acme"
  end

  test "a blank or long name is refused on the name field", ctx do
    assert {:error, {:unprocessable, "name", "Give the workspace a name."}} =
             Workspaces.rename(ctx.owner, ctx.team.id, "   ")

    assert {:error, {:unprocessable, "name", "Keep the name to 60 characters."}} =
             Workspaces.rename(ctx.owner, ctx.team.id, String.duplicate("a", 61))

    assert {:error, {:unprocessable, "name", _}} = Workspaces.rename(ctx.owner, ctx.team.id, nil)
  end

  test "an archived workspace is not found, and the store says so too", ctx do
    ctx.team
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Ravix.Repo.update!()

    assert {:error, :not_found} = Workspaces.rename(ctx.owner, ctx.team.id, "Gone")
    assert {:error, :not_found} = Store.rename_workspace(ctx.team.id, "Gone")
  end
end
