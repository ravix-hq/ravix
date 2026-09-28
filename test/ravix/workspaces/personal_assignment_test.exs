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
  alias Ravix.Projects.Project
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

    assert {:ok, %{applied: true}} = PersonalAssignment.run(apply: true)

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
