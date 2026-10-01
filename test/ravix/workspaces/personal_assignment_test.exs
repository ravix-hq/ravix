defmodule Ravix.Workspaces.PersonalAssignmentTest do
  @moduledoc """
  The personal-workspace assignment: a dry run writes nothing, apply moves
  every live legacy project into its owner's personal workspace once, a
  same-repository collision is marked a legacy duplicate for the owner to
  decide rather than moved, and archived, deleting and already-marked
  projects are skipped. Legacy members keep reaching a moved project.
  """
  use Ravix.DataCase, async: true

  # Marking a duplicate by explicit canonical choice logs a warning by design.
  @moduletag :capture_log

  import ExUnit.CaptureIO
  import Ravix.Factory

  alias Mix.Tasks.Ravix.AssignPersonalWorkspaces
  alias Ravix.Accounts.Access
  alias Ravix.Projects.{Project, Sections}
  alias Ravix.Workspaces.{PersonalAssignment, RepositoryReservation, Store}

  setup do
    ada = insert_user(login: "ada")
    {:ok, personal} = Store.ensure_personal_workspace(ada)
    early = ~U[2026-09-01 00:00:00.000000Z]
    late = ~U[2026-09-20 00:00:00.000000Z]

    plain = insert_project(user: ada, repo_full_name: "ada/app", created_at: early)
    scratch = insert_project(user: ada, repo_full_name: nil, created_at: early)

    # Already in the personal workspace; the legacy one for its repository
    # must not be moved beside it.
    held = insert_project(user: ada, repo_full_name: "ada/held", created_at: late)
    1 = Store.move_project(held.id, personal.id)
    colliding = insert_project(user: ada, repo_full_name: " Ada/Held ", created_at: early)

    # Two legacy projects of one repository: the older moves, the later is
    # marked its duplicate.
    older = insert_project(user: ada, repo_full_name: "ada/twice", created_at: early)
    later = insert_project(user: ada, repo_full_name: "ada/twice", created_at: late)

    archived = insert_project(user: ada, repo_full_name: "ada/old", archived_at: late)

    deleting =
      insert_project(user: ada, repo_full_name: "ada/going")
      |> Ecto.Changeset.change(deletion_requested_at: late)
      |> Repo.update!()

    marked_canonical = insert_project(user: ada, repo_full_name: "ada/pair", created_at: early)
    marked = insert_project(user: ada, repo_full_name: "ada/pair", created_at: late)
    {:ok, _} = Store.mark_legacy_duplicate(marked.id, marked_canonical.id)

    # Somebody the personal-workspace backfill has not reached.
    newcomer = insert_project(repo_full_name: "new/comer")

    %{
      ada: ada,
      personal: personal,
      plain: plain,
      scratch: scratch,
      held: held,
      colliding: colliding,
      older: older,
      later: later,
      archived: archived,
      deleting: deleting,
      marked_canonical: marked_canonical,
      marked: marked,
      newcomer: newcomer
    }
  end

  defp reload(%Project{id: id}), do: Repo.get!(Project, id)
  defp by_id(summary), do: Map.new(summary.projects, &{&1.id, &1})
  defp snapshot, do: Repo.all(from p in Project, order_by: p.id) |> Enum.map(&Map.from_struct/1)

  test "a dry run reports every unassigned project and writes nothing", ctx do
    before = snapshot()
    assert {:ok, %{applied: false} = summary} = PersonalAssignment.run()
    assert snapshot() == before
    assert Repo.aggregate(RepositoryReservation, :count) == 1

    lines = by_id(summary)
    refute Map.has_key?(lines, ctx.held.id)

    for project <- [ctx.plain, ctx.scratch, ctx.older, ctx.marked_canonical] do
      assert %{action: :move, workspace_id: workspace_id, owner: "ada"} = lines[project.id]
      assert workspace_id == ctx.personal.id
    end

    assert lines[ctx.colliding.id].action == :duplicate
    assert lines[ctx.colliding.id].duplicate_of == ctx.held.id
    assert lines[ctx.later.id].action == :duplicate
    assert lines[ctx.later.id].duplicate_of == ctx.older.id
    assert lines[ctx.archived.id].action == :archived
    assert lines[ctx.deleting.id].action == :deleting
    assert lines[ctx.marked.id].action == :legacy_duplicate
    assert %{action: :no_workspace, workspace_id: nil} = lines[ctx.newcomer.id]
  end

  test "apply moves, marks collisions and skips the rest; a re-run changes nothing", ctx do
    member = insert_user()
    insert_project_member(ctx.plain, member)
    track = insert_track(project: ctx.plain)

    # Sidebar placements of a project that moves are dropped (RAV-127): the
    # owner's, and a member's; one of a project left alone stays.
    {:ok, filed} = Sections.create(ctx.ada, nil, %{name: "Filed"})
    {:ok, _} = Sections.move(ctx.ada, nil, ctx.plain.id, filed.id)
    {:ok, _} = Sections.move(ctx.ada, nil, ctx.colliding.id, filed.id)
    {:ok, theirs} = Sections.create(member, nil, %{name: "Theirs"})
    {:ok, _} = Sections.move(member, nil, ctx.plain.id, theirs.id)

    assert {:ok, %{applied: true} = applied} = PersonalAssignment.run(apply: true)

    assert {:ok, {[^filed], placements}} = Sections.list(ctx.ada, nil)
    assert placements == %{ctx.colliding.id => filed.id}
    assert {:ok, {[^theirs], %{}}} = Sections.list(member, nil)
    results = Map.new(applied.projects, &{&1.id, &1.result})
    assert results[ctx.plain.id] == :moved
    assert results[ctx.colliding.id] == :marked
    assert results[ctx.archived.id] == nil

    for project <- [ctx.plain, ctx.scratch, ctx.older, ctx.marked_canonical] do
      moved = reload(project)
      assert moved.workspace_id == ctx.personal.id
      assert moved.user_id == ctx.ada.id
      assert is_nil(moved.legacy_duplicate_at)
    end

    for {duplicate, canonical} <- [{ctx.colliding, ctx.held}, {ctx.later, ctx.older}] do
      marked = reload(duplicate)
      assert is_nil(marked.workspace_id)
      assert marked.legacy_duplicate_of == canonical.id
    end

    for project <- [ctx.archived, ctx.deleting, ctx.marked, ctx.newcomer],
        do: assert(is_nil(reload(project).workspace_id))

    # The legacy member still reaches the project and its track.
    assert {:ok, %{role: :member}} = Access.project_access(member, ctx.plain.id)
    assert Repo.get!(Ravix.Tracks.Track, track.id).project_id == ctx.plain.id

    after_first = snapshot()
    reservations = Repo.aggregate(RepositoryReservation, :count)
    assert {:ok, %{applied: true} = again} = PersonalAssignment.run(apply: true)
    assert snapshot() == after_first
    assert Repo.aggregate(RepositoryReservation, :count) == reservations
    refute Enum.any?(again.projects, &(&1.action in [:move, :duplicate]))
  end

  test "the summary names projects, owners and decisions, and no secret", ctx do
    {:ok, summary} = PersonalAssignment.run()
    [head | lines] = PersonalAssignment.format(summary)

    assert head =~ "Dry run (pass --apply to write)"
    assert head =~ "4 move"
    assert head =~ "2 duplicate"
    text = Enum.join(lines, "\n")
    assert text =~ "#{ctx.plain.id} #{ctx.plain.name} (ada/app, @ada): move into personal"

    assert text =~
             "not moved: a legacy duplicate of #{ctx.held.id}, which holds this repository in " <>
               "personal workspace #{ctx.personal.id}"

    assert text =~ "skipped: archived"
    assert text =~ "skipped: deletion requested"
    assert text =~ "skipped: already a legacy duplicate"
    assert text =~ "the owner has no personal workspace yet"
    refute text =~ ctx.plain.vault_id
    refute text =~ ctx.plain.agent_id

    {:ok, applied} = PersonalAssignment.run(apply: true)
    assert hd(PersonalAssignment.format(applied)) =~ "Applied"

    assert PersonalAssignment.format(%{applied: false, projects: []}) == [
             "Dry run (pass --apply to write): no unassigned projects"
           ]
  end

  describe "who else holds what" do
    setup ctx do
      zed = insert_user(login: "zed")
      bo = insert_user(login: "bo")
      insert_project_member(ctx.plain, zed)
      track = insert_track(project: ctx.plain)
      other_track = insert_track(project: ctx.plain)
      insert_track_member(track, bo)
      insert_track_member(other_track, bo)
      # The owner's own seat is not somebody else's.
      insert_track_member(track, ctx.ada)
      insert_track_invite(track, login: "pending")
      insert_project_invite(ctx.plain, login: "waiting")
      {_token, _link} = insert_track_link(track)
      expired = DateTime.add(DateTime.utc_now(), -1, :day)
      {_token, _link} = insert_project_link(ctx.plain, expires_at: expired)

      # Shared, but only through what carries over.
      insert_project_member(ctx.scratch, bo)
      %{zed: zed, bo: bo}
    end

    test "is inventoried per project, and a line that loses something is marked", ctx do
      {:ok, summary} = PersonalAssignment.run()
      lines = by_id(summary)

      assert lines[ctx.plain.id].sharing == %{
               members: ["zed"],
               seats: ["bo"],
               invites: ["waiting", "pending"],
               links: 1
             }

      assert lines[ctx.scratch.id].sharing == %{members: ["bo"], seats: [], invites: [], links: 0}
      assert lines[ctx.older.id].sharing == %{members: [], seats: [], invites: [], links: 0}

      text = Enum.join(PersonalAssignment.format(summary), "\n")
      assert text =~ "1 moving project(s) have waiting invitations or links that stop working"

      assert text =~
               "    LOSES invitations/links; project members @zed (kept); track seats @bo (kept); " <>
                 "waiting invitations @waiting, @pending; 1 unexpired link(s)"

      assert text =~ "    shared: project members @bo (kept)"
      refute text =~ "token"
    end

    test "carries members and seats over on apply", ctx do
      {:ok, _} = PersonalAssignment.run(apply: true)
      assert reload(ctx.plain).workspace_id == ctx.personal.id
      assert {:ok, %{role: :member}} = Access.project_access(ctx.zed, ctx.plain.id)
      assert {:ok, %{role: :member}} = Access.project_access(ctx.bo, ctx.scratch.id)
    end
  end

  test "an archived canonical project is named as such", ctx do
    ctx.held |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    {:ok, summary} = PersonalAssignment.run()
    assert %{action: :duplicate, canonical_state: :archived} = by_id(summary)[ctx.colliding.id]
    text = Enum.join(PersonalAssignment.format(summary), "\n")
    assert text =~ "personal workspace #{ctx.personal.id} (that project is archived)"
    assert by_id(summary)[ctx.later.id].canonical_state == :live
  end

  test "the write re-checks the row: changed since the plan is skipped, a collision reported",
       ctx do
    ctx.plain |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    assert Store.assign_personal(ctx.plain.id, ctx.personal.id) == :skipped
    assert is_nil(reload(ctx.plain).workspace_id)

    # `colliding` would land beside `held`, which the plan would have caught.
    assert Store.assign_personal(ctx.colliding.id, ctx.personal.id) == :collision
    assert is_nil(reload(ctx.colliding).workspace_id)

    assert Store.assign_personal(ctx.older.id, ctx.personal.id) == :moved
    assert Store.assign_personal(ctx.older.id, ctx.personal.id) == :skipped

    line = %{
      id: "p",
      name: "n",
      repo: "r/r",
      owner: "ada",
      workspace_id: "w",
      action: :move,
      duplicate_of: nil,
      canonical_state: nil,
      sharing: %{members: [], seats: [], invites: ["x"], links: 0},
      result: nil
    }

    text =
      Enum.join(
        PersonalAssignment.format(%{
          applied: true,
          projects: [
            %{line | result: :skipped},
            %{line | result: :collision},
            %{line | result: :moved},
            %{line | action: :duplicate, duplicate_of: "c", result: :marked},
            %{line | action: :duplicate, duplicate_of: "c", result: {:failed, :already_marked}}
          ]
        }),
        "\n"
      )

    assert text =~ "-> skipped at write: no longer unassigned, live and unmarked"
    assert text =~ "-> not moved: the workspace gained a project for this repository"
    assert text =~ "-> moved"
    assert text =~ "-> marked"
    assert text =~ "-> not marked: already_marked"
    # Only the line that did move is counted as losing its invitation.
    assert text =~ "1 moving project(s) have waiting invitations"
  end

  test "the release entry and the Mix task run it, dry by default", ctx do
    output = capture_io(fn -> Ravix.Release.assign_personal_workspaces() end)
    assert output =~ "Dry run"
    assert is_nil(reload(ctx.plain).workspace_id)

    output = capture_io(fn -> AssignPersonalWorkspaces.run([]) end)
    assert output =~ "Dry run"
    assert is_nil(reload(ctx.plain).workspace_id)

    output = capture_io(fn -> AssignPersonalWorkspaces.run(["--apply"]) end)
    assert output =~ "Applied"
    assert reload(ctx.plain).workspace_id == ctx.personal.id

    output = capture_io(fn -> Ravix.Release.assign_personal_workspaces(true) end)
    assert output =~ "Applied"
    refute output =~ " move into"

    assert_raise Mix.Error, ~r/Usage/, fn -> AssignPersonalWorkspaces.run(["--bogus"]) end
  end
end
