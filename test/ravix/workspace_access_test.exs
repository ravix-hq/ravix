defmodule Ravix.WorkspaceAccessTest do
  @moduledoc """
  ADR 0009 phase 3a: the personal workspace written at sign-up, the
  workspace capabilities in `Ravix.Accounts.Access`, the
  `RAVIX_WORKSPACE_ACCESS` switch and member removal.

  Not async: some tests flip the switch, which is application-wide.
  """
  use Ravix.DataCase, async: false
  use Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.{Access, User}
  alias Ravix.Crypto
  alias Ravix.Projects.Project
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Backfill, Membership, Store, Workspace}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)
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

  defp member!(workspace, user, role) do
    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp personal!(user) do
    {:ok, workspace} = Store.ensure_personal_workspace(user)
    workspace
  end

  defp memberships(workspace),
    do: Repo.all(from m in Membership, where: m.workspace_id == ^workspace.id)

  describe "the personal workspace at sign-up" do
    test "a new user has one, owned by them, from their first sign-in" do
      assert {:ok, %User{} = user} = sign_in("901", "Newcomer")

      assert {:ok, %Workspace{kind: :personal, name: "Newcomer"} = workspace} =
               Workspaces.personal_workspace(user)

      assert workspace.personal_user_id == user.id
      assert workspace.created_by_user_id == user.id
      assert [%{user_id: user_id, role: :owner, revoked_at: nil}] = memberships(workspace)
      assert user_id == user.id
      assert {:ok, %{role: :owner}} = Access.workspace_access(user, workspace.id)
    end

    test "a returning user keeps the same one, unrenamed, and a revoked owner stays revoked" do
      {:ok, user} = sign_in("902", "before")
      {:ok, workspace} = Workspaces.personal_workspace(user)
      Repo.update_all(Membership, set: [revoked_at: DateTime.utc_now()])

      assert {:ok, %User{login: "after"} = again} = sign_in("902", "after")
      assert again.id == user.id
      assert {:ok, %Workspace{name: "before"} = same} = Workspaces.personal_workspace(again)
      assert same.id == workspace.id
      assert Repo.aggregate(Workspace, :count) == 1
      assert [%{revoked_at: %DateTime{}}] = memberships(workspace)
    end

    test "a user an older release created gets theirs on sign-in, as the backfill would" do
      # `insert_user/1` writes the row as the previous release does: no workspace.
      old = insert_user(github_id: "903", login: "old")
      assert {:error, :not_found} = Workspaces.personal_workspace(old)

      {:ok, user} = sign_in("903", "old")
      assert {:ok, %Workspace{name: "old"}} = Workspaces.personal_workspace(user)
      assert %{workspaces: 0, memberships: 0} = Backfill.run()
    end

    test "sign-in and the backfill, in either order, leave exactly one of each" do
      # Backfill first: the sign-in finds the workspace and its owner.
      old = insert_user(github_id: "904", login: "first")
      assert %{workspaces: 1, memberships: 1} = Backfill.run()
      {:ok, backfilled} = Workspaces.personal_workspace(old)
      {:ok, _} = sign_in("904", "first")
      assert {:ok, %{id: id}} = Workspaces.personal_workspace(old)
      assert id == backfilled.id

      # Sign-in first: the backfill finds nothing left.
      {:ok, fresh} = sign_in("905", "second")
      assert %{workspaces: 0, memberships: 0} = Backfill.run()
      assert {:ok, _} = Workspaces.personal_workspace(fresh)

      # A sign-in whose workspace insert lost the race to the backfill (the
      # unique key conflicted) still finds it and adds only what is missing.
      Repo.delete_all(from m in Membership, where: m.user_id == ^fresh.id)
      assert {:ok, %Workspace{id: id}} = Store.ensure_personal_workspace(fresh)
      assert {:ok, %Workspace{id: ^id}} = Store.ensure_personal_workspace(fresh)
      assert {:ok, %Workspace{id: ^id}} = Workspaces.personal_workspace(fresh)

      assert Repo.aggregate(Workspace, :count) == 2
      assert Repo.aggregate(Membership, :count) == 2
    end

    test "a refused sign-in writes nothing" do
      assert {:error, %Ecto.Changeset{}} = sign_in("906", nil)
      assert Repo.aggregate(Workspace, :count) == 0
    end

    test "a personal workspace gone mid-sign-in rolls the sign-in back, rather than raising" do
      stub(Store, :ensure_personal_workspace, fn _user -> {:error, :not_found} end)

      assert {:error, %Ecto.Changeset{errors: [id: {"has no personal workspace", _}]}} =
               sign_in("907", "vanished")

      assert Repo.aggregate(User, :count) == 0
    end
  end

  describe "workspace_access/2" do
    setup do
      [owner, admin, member, stranger] = for _ <- 1..4, do: insert_user()
      workspace = personal!(owner)
      member!(workspace, admin, :admin)
      member!(workspace, member, :member)
      %{owner: owner, admin: admin, member: member, stranger: stranger, workspace: workspace}
    end

    test "answers each member's role", ctx do
      assert {:ok, %{role: :owner, workspace: %{id: id}}} =
               Access.workspace_access(ctx.owner, ctx.workspace.id)

      assert id == ctx.workspace.id
      assert {:ok, %{role: :admin}} = Access.workspace_access(ctx.admin, ctx.workspace.id)
      assert {:ok, %{role: :member}} = Access.workspace_access(ctx.member, ctx.workspace.id)
    end

    test "a non-member, another tenant's id and a removed membership are all not found", ctx do
      assert {:error, :not_found} = Access.workspace_access(ctx.stranger, ctx.workspace.id)

      other = personal!(ctx.stranger)
      assert {:error, :not_found} = Access.workspace_access(ctx.owner, other.id)

      assert :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.member.id)
      assert {:error, :not_found} = Access.workspace_access(ctx.member, ctx.workspace.id)
    end
  end

  describe "capabilities" do
    test "follow ADR 0009's roles" do
      table = %{
        manage_roles: [:owner],
        delete_workspace: [:owner],
        manage_members: [:owner, :admin],
        connect_repos: [:owner, :admin],
        manage_projects: [:owner, :admin],
        create_project: [:owner, :admin],
        create_track: [:owner, :admin, :member],
        see_workspace_tracks: [:owner, :admin, :member]
      }

      for {capability, allowed} <- table, role <- [:owner, :admin, :member] do
        assert Access.can?(role, capability) == role in allowed,
               "#{role} #{capability}"
      end

      refute Access.can?(:owner, :read_private_tracks)
      refute Access.can?(:guest, :see_workspace_tracks)
      assert {:error, {:forbidden, _}} = Access.require_capability(:member, :manage_members)
      assert :ok = Access.require_capability(:admin, :manage_members)
    end

    test "workspace_grant/3 grants nothing while the switch is off" do
      owner = insert_user()
      member = insert_user()
      workspace = personal!(owner)
      member!(workspace, member, :member)

      switch(false)
      assert {:error, :not_found} = Access.workspace_grant(owner, workspace.id, :manage_members)
      assert {:error, :not_found} = Access.workspace_grant(member, workspace.id, :create_track)

      switch(true)
      assert {:ok, %{role: :owner}} = Access.workspace_grant(owner, workspace.id, :manage_members)
      assert {:ok, %{role: :member}} = Access.workspace_grant(member, workspace.id, :create_track)

      assert {:error, {:forbidden, _}} =
               Access.workspace_grant(member, workspace.id, :manage_members)

      assert {:error, :not_found} =
               Access.workspace_grant(insert_user(), workspace.id, :create_track)
    end
  end

  describe "remove_member/3" do
    setup do
      [owner, admin, member] = for _ <- 1..3, do: insert_user()
      workspace = personal!(owner)
      member!(workspace, admin, :admin)
      member!(workspace, member, :member)
      %{owner: owner, admin: admin, member: member, workspace: workspace}
    end

    test "owners and admins remove members, and are told after it commits", ctx do
      Ravix.Hub.subscribe_workspace(ctx.workspace.id)

      assert :ok = Workspaces.remove_member(ctx.admin, ctx.workspace.id, ctx.member.id)
      assert_receive {:workspace_hub, id, :members}
      assert id == ctx.workspace.id

      # Stamped, not deleted, so the backfill cannot put it back.
      assert %{revoked_at: %DateTime{}} =
               Repo.get_by(Membership, workspace_id: ctx.workspace.id, user_id: ctx.member.id)

      Backfill.run()
      assert {:error, :not_found} = Access.workspace_access(ctx.member, ctx.workspace.id)

      assert :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.admin.id)
      assert {:error, :not_found} = Access.workspace_access(ctx.admin, ctx.workspace.id)
    end

    test "a member cannot remove anybody, and a removed admin can no longer", ctx do
      assert {:error, {:forbidden, _}} =
               Workspaces.remove_member(ctx.member, ctx.workspace.id, ctx.admin.id)

      assert {:error, {:forbidden, _}} =
               Workspaces.remove_member(ctx.member, ctx.workspace.id, ctx.member.id)

      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.admin.id)

      assert {:error, :not_found} =
               Workspaces.remove_member(ctx.admin, ctx.workspace.id, ctx.member.id)

      assert {:ok, %{role: :member}} = Access.workspace_access(ctx.member, ctx.workspace.id)
    end

    test "never the last owner, and only an owner removes an owner", ctx do
      assert {:error, :last_owner} =
               Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.owner.id)

      second = insert_user()
      member!(ctx.workspace, second, :owner)

      assert {:error, {:forbidden, _}} =
               Workspaces.remove_member(ctx.admin, ctx.workspace.id, second.id)

      assert :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, second.id)

      assert {:error, :last_owner} =
               Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.owner.id)
    end

    test "a remover revoked or demoted while their removal was in flight is refused", ctx do
      # `workspace_access/2` answered for the admin before the removal took
      # its lock; by then another owner had removed them.
      stale = Access.workspace_access(ctx.admin, ctx.workspace.id)
      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.admin.id)
      Ravix.Hub.subscribe_workspace(ctx.workspace.id)
      stub(Access, :workspace_access, fn _user, _id -> stale end)

      assert {:error, :not_found} =
               Workspaces.remove_member(ctx.admin, ctx.workspace.id, ctx.member.id)

      # Demoted to member instead: refused as a member is.
      demoted = insert_user()
      member!(ctx.workspace, demoted, :member)

      stub(Access, :workspace_access, fn _user, _id ->
        {:ok, %{workspace: ctx.workspace, role: :admin}}
      end)

      assert {:error, {:forbidden, _}} =
               Workspaces.remove_member(demoted, ctx.workspace.id, ctx.member.id)

      # Neither removal happened, and nobody was told one did.
      refute_received {:workspace_hub, _, :members}

      assert %{revoked_at: nil} =
               Repo.get_by(Membership, workspace_id: ctx.workspace.id, user_id: ctx.member.id)
    end

    test "a stranger, another tenant and somebody not in it answer not found", ctx do
      stranger = insert_user()
      other = personal!(stranger)

      assert {:error, :not_found} =
               Workspaces.remove_member(stranger, ctx.workspace.id, ctx.member.id)

      assert {:error, :not_found} = Workspaces.remove_member(ctx.owner, other.id, stranger.id)

      assert {:error, :not_found} =
               Workspaces.remove_member(ctx.owner, ctx.workspace.id, stranger.id)
    end
  end

  describe "RAVIX_WORKSPACE_ACCESS" do
    test "reads true only from \"true\", and defaults off" do
      env = System.get_env("RAVIX_WORKSPACE_ACCESS")

      on_exit(fn ->
        if env,
          do: System.put_env("RAVIX_WORKSPACE_ACCESS", env),
          else: System.delete_env("RAVIX_WORKSPACE_ACCESS")
      end)

      for {value, expected} <- [{nil, false}, {"false", false}, {"TRUE", false}, {"true", true}] do
        if value,
          do: System.put_env("RAVIX_WORKSPACE_ACCESS", value),
          else: System.delete_env("RAVIX_WORKSPACE_ACCESS")

        config = Config.Reader.read!("config/runtime.exs", env: :test)
        switch(config[:ravix][:workspace_access])
        assert Ravix.Config.workspace_access?() == expected, inspect(value)
      end

      Application.delete_env(:ravix, :workspace_access)
      refute Ravix.Config.workspace_access?()
    end

    test "while off, every existing door answers exactly as it did before workspaces" do
      switch(false)
      owner = insert_user()
      [project_member, track_member, colleague, stranger] = for _ <- 1..4, do: insert_user()
      project = insert_project(user: owner)
      insert_project_member(project, project_member)
      open = insert_track(project: project, created_by: owner.id)
      private = insert_track(project: project, created_by: owner.id, visibility: :private)
      insert_track_member(open, track_member)
      people = [owner, project_member, track_member, colleague, stranger]

      doors = fn ->
        project = Repo.get!(Project, project.id)

        for user <- people do
          {user.id,
           [
             Access.project_access(user, project.id) |> elem(0),
             Access.project_of(user, project.id) |> elem(0),
             Access.access_of(user.id, project),
             Access.project_ids(user),
             for(t <- [open, private], do: Access.track_access(user, t.id) |> elem(0)),
             for(t <- [open, private], do: Access.thread_access(user, t.id) |> elem(0)),
             Access.open_tracks(user, [project.id]) |> Enum.map(&elem(&1, 0).id) |> Enum.sort()
           ]}
        end
      end

      before = doors.()

      # Now give the project a workspace, and everybody a role in it.
      workspace = personal!(owner)
      Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])
      member!(workspace, colleague, :member)
      member!(workspace, stranger, :admin)
      member!(workspace, project_member, :member)

      assert doors.() == before
    end
  end
end
