defmodule Ravix.WorkspaceVisibilityTest do
  @moduledoc """
  ADR 0009 phase 3b: explicit track visibility, permission rows and
  filtered discovery behind `RAVIX_WORKSPACE_ACCESS`.

  Every case runs with the switch on and again with it off. Off is today's
  rule exactly -- a workspace grants nothing -- and on adds only what the
  ADR names: workspace members see the workspace's project-visible tracks,
  permission rows admit their holders to a private track, and nobody reads
  a private track through their role.

  The switch is stubbed per test process (`Ravix.Config` is Mimic-copied),
  so this file stays async.
  """
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Access
  alias Ravix.Fountain.Client
  alias Ravix.People
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.Projects
  alias Ravix.Projects.Project
  alias Ravix.Tooling
  alias Ravix.ToolingFixture
  alias Ravix.Tracks
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :environment, fn _, _ -> {:error, :offline} end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    [owner, colleague, admin, creator, holder, legacy, seat, stranger, removed] =
      for login <-
            ~w(owner colleague admin creator holder legacy seat stranger removed),
          do: insert_user(login: "#{login}#{System.unique_integer([:positive])}")

    {:ok, workspace} = Store.ensure_personal_workspace(owner)

    for {user, role} <- [
          {colleague, :member},
          {admin, :admin},
          {creator, :member},
          {holder, :member},
          {removed, :member}
        ],
        do: member!(workspace, user, role)

    project = in_workspace(insert_project(user: owner, name: "Shared"), workspace)
    insert_project_member(project, legacy)

    open =
      insert_track(
        project: project,
        title: "Open work",
        created_by: owner.id,
        created_by_login: owner.login
      )

    secret =
      insert_track(
        project: project,
        title: "Private investigation",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: creator.id,
        created_by_login: creator.login
      )

    insert_track_member(open, seat)
    :ok = PeopleStore.add_permission(secret.id, holder.id, workspace.id, creator.id)
    # Shared, then removed: the removal must take the row with it.
    :ok = PeopleStore.add_permission(secret.id, removed.id, workspace.id, creator.id)
    {:ok, _} = Store.revoke_membership(workspace.id, removed.id, owner.id)

    # Another tenant: the stranger's own workspace, project and tracks.
    {:ok, elsewhere} = Store.ensure_personal_workspace(stranger)
    theirs = in_workspace(insert_project(user: stranger, name: "Theirs"), elsewhere)
    their_track = insert_track(project: theirs, title: "Their work", created_by: stranger.id)

    %{
      owner: owner,
      colleague: colleague,
      admin: admin,
      creator: creator,
      holder: holder,
      legacy: legacy,
      seat: seat,
      stranger: stranger,
      removed: removed,
      workspace: workspace,
      project: project,
      open: open,
      secret: secret,
      theirs: theirs,
      their_track: their_track
    }
  end

  defp member!(workspace, user, role) do
    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp in_workspace(project, workspace) do
    Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])
    Repo.get!(Project, project.id)
  end

  defp switch(on?), do: stub(Ravix.Config, :workspace_access?, fn -> on? end)

  # Who reaches which track, by name, for each state of the switch.
  @on %{
    open: ~w(owner colleague admin creator holder legacy seat)a,
    secret: ~w(creator holder)a,
    project: ~w(owner colleague admin creator holder legacy)a
  }

  @off %{
    open: ~w(owner legacy seat)a,
    secret: ~w(creator)a,
    project: ~w(owner legacy)a
  }

  @viewers ~w(owner colleague admin creator holder legacy seat stranger removed)a

  for {state, expected} <- [on: @on, off: @off] do
    describe "with the switch #{state}" do
      setup do
        switch(unquote(state) == :on)
        :ok
      end

      test "every track door admits exactly the viewers the rule names", ctx do
        expected = unquote(Macro.escape(expected))

        for viewer <- @viewers, track <- [:open, :secret] do
          user = ctx[viewer]
          id = ctx[track].id
          admitted? = viewer in expected[track]
          label = "#{viewer} on #{track}"

          assert match?({:ok, _}, Access.track_access(user, id)) == admitted?, label

          assert id in Enum.map(Access.open_tracks(user, [ctx.project.id]), &elem(&1, 0).id) ==
                   admitted?,
                 label

          listed =
            case Tracks.list(user, ctx.project.id) do
              {:ok, rows} -> Enum.map(rows, & &1.id)
              {:error, :not_found} -> []
            end

          assert id in listed == admitted?, label

          assert match?({:ok, _}, Access.thread_access(user, id)) == admitted?, label
          {principal, _, _} = ToolingFixture.principal(user)

          mcp =
            case Tooling.call(principal, "list_tracks", %{"project_id" => ctx.project.id}) do
              {:ok, %{items: items}} -> Enum.map(items, & &1.id)
              {:error, :not_found} -> []
            end

          assert id in mcp == admitted?, label

          # Refusals are decided before any provider is asked, so every
          # provider-backed door is checked here without one.
          unless admitted? do
            assert {:error, :not_found} = Tracks.get(user, id)

            for tool <- ["get_track", "read_track"],
                do:
                  assert(
                    {:error, :not_found} = Tooling.call(principal, tool, %{"track_id" => id})
                  )

            assert {:error, :not_found} = Ravix.Terminal.exec(user, id, %{command: "pwd"})
            assert {:error, :not_found} = Ravix.Terminal.status(user, id)
            assert {:error, :not_found} = Ravix.Previews.status(user, id)
          end
        end
      end

      test "project discovery follows the same memberships", ctx do
        expected = unquote(Macro.escape(expected))

        for viewer <- @viewers do
          user = ctx[viewer]
          whole? = viewer in expected.project
          label = "#{viewer}"

          assert match?({:ok, _}, Access.project_access(user, ctx.project.id)) == whole?, label
          assert ctx.project.id in Access.project_ids(user) == whole?, label

          listed = Enum.map(Projects.list(user, include_machine: false), & &1.id)
          reaches? = whole? or viewer in expected.open or viewer in expected.secret
          assert ctx.project.id in listed == reaches?, label
          assert Access.access_of(user.id, ctx.project) != nil == reaches?, label
        end

        # Nobody's role reaches the project's controls.
        for viewer <- @viewers -- [:owner],
            do: assert({:error, :not_found} = Access.project_of(ctx[viewer], ctx.project.id))
      end

      test "another tenant's ids answer not found through every door", ctx do
        id = ctx.their_track.id

        for viewer <- @viewers -- [:stranger] do
          user = ctx[viewer]
          {principal, _, _} = ToolingFixture.principal(user)

          assert {:error, :not_found} = Access.track_access(user, id)
          assert {:error, :not_found} = Access.thread_access(user, id)
          assert {:error, :not_found} = Access.project_access(user, ctx.theirs.id)
          assert {:error, :not_found} = Tracks.get(user, id)
          assert {:error, :not_found} = Tracks.list(user, ctx.theirs.id)
          assert {:error, :not_found} = Ravix.Terminal.exec(user, id, %{command: "pwd"})
          assert {:error, :not_found} = Ravix.Previews.status(user, id)

          for tool <- ["get_track", "read_track"],
              do:
                assert({:error, :not_found} = Tooling.call(principal, tool, %{"track_id" => id}))

          assert {:error, :not_found} =
                   Tooling.call(principal, "list_tracks", %{"project_id" => ctx.theirs.id})

          assert Access.open_tracks(user, [ctx.theirs.id]) == []
          refute ctx.theirs.id in Access.project_ids(user)
          assert {:error, :not_found} = Access.workspace_access(user, ctx.theirs.workspace_id)
        end
      end

      test "a private sibling's name and count never reach a viewer it was not shared with",
           ctx do
        for viewer <- [:owner, :colleague, :admin, :legacy, :seat] do
          user = ctx[viewer]
          {principal, _, _} = ToolingFixture.principal(user)

          titles = Enum.map(Access.open_tracks(user, [ctx.project.id]), &elem(&1, 0).title)
          refute "Private investigation" in titles

          case Tooling.call(principal, "list_tracks", %{"project_id" => ctx.project.id}) do
            {:ok, %{items: items}} -> refute Enum.any?(items, &(&1.id == ctx.secret.id))
            {:error, :not_found} -> :ok
          end

          # The rail's closed ranking counts only what is visible: closing the
          # private track does not make it a closed row for anybody else.
          refute ctx.secret.id in Enum.map(
                   Access.open_tracks(user, [ctx.project.id], closed: %{ctx.project.id => 10}),
                   &elem(&1, 0).id
                 )
        end
      end
    end
  end

  describe "a removed workspace member (switch on)" do
    setup do
      switch(true)
      :ok
    end

    test "loses workspace tracks, their permission rows and even their own private tracks", ctx do
      assert {:ok, _} = Access.track_access(ctx.creator, ctx.secret.id)
      assert {:ok, _} = Access.track_access(ctx.holder, ctx.secret.id)
      assert {:ok, _} = Access.track_access(ctx.colleague, ctx.open.id)

      for user <- [ctx.creator, ctx.holder, ctx.colleague],
          do: :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, user.id)

      for {user, track} <- [
            {ctx.creator, ctx.secret},
            {ctx.holder, ctx.secret},
            {ctx.colleague, ctx.open}
          ] do
        assert {:error, :not_found} = Access.track_access(user, track.id)
        assert Access.open_tracks(user, [ctx.project.id]) == []
        assert PeopleStore.member_tracks(user.id) == []
      end

      refute ctx.project.id in Enum.map(
               Projects.list(ctx.colleague, include_machine: false),
               & &1.id
             )

      # The legacy grants were never the workspace's to take.
      assert {:ok, _} = Access.track_access(ctx.legacy, ctx.open.id)
      assert {:ok, _} = Access.track_access(ctx.seat, ctx.open.id)
    end

    test "removal tells every project in the workspace, so open track pages re-check", ctx do
      Ravix.Hub.subscribe(ctx.project.id)
      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.colleague.id)
      assert_receive {:hub, %Ravix.Hub.Event{name: :people, track_id: nil}}
    end

    test "removal deletes their permission rows, so re-admission restores no share", ctx do
      refute PeopleStore.permitted?(ctx.secret.id, ctx.removed.id, ctx.workspace.id)

      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.holder.id)
      refute PeopleStore.permitted?(ctx.secret.id, ctx.holder.id, ctx.workspace.id)

      # Phase 4's re-admission un-revokes the same membership row.
      Repo.update_all(
        where(Membership, workspace_id: ^ctx.workspace.id, user_id: ^ctx.holder.id),
        set: [revoked_at: nil]
      )

      assert {:ok, _} = Access.workspace_access(ctx.holder, ctx.workspace.id)
      assert {:error, :not_found} = Access.track_access(ctx.holder, ctx.secret.id)
      assert {:ok, _} = Access.track_access(ctx.holder, ctx.open.id)
    end

    test "the row is written only under a live membership, whoever calls", ctx do
      # `People.share/3` checks first; the write checks again, under a lock,
      # which is what a removal racing the share meets.
      assert {:error, :not_workspace_member} =
               PeopleStore.add_permission(
                 ctx.secret.id,
                 ctx.removed.id,
                 ctx.workspace.id,
                 ctx.creator.id
               )

      refute PeopleStore.permitted?(ctx.secret.id, ctx.removed.id, ctx.workspace.id)
    end

    test "the rail is still one query with the switch on", ctx do
      {rows, queries} =
        Ravix.QueryCount.count(fn -> Access.open_tracks(ctx.holder, [ctx.project.id]) end)

      assert length(queries) == 1
      assert Enum.sort(Enum.map(rows, &elem(&1, 0).id)) == Enum.sort([ctx.open.id, ctx.secret.id])
    end

    test "people lists and @mentions include the workspace's members and holders", ctx do
      {:ok, people} = People.list(ctx.creator, ctx.secret.id)

      assert Enum.map(people, &{&1.login, &1.via}) |> Enum.sort() ==
               Enum.sort([{ctx.creator.login, :creator}, {ctx.holder.login, :shared}])

      {:ok, people} = People.list(ctx.owner, ctx.open.id)
      vias = Map.new(people, &{&1.login, &1.via})
      assert vias[ctx.colleague.login] == :workspace
      assert vias[ctx.legacy.login] == :project
      refute Map.has_key?(vias, ctx.removed.login)

      {:ok, mentionable} = Ravix.Comments.mentionable(ctx.creator, ctx.secret.id)
      assert Enum.map(mentionable, & &1.login) == [ctx.holder.login]

      {:ok, mentionable} = Ravix.Comments.mentionable(ctx.owner, ctx.open.id)
      logins = Enum.map(mentionable, & &1.login)
      assert ctx.colleague.login in logins and ctx.admin.login in logins
      refute ctx.removed.login in logins

      switch(false)
      {:ok, mentionable} = Ravix.Comments.mentionable(ctx.owner, ctx.open.id)
      refute ctx.colleague.login in Enum.map(mentionable, & &1.login)
    end

    test "a legacy project never reads through a workspace", ctx do
      legacy_project = insert_project(user: ctx.owner)
      track = insert_track(project: legacy_project, created_by: ctx.owner.id)

      assert {:error, :not_found} = Access.track_access(ctx.colleague, track.id)
      assert Access.open_tracks(ctx.colleague, [legacy_project.id]) == []
      refute legacy_project.id in Access.project_ids(ctx.colleague)
    end
  end

  describe "sharing a private track with selected members" do
    setup ctx do
      switch(true)
      %{extra: tap(insert_user(), &member!(ctx.workspace, &1, :member))}
    end

    test "the creator shares with a workspace member, who then reaches it", ctx do
      assert {:error, :not_found} = Access.track_access(ctx.extra, ctx.secret.id)
      Ravix.Hub.subscribe(ctx.project.id)

      assert :ok = People.share(ctx.creator, ctx.secret.id, ctx.extra.id)
      assert_receive {:hub, %Ravix.Hub.Event{name: :people}}
      assert {:ok, %{role: :member}} = Access.track_access(ctx.extra, ctx.secret.id)

      assert ctx.secret.id in Enum.map(
               Access.open_tracks(ctx.extra, [ctx.project.id]),
               &elem(&1, 0).id
             )

      assert :ok = People.share(ctx.creator, ctx.secret.id, ctx.extra.id)

      assert {:ok, shared} = People.shared_with(ctx.creator, ctx.secret.id)

      assert Enum.sort(Enum.map(shared, & &1.id)) == Enum.sort([ctx.holder.id, ctx.extra.id])
    end

    test "rejects anybody outside the workspace; there are no external guests", ctx do
      for outsider <- [ctx.stranger, ctx.legacy, ctx.seat, ctx.removed] do
        assert {:error, :not_workspace_member} =
                 People.share(ctx.creator, ctx.secret.id, outsider.id)
      end

      assert {:error, :not_workspace_member} =
               People.share(ctx.creator, ctx.secret.id, Ecto.UUID.generate())

      refute PeopleStore.permitted?(ctx.secret.id, ctx.stranger.id, ctx.workspace.id)
    end

    test "only the creator, only a private track, only with the switch on", ctx do
      for user <- [ctx.owner, ctx.admin, ctx.holder] do
        assert {:error, reason} = People.share(user, ctx.secret.id, ctx.extra.id)
        assert reason in [:not_found] or match?({:forbidden, _}, reason)
      end

      assert {:error, {:unprocessable, "not_private", _}} =
               People.share(ctx.owner, ctx.open.id, ctx.extra.id)

      switch(false)
      assert {:error, :not_found} = People.share(ctx.creator, ctx.secret.id, ctx.extra.id)
      refute PeopleStore.permitted?(ctx.secret.id, ctx.extra.id, ctx.workspace.id)
    end

    test "unsharing somebody on a legacy seat leaves their seat's preview grants", ctx do
      insert_track_member(ctx.secret, ctx.extra)
      insert_preview_agent_grant(ctx.secret, ctx.extra)

      assert :ok = People.unshare(ctx.creator, ctx.secret.id, ctx.extra.id)
      assert [_] = Repo.all(where(Ravix.Previews.PreviewAgentGrant, user_id: ^ctx.extra.id))
      assert {:ok, _} = Access.track_access(ctx.extra, ctx.secret.id)
    end

    test "unsharing revokes the row and its preview grants; a holder may leave", ctx do
      preview = insert_preview_agent_grant(ctx.secret, ctx.holder)
      assert preview

      assert {:error, {:forbidden, _}} = People.unshare(ctx.holder, ctx.secret.id, ctx.removed.id)
      assert :ok = People.unshare(ctx.creator, ctx.secret.id, ctx.holder.id)
      assert {:error, :not_found} = Access.track_access(ctx.holder, ctx.secret.id)

      assert Repo.all(Ravix.Previews.PreviewAgentGrant)
             |> Enum.filter(&(&1.user_id == ctx.holder.id)) == []

      :ok = People.share(ctx.creator, ctx.secret.id, ctx.extra.id)
      assert :ok = People.unshare(ctx.extra, ctx.secret.id, ctx.extra.id)
      assert {:error, :not_found} = Access.track_access(ctx.extra, ctx.secret.id)
    end

    test "a permission row admits nobody while the switch is off", ctx do
      switch(false)
      assert {:error, :not_found} = Access.track_access(ctx.holder, ctx.secret.id)

      refute ctx.secret.id in Enum.map(
               Access.open_tracks(ctx.holder, [ctx.project.id]),
               &elem(&1, 0).id
             )

      assert PeopleStore.member_tracks(ctx.holder.id) == []
    end
  end
end
