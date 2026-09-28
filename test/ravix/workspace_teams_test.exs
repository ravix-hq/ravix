defmodule Ravix.WorkspaceTeamsTest do
  @moduledoc """
  ADR 0009 phase 4a: team workspaces, invitations by GitHub login, their
  acceptance at sign-in, and the role rules around both.

  Not async: the tests flip `RAVIX_WORKSPACE_ACCESS`, which is application-wide.
  """
  use Ravix.DataCase, async: false
  use Mimic

  import Ravix.Factory

  alias Ravix.Accounts
  alias Ravix.Accounts.User
  alias Ravix.Crypto
  alias Ravix.GitHubFake, as: Fake
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Invite, Membership, Store, Workspace}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    github(%{})
    stub(Ravix.Config, :github, fn -> Fake.app() end)

    owner = insert_user(login: "owner")
    {:ok, team} = Workspaces.create(owner, "Acme")
    %{owner: owner, team: team}
  end

  # GitHub knows @dana (9001), who has not signed in here, plus `accounts`,
  # and otherwise whoever holds a login locally; @broken refuses.
  defp github(accounts) do
    Fake.install([
      {"GET", "/users/broken", {401, %{message: "Bad credentials"}}},
      Fake.users_route(Map.merge(%{"dana" => {9001, "dana"}}, accounts))
    ])
  end

  defp switch(on?), do: Application.put_env(:ravix, :workspace_access, on?)

  defp sign_in(github_id, login) do
    Accounts.upsert_user(%{
      github_id: github_id,
      login: login,
      name: nil,
      avatar_url: nil,
      token_enc: Crypto.encrypt("t")
    })
  end

  defp role_of(workspace, %User{id: id}) do
    case Store.membership(workspace.id, id) do
      %Membership{role: role} -> role
      nil -> nil
    end
  end

  defp join!(workspace, user, role) do
    :ok = Store.add_member(workspace.id, user.id, role, nil)
    user
  end

  describe "create/2" do
    test "anybody signed in creates a team workspace and owns it", %{owner: owner, team: team} do
      assert %Workspace{kind: :team, name: "Acme", personal_user_id: nil} = team
      assert team.created_by_user_id == owner.id
      assert role_of(team, owner) == :owner
      assert [%{workspace: %{id: id}, role: :owner}] = Workspaces.list(owner)
      assert id == team.id
    end

    test "the name is trimmed and required, and at most 60 characters", %{owner: owner} do
      assert {:ok, %Workspace{name: "Spaced"}} = Workspaces.create(owner, "  Spaced  ")
      assert {:error, {:unprocessable, "name", _}} = Workspaces.create(owner, "   ")
      assert {:error, {:unprocessable, "name", _}} = Workspaces.create(owner, nil)

      assert {:error, {:unprocessable, "name", _}} =
               Workspaces.create(owner, String.duplicate("x", 61))
    end

    test "with the switch off nobody can", %{owner: owner} do
      switch(false)
      assert {:error, :not_found} = Workspaces.create(owner, "Hidden")
      refute Repo.exists?(from w in Workspace, where: w.name == "Hidden")
    end
  end

  describe "invite/4" do
    test "somebody who has signed in here joins at once, and open pages hear", ctx do
      bo = insert_user(login: "Bo")
      Ravix.Hub.subscribe_workspace(ctx.team.id)

      assert {:ok, :member} = Workspaces.invite(ctx.owner, ctx.team.id, "@bo")
      assert role_of(ctx.team, bo) == :member
      assert_receive {:workspace_hub, _, :members}

      assert {:error, {:conflict, "already_member", _}} =
               Workspaces.invite(ctx.owner, ctx.team.id, "bo")

      # And they see it.
      assert {:ok, %{role: :member}} = Workspaces.people(bo, ctx.team.id)
    end

    test "a join tells each of the workspace's projects, as a removal does", ctx do
      project = insert_project(user: ctx.owner)
      Store.move_project(project.id, ctx.team.id)
      Ravix.Hub.subscribe(project.id)
      insert_user(login: "bo")

      assert {:ok, :member} = Workspaces.invite(ctx.owner, ctx.team.id, "bo")
      assert_receive {:hub, %Ravix.Hub.Event{name: :people}}

      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert {:ok, _dana} = sign_in("9001", "dana")
      assert_receive {:hub, %Ravix.Hub.Event{name: :people}}
    end

    test "somebody not signed up waits on their GitHub id and joins at first sign-in", ctx do
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "Dana", "admin")

      assert [%Invite{login: "dana", login_key: "dana", github_id: "9001", role: :admin}] =
               Store.invites(ctx.team.id)

      Ravix.Hub.subscribe_workspace(ctx.team.id)
      assert {:ok, dana} = sign_in("9001", "dana")
      assert role_of(ctx.team, dana) == :admin
      assert Store.invites(ctx.team.id) == []
      assert_receive {:workspace_hub, _, :members}

      # Their personal workspace was written in the same sign-in.
      assert {:ok, %Workspace{kind: :personal}} = Workspaces.personal_workspace(dana)
    end

    test "an invitation with a GitHub id is not taken by somebody else holding the login", ctx do
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert {:ok, impostor} = sign_in("7777", "DANA")
      assert role_of(ctx.team, impostor) == nil
      assert [%Invite{github_id: "9001"}] = Store.invites(ctx.team.id)
    end

    test "without a GitHub App the invitation waits on the login, case-insensitively", ctx do
      stub(Ravix.Config, :github, fn -> nil end)
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "NewComer")
      assert [%Invite{github_id: nil, login_key: "newcomer"}] = Store.invites(ctx.team.id)

      assert {:ok, newcomer} = sign_in("5555", "newcomer")
      assert role_of(ctx.team, newcomer) == :member
    end

    test "a GitHub account renamed since they signed in here is still them", ctx do
      renamed = insert_user(login: "dana-old", github_id: "9001")
      assert {:ok, :member} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert role_of(ctx.team, renamed) == :member
    end

    test "a stale local login is not trusted: GitHub says who holds it now", ctx do
      # @foo signed in here long ago, then renamed on GitHub; somebody else,
      # never signed in here, holds `foo` today.
      stale = insert_user(login: "foo", github_id: "1111")
      github(%{"foo" => {2222, "foo"}})

      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "foo")
      assert role_of(ctx.team, stale) == nil
      assert [%Invite{github_id: "2222", login_key: "foo"}] = Store.invites(ctx.team.id)

      # The stale account signing in again does not take it either.
      assert {:ok, _} = sign_in("1111", "foo")
      assert role_of(ctx.team, stale) == nil

      # The real holder does.
      assert {:ok, holder} = sign_in("2222", "foo2")
      assert role_of(ctx.team, holder) == :member
    end

    test "without a GitHub App a login held here joins at once", ctx do
      stub(Ravix.Config, :github, fn -> nil end)
      bo = insert_user(login: "bo")
      assert {:ok, :member} = Workspaces.invite(ctx.owner, ctx.team.id, "BO")
      assert role_of(ctx.team, bo) == :member
    end

    test "a stranger, a malformed login and GitHub's refusal are refused", ctx do
      assert {:error, {:unprocessable, "no_such_user", _}} =
               Workspaces.invite(ctx.owner, ctx.team.id, "nobody")

      assert {:error, {:unprocessable, "no_login", _}} =
               Workspaces.invite(ctx.owner, ctx.team.id, " @ ")

      assert {:error, {:unprocessable, "bad_login", _}} =
               Workspaces.invite(ctx.owner, ctx.team.id, "not a login")

      assert {:error, {:unprocessable, "role", _}} =
               Workspaces.invite(ctx.owner, ctx.team.id, "dana", "guest")

      assert {:error, %Ravix.GitHub.Error{status: 401}} =
               Workspaces.invite(ctx.owner, ctx.team.id, "broken")

      assert Store.invites(ctx.team.id) == []
    end

    test "inviting the same login again updates the waiting invitation", ctx do
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "DANA", "owner")
      assert [%Invite{role: :owner}] = Store.invites(ctx.team.id)
    end

    test "somebody removed can be invited back", ctx do
      bo = join!(ctx.team, insert_user(login: "bo"), :member)
      assert :ok = Workspaces.remove_member(ctx.owner, ctx.team.id, bo.id)
      assert role_of(ctx.team, bo) == nil

      assert {:ok, :member} = Workspaces.invite(ctx.owner, ctx.team.id, "bo", "admin")
      assert role_of(ctx.team, bo) == :admin
    end

    test "a personal workspace takes no invitations", %{owner: owner} do
      {:ok, personal} = Store.ensure_personal_workspace(owner)

      assert {:error, {:unprocessable, "personal", _}} =
               Workspaces.invite(owner, personal.id, "dana")
    end

    test "an archived workspace's invitation admits nobody", ctx do
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      Repo.update_all(Workspace, set: [archived_at: DateTime.utc_now()])

      assert {:ok, dana} = sign_in("9001", "dana")

      refute Repo.exists?(
               from m in Membership,
                 where: m.user_id == ^dana.id and m.workspace_id == ^ctx.team.id
             )

      assert Store.invites(ctx.team.id) == []
    end
  end

  describe "revoke_invite/3" do
    test "an owner or admin withdraws an invitation, and its sign-in then admits nothing", ctx do
      admin = join!(ctx.team, insert_user(), :admin)
      assert {:ok, :invited} = Workspaces.invite(admin, ctx.team.id, "dana")

      assert :ok = Workspaces.revoke_invite(admin, ctx.team.id, "@Dana")
      assert Store.invites(ctx.team.id) == []
      assert {:error, :not_found} = Workspaces.revoke_invite(admin, ctx.team.id, "dana")

      assert {:ok, dana} = sign_in("9001", "dana")
      assert role_of(ctx.team, dana) == nil
    end

    test "an owner's invitation, or one for an admin or owner, is an owner's to change", ctx do
      admin = join!(ctx.team, insert_user(), :admin)
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert [%Invite{invited_by_role: :owner, role: :member}] = Store.invites(ctx.team.id)

      assert {:error, {:forbidden, _}} = Workspaces.invite(admin, ctx.team.id, "dana")
      assert {:error, {:forbidden, _}} = Workspaces.revoke_invite(admin, ctx.team.id, "dana")
      assert [%Invite{invited_by_role: :owner}] = Store.invites(ctx.team.id)

      # An owner may; and an admin's own member invitation stays theirs to manage.
      assert :ok = Workspaces.revoke_invite(ctx.owner, ctx.team.id, "dana")
      assert {:ok, :invited} = Workspaces.invite(admin, ctx.team.id, "dana")
      assert {:ok, :invited} = Workspaces.invite(admin, ctx.team.id, "dana")
      assert [%Invite{invited_by_role: :admin}] = Store.invites(ctx.team.id)

      # Once an owner raises it to admin, it is protected again.
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana", "admin")
      assert {:error, {:forbidden, _}} = Workspaces.revoke_invite(admin, ctx.team.id, "dana")
    end

    test "a member cannot", ctx do
      member = join!(ctx.team, insert_user(), :member)
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert {:error, {:forbidden, _}} = Workspaces.revoke_invite(member, ctx.team.id, "dana")
      assert [_] = Store.invites(ctx.team.id)
    end
  end

  describe "role rules" do
    test "a member invites nobody; an admin invites members only; an owner any role", ctx do
      member = join!(ctx.team, insert_user(), :member)
      admin = join!(ctx.team, insert_user(), :admin)

      assert {:error, {:forbidden, _}} = Workspaces.invite(member, ctx.team.id, "dana")
      assert {:error, {:forbidden, _}} = Workspaces.invite(admin, ctx.team.id, "dana", "admin")
      assert {:error, {:forbidden, _}} = Workspaces.invite(admin, ctx.team.id, "dana", "owner")
      assert {:ok, :invited} = Workspaces.invite(admin, ctx.team.id, "dana", "member")
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana", "owner")
    end

    test "only an owner changes roles, and never the last owner's", ctx do
      admin = join!(ctx.team, insert_user(), :admin)
      member = join!(ctx.team, insert_user(), :member)

      assert {:error, {:forbidden, _}} =
               Workspaces.set_role(admin, ctx.team.id, member.id, :admin)

      assert :ok = Workspaces.set_role(ctx.owner, ctx.team.id, member.id, "admin")
      assert role_of(ctx.team, member) == :admin

      assert {:error, {:conflict, "last_owner", _}} =
               Workspaces.set_role(ctx.owner, ctx.team.id, ctx.owner.id, "member")

      assert :ok = Workspaces.set_role(ctx.owner, ctx.team.id, admin.id, "owner")
      assert :ok = Workspaces.set_role(ctx.owner, ctx.team.id, ctx.owner.id, "member")
      assert role_of(ctx.team, ctx.owner) == :member

      assert {:error, {:unprocessable, "role", _}} =
               Workspaces.set_role(admin, ctx.team.id, member.id, "guest")

      assert {:error, :not_found} = Workspaces.set_role(admin, ctx.team.id, "nobody", "member")
    end

    test "an admin removes members; only an owner removes an owner", ctx do
      admin = join!(ctx.team, insert_user(), :admin)
      member = join!(ctx.team, insert_user(), :member)

      assert :ok = Workspaces.remove_member(admin, ctx.team.id, member.id)

      assert {:error, {:forbidden, _}} =
               Workspaces.remove_member(admin, ctx.team.id, ctx.owner.id)
    end
  end

  describe "somebody outside the workspace" do
    test "a stranger and another tenant's owner get not found everywhere", ctx do
      stranger = insert_user()
      {:ok, other} = Workspaces.create(stranger, "Other")

      for {user, id} <- [{stranger, ctx.team.id}, {ctx.owner, other.id}, {ctx.owner, "nope"}] do
        assert {:error, :not_found} = Workspaces.people(user, id)
        assert {:error, :not_found} = Workspaces.invite(user, id, "dana")
        assert {:error, :not_found} = Workspaces.revoke_invite(user, id, "dana")
        assert {:error, :not_found} = Workspaces.set_role(user, id, ctx.owner.id, "member")
        assert {:error, :not_found} = Workspaces.remove_member(user, id, ctx.owner.id)
      end

      assert Store.invites(ctx.team.id) == []
    end

    test "a removed member gets not found", ctx do
      bo = join!(ctx.team, insert_user(), :admin)
      assert :ok = Workspaces.remove_member(ctx.owner, ctx.team.id, bo.id)
      assert {:error, :not_found} = Workspaces.people(bo, ctx.team.id)
      assert {:error, :not_found} = Workspaces.invite(bo, ctx.team.id, "dana")
    end

    test "with the switch off, members too get not found for anything granted", ctx do
      switch(false)
      assert {:error, :not_found} = Workspaces.people(ctx.owner, ctx.team.id)
      assert {:error, :not_found} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")
      assert {:error, :not_found} = Workspaces.revoke_invite(ctx.owner, ctx.team.id, "dana")

      assert {:error, :not_found} =
               Workspaces.set_role(ctx.owner, ctx.team.id, ctx.owner.id, "owner")
    end
  end

  describe "the people list" do
    test "owners first, then admins, then members, with waiting invitations", ctx do
      join!(ctx.team, insert_user(login: "zed"), :member)
      join!(ctx.team, insert_user(login: "amy"), :admin)
      assert {:ok, :invited} = Workspaces.invite(ctx.owner, ctx.team.id, "dana")

      assert {:ok, %{role: :owner, members: members, invites: [%Invite{login: "dana"}]}} =
               Workspaces.people(ctx.owner, ctx.team.id)

      assert Enum.map(members, &{&1.user.login, &1.role}) ==
               [{"owner", :owner}, {"amy", :admin}, {"zed", :member}]
    end
  end
end
