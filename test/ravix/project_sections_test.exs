defmodule Ravix.ProjectSectionsTest do
  @moduledoc """
  Sidebar sections: personal, and per workspace (RAV-127). The unscoped
  calls (nil workspace, `RAVIX_WORKSPACE_ACCESS` off) behave as they always
  did; a workspace in hand is checked through `Access.workspace_access/2`,
  lists only its own sections, and takes only its own projects. A row the
  previous release wrote without a workspace reads as the personal one.
  """
  use Ravix.DataCase, async: true

  alias Ravix.Projects.{Section, SectionPlacement, Sections}
  alias Ravix.Workspaces.Store

  test "sections persist names, collapse state and exclusive project placement" do
    user = insert_user()
    project = insert_project(user: user)
    assert {:ok, first} = Sections.create(user, nil, %{name: " Work "})
    assert first.name == "Work"
    assert {:ok, second} = Sections.create(user, nil, %{name: "Later"})
    assert {:ok, _} = Sections.move(user, nil, project.id, first.id)
    assert {:ok, _} = Sections.move(user, nil, project.id, second.id)
    assert {:ok, _} = Sections.update(user, second.id, %{name: "Soon", collapsed: true})
    {:ok, {sections, placements}} = Sections.list(user, nil)
    assert placements == %{project.id => second.id}
    assert Enum.find(sections, &(&1.id == second.id)).collapsed
    assert {:ok, _} = Sections.move(user, nil, project.id, "")
    assert {:ok, {_, %{}}} = Sections.list(user, nil)
    assert {:ok, _} = Sections.move(user, nil, project.id, second.id)
    assert {:ok, _} = Sections.delete(user, second.id)
    assert {:ok, {[^first], %{}}} = Sections.list(user, nil)
    assert Ravix.Projects.get(user, project.id) |> elem(0) == :ok
  end

  test "names are required, bounded and unique per person and workspace" do
    user = insert_user()
    assert {:error, _} = Sections.create(user, nil, %{name: "   "})
    assert {:error, _} = Sections.create(user, nil, %{name: String.duplicate("x", 81)})
    assert {:ok, _} = Sections.create(user, nil, %{name: "Work"})
    assert {:error, _} = Sections.create(user, nil, %{name: "Work"})
    assert {:ok, _} = Sections.create(insert_user(), nil, %{name: "Work"})
  end

  test "foreign sections and inaccessible projects cannot be changed" do
    user = insert_user()
    other = insert_user()
    project = insert_project(user: user)
    foreign = insert_project(user: other)
    {:ok, own} = Sections.create(user, nil, %{name: "Mine"})
    {:ok, theirs} = Sections.create(other, nil, %{name: "Theirs"})
    assert {:error, :not_found} = Sections.update(user, theirs.id, %{name: "Stolen"})
    assert {:error, :not_found} = Sections.delete(user, theirs.id)
    assert {:error, :not_found} = Sections.move(user, nil, project.id, theirs.id)
    assert {:error, :not_found} = Sections.move(user, nil, foreign.id, own.id)
    assert {:error, :not_found} = Sections.move(user, nil, foreign.id, "")
    assert {:ok, {[^theirs], %{}}} = Sections.list(other, nil)
  end

  test "project and track guests organize independently and lose move access on revocation" do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    member = insert_user()
    guest = insert_user()
    insert_project_member(project, member)
    membership = insert_track_member(track, guest)

    for user <- [owner, member, guest] do
      {:ok, section} = Sections.create(user, nil, %{name: "Work"})
      assert {:ok, _} = Sections.move(user, nil, project.id, section.id)
      assert {:ok, {[section], %{project.id => section.id}}} == Sections.list(user, nil)
    end

    Repo.delete!(membership)
    assert {:error, :not_found} = Sections.move(guest, nil, project.id, "")
  end

  describe "in a workspace" do
    setup do
      me = insert_user(login: "me")
      {:ok, personal} = Store.ensure_personal_workspace(me)
      {:ok, team} = Store.create_team_workspace(me.id, "Team")
      mine = insert_project(user: me, name: "Mine", repo_full_name: "me/app")
      team_project = insert_project(user: me, name: "TeamApp", repo_full_name: "team/api")
      1 = Store.move_project(team_project.id, team.id)
      %{me: me, personal: personal, team: team, mine: mine, team_project: team_project}
    end

    test "sections are listed and created per workspace, unscoped all at once", ctx do
      assert {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})
      assert {:ok, work} = Sections.create(ctx.me, ctx.team.id, %{name: "Work"})
      # The same name once per workspace.
      assert {:ok, again} = Sections.create(ctx.me, ctx.team.id, %{name: "Home"})
      assert {:error, %Ecto.Changeset{}} = Sections.create(ctx.me, ctx.team.id, %{name: "Home"})

      assert home.workspace_id == ctx.personal.id
      assert work.workspace_id == ctx.team.id

      assert {:ok, {[^home], %{}}} = Sections.list(ctx.me, ctx.personal.id)
      assert {:ok, {[^again, ^work], %{}}} = Sections.list(ctx.me, ctx.team.id)
      assert {:ok, {all, %{}}} = Sections.list(ctx.me, nil)
      assert Enum.sort(all) == Enum.sort([home, again, work])

      # Unscoped, a new section still lands in the personal workspace.
      assert {:ok, %{workspace_id: workspace_id}} = Sections.create(ctx.me, nil, %{name: "Later"})
      assert workspace_id == ctx.personal.id
    end

    test "a project goes only into a section of its own workspace", ctx do
      {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})
      {:ok, work} = Sections.create(ctx.me, ctx.team.id, %{name: "Work"})

      assert {:ok, _} = Sections.move(ctx.me, ctx.personal.id, ctx.mine.id, home.id)
      assert {:ok, _} = Sections.move(ctx.me, ctx.team.id, ctx.team_project.id, work.id)

      # A section of another workspace, and a project from one.
      assert {:error, {:conflict, "other_workspace", _}} =
               Sections.move(ctx.me, ctx.personal.id, ctx.mine.id, work.id)

      assert {:error, {:conflict, "other_workspace", _}} =
               Sections.move(ctx.me, ctx.team.id, ctx.mine.id, work.id)

      assert {:error, {:conflict, "other_workspace", _}} =
               Sections.move(ctx.me, ctx.personal.id, ctx.team_project.id, home.id)

      assert {:ok, {[^home], placements}} = Sections.list(ctx.me, ctx.personal.id)
      assert placements == %{ctx.mine.id => home.id}
      assert {:ok, {[^work], placements}} = Sections.list(ctx.me, ctx.team.id)
      assert placements == %{ctx.team_project.id => work.id}

      # Out of a section needs no workspace to agree.
      assert {:ok, nil} = Sections.move(ctx.me, ctx.team.id, ctx.mine.id, "")
      assert {:ok, {_, %{}}} = Sections.list(ctx.me, ctx.personal.id)

      # Unscoped, any section of the person's takes any project they reach.
      assert {:ok, _} = Sections.move(ctx.me, nil, ctx.mine.id, work.id)
    end

    test "another person's section and workspace ids, and a workspace left, are refused", ctx do
      other = insert_user(login: "other")
      {:ok, theirs} = Store.create_team_workspace(other.id, "Theirs")
      {:ok, their_section} = Sections.create(other, theirs.id, %{name: "Private"})

      assert {:error, :not_found} = Sections.list(ctx.me, theirs.id)
      assert {:error, :not_found} = Sections.create(ctx.me, theirs.id, %{name: "Sneak"})
      assert {:error, :not_found} = Sections.list(ctx.me, Ecto.UUID.generate())

      assert {:error, :not_found} =
               Sections.move(ctx.me, ctx.team.id, ctx.mine.id, their_section.id)

      assert {:error, :not_found} =
               Sections.move(ctx.me, theirs.id, ctx.mine.id, their_section.id)

      assert {:error, :not_found} = Sections.update(ctx.me, their_section.id, %{name: "Mine"})
      assert {:ok, {[^their_section], %{}}} = Sections.list(other, theirs.id)

      # Let in, then removed: the sections stay, out of reach.
      :ok = Store.add_member(theirs.id, ctx.me.id, :member, other.id)
      assert {:ok, mine_there} = Sections.create(ctx.me, theirs.id, %{name: "Visiting"})
      assert {:ok, {[^mine_there], %{}}} = Sections.list(ctx.me, theirs.id)
      {:ok, _} = Store.revoke_membership(theirs.id, ctx.me.id, other.id)
      assert {:error, :not_found} = Sections.list(ctx.me, theirs.id)
      assert {:error, :not_found} = Sections.create(ctx.me, theirs.id, %{name: "Still"})
      assert {:error, :not_found} = Sections.move(ctx.me, theirs.id, ctx.mine.id, mine_there.id)
      assert {:ok, {[^mine_there], %{}}} = Sections.list(ctx.me, nil)
    end

    test "a row the previous release wrote without a workspace reads as the personal one", ctx do
      legacy = old_writer_section(ctx.me, "Legacy")
      assert {:ok, {[^legacy], %{}}} = Sections.list(ctx.me, ctx.personal.id)
      assert {:ok, {[], %{}}} = Sections.list(ctx.me, ctx.team.id)

      assert {:ok, _} = Sections.move(ctx.me, ctx.personal.id, ctx.mine.id, legacy.id)
      assert {:ok, {[^legacy], placements}} = Sections.list(ctx.me, ctx.personal.id)
      assert placements == %{ctx.mine.id => legacy.id}

      assert {:error, {:conflict, "other_workspace", _}} =
               Sections.move(ctx.me, ctx.team.id, ctx.team_project.id, legacy.id)

      # Somebody else's personal workspace does not read my old rows.
      other = insert_user(login: "other")
      {:ok, _} = Store.ensure_personal_workspace(other)
      :ok = Store.add_member(ctx.personal.id, other.id, :member, ctx.me.id)
      assert {:ok, {[], %{}}} = Sections.list(other, ctx.personal.id)
    end

    test "a project that changes workspace leaves its placement behind", ctx do
      other = insert_user(login: "other")
      {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})
      {:ok, _} = Sections.move(ctx.me, ctx.personal.id, ctx.mine.id, home.id)
      # Somebody the project was shared with filed it too.
      insert_project_member(ctx.mine, other)
      {:ok, shared} = Sections.create(other, nil, %{name: "Shared"})
      {:ok, _} = Sections.move(other, nil, ctx.mine.id, shared.id)
      assert Repo.aggregate(SectionPlacement, :count) == 2

      assert {:ok, _} = Store.move_owned_project(ctx.mine.id, ctx.me.id, nil, ctx.team.id)
      assert Repo.aggregate(SectionPlacement, :count) == 0
      assert {:ok, {[^home], %{}}} = Sections.list(ctx.me, ctx.personal.id)
      assert {:ok, {[^shared], %{}}} = Sections.list(other, nil)
    end
  end

  describe "the backfill" do
    setup do
      me = insert_user(login: "me")
      {:ok, personal} = Store.ensure_personal_workspace(me)
      {:ok, team} = Store.create_team_workspace(me.id, "Team")
      mine = insert_project(user: me, name: "Mine", repo_full_name: "me/app")
      team_project = insert_project(user: me, name: "TeamApp", repo_full_name: "team/api")
      1 = Store.move_project(team_project.id, team.id)
      %{me: me, personal: personal, team: team, mine: mine, team_project: team_project}
    end

    test "a section takes the workspace of its projects; one with none goes home", ctx do
      filed = old_writer_section(ctx.me, "Filed")
      place!(ctx.me, ctx.team_project, filed)
      empty = old_writer_section(ctx.me, "Empty", collapsed: true)
      legacy = old_writer_section(ctx.me, "Legacy")
      place!(ctx.me, ctx.mine, legacy)

      assert %{sections: 3} = Ravix.Workspaces.Backfill.run()

      assert reload(filed).workspace_id == ctx.team.id
      assert reload(empty).workspace_id == ctx.personal.id
      assert reload(empty).collapsed
      assert reload(legacy).workspace_id == ctx.personal.id
      assert Repo.aggregate(Section, :count) == 3

      assert {:ok, {[filed], placements}} = Sections.list(ctx.me, ctx.team.id)
      assert placements == %{ctx.team_project.id => filed.id}
      assert {:ok, {[empty, legacy], placements}} = Sections.list(ctx.me, ctx.personal.id)
      assert placements == %{ctx.mine.id => legacy.id}
      assert {empty.name, legacy.name} == {"Empty", "Legacy"}

      assert %{sections: 0} = Ravix.Workspaces.Backfill.run()
    end

    test "a section spanning workspaces is split, placements following their copy", ctx do
      other = insert_user(login: "other")
      {:ok, theirs} = Store.create_team_workspace(other.id, "Theirs")
      :ok = Store.add_member(theirs.id, ctx.me.id, :member, other.id)
      their_project = insert_project(user: other, name: "Theirs", repo_full_name: "o/their")
      1 = Store.move_project(their_project.id, theirs.id)
      # A legacy project somebody shared sits in the personal sidebar.
      shared = insert_project(user: other, name: "Shared", repo_full_name: "o/shared")
      insert_project_member(shared, ctx.me)

      mixed = old_writer_section(ctx.me, "Mixed", collapsed: true)

      for project <- [ctx.mine, ctx.team_project, their_project, shared],
          do: place!(ctx.me, project, mixed)

      assert %{sections: 1} = Ravix.Workspaces.Backfill.run()

      assert {:ok, {[home], placements}} = Sections.list(ctx.me, ctx.personal.id)
      assert home.id == mixed.id
      assert home.collapsed
      assert placements == %{ctx.mine.id => mixed.id, shared.id => mixed.id}

      assert {:ok, {[work], placements}} = Sections.list(ctx.me, ctx.team.id)
      assert {work.name, work.collapsed} == {"Mixed", true}
      assert placements == %{ctx.team_project.id => work.id}

      assert {:ok, {[visiting], placements}} = Sections.list(ctx.me, theirs.id)
      assert {visiting.name, visiting.collapsed} == {"Mixed", true}
      assert placements == %{their_project.id => visiting.id}

      assert Repo.aggregate(Section, :count) == 3
      assert Repo.aggregate(SectionPlacement, :count) == 4

      # A second run has nothing left.
      rows = Repo.all(from s in Section, order_by: s.id)
      assert %{sections: 0} = Ravix.Workspaces.Backfill.run()
      assert Repo.all(from s in Section, order_by: s.id) == rows
    end

    test "joins a same-named section this release already created, leaving no duplicate", ctx do
      {:ok, work} = Sections.create(ctx.me, ctx.team.id, %{name: "Work"})
      {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Work"})
      old = old_writer_section(ctx.me, "Work")
      place!(ctx.me, ctx.team_project, old)
      place!(ctx.me, ctx.mine, old)

      assert %{sections: 1} = Ravix.Workspaces.Backfill.run()
      assert Repo.get(Section, old.id) == nil
      assert {:ok, {[^work], placements}} = Sections.list(ctx.me, ctx.team.id)
      assert placements == %{ctx.team_project.id => work.id}
      assert {:ok, {[^home], placements}} = Sections.list(ctx.me, ctx.personal.id)
      assert placements == %{ctx.mine.id => home.id}
    end

    test "waits for an owner the personal-workspace backfill has not reached, and resumes", ctx do
      newcomer = insert_user(login: "new")
      waiting = old_writer_section(newcomer, "Waiting")
      for n <- 1..3, do: old_writer_section(ctx.me, "Batch #{n}")

      # The step alone, in bounded batches: the newcomer's row is not ready.
      assert Ravix.Projects.Sections.Store.scope_sections(2) == 2
      assert Ravix.Projects.Sections.Store.scope_sections(2) == 1
      assert Ravix.Projects.Sections.Store.scope_sections(2) == 0
      assert is_nil(reload(waiting).workspace_id)

      # The whole backfill makes the newcomer's workspace first, then settles it.
      assert %{sections: 1} = Ravix.Workspaces.Backfill.run(batch_size: 1)
      assert reload(waiting).workspace_id == Store.personal_workspace(newcomer.id).id
      assert Repo.aggregate(from(s in Section, where: is_nil(s.workspace_id)), :count) == 0
    end
  end

  # A section as the release before this one inserts it: no workspace.
  defp old_writer_section(user, name, attrs \\ []) do
    Repo.insert!(%Section{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      name: name,
      collapsed: Keyword.get(attrs, :collapsed, false)
    })
  end

  defp place!(user, project, section) do
    Repo.insert!(%SectionPlacement{
      user_id: user.id,
      project_id: project.id,
      section_id: section.id
    })
  end

  defp reload(%Section{id: id}), do: Repo.get!(Section, id)
end
