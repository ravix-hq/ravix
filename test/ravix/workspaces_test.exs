defmodule Ravix.WorkspacesTest do
  @moduledoc """
  ADR 0009 phase 2: the workspace expand, its backfill and its dual readers.

  The phase's promise is that nothing changes for anybody, so as much of
  this file proves what did *not* happen -- no access granted through a
  workspace, no old-release row misread -- as proves what the new rows are.
  """
  use Ravix.DataCase, async: true

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Projects.Project
  alias Ravix.Tracks.{Thread, Track}
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Backfill, Installation, Membership, RepositoryReservation, Store}
  alias Ravix.Workspaces.Workspace

  # The `projects` row as the release before this one knows it: none of the
  # ADR 0009 columns. Inserting through it is exactly what an old writer
  # does while this release's migration has already run.
  defmodule PreviousReleaseProject do
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "projects" do
      field :user_id, :string
      field :name, :string
      field :repo_full_name, :string
      field :agent_id, :string
      field :environment_id, :string
      field :runtime, :string
      field :model, :string
      field :rev, :integer, default: 1
      field :created_at, :utc_datetime_usec
    end
  end

  defp old_writer_project(user, attrs \\ []) do
    row =
      struct!(
        PreviousReleaseProject,
        Keyword.merge(
          [
            id: Ecto.UUID.generate(),
            user_id: user.id,
            name: "old",
            repo_full_name: "Acme/Widget",
            agent_id: "agent",
            environment_id: "env",
            runtime: "claude-code",
            model: "anthropic/claude-sonnet-5",
            created_at: DateTime.utc_now()
          ],
          attrs
        )
      )

    %{id: id} = Repo.insert!(row)
    Repo.get!(Project, id)
  end

  # A user as an older release creates one: no personal workspace.
  defp personal(user), do: Repo.get_by(Workspace, personal_user_id: user.id)

  defp workspace!(attrs) do
    %Workspace{}
    |> Workspace.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp member!(workspace, user, role, attrs \\ []) do
    %Membership{}
    |> Membership.changeset(
      Map.merge(%{workspace_id: workspace.id, user_id: user.id, role: role}, Map.new(attrs))
    )
    |> Repo.insert!()
  end

  describe "the backfill" do
    test "gives every user one personal workspace they own, and is idempotent" do
      [a, b] = [insert_user(login: "ana"), insert_user(login: "bo")]

      first = Backfill.run()
      assert first.workspaces >= 2
      assert first.memberships >= 2

      for user <- [a, b] do
        workspace = personal(user)
        assert workspace.kind == :personal
        assert workspace.name == user.login
        assert workspace.created_by_user_id == user.id
        assert Store.membership(workspace.id, user.id).role == :owner
        assert {:ok, ^workspace} = Workspaces.personal_workspace(user)
      end

      assert Backfill.run() == %{workspaces: 0, memberships: 0, projects: 0}
      assert Repo.aggregate(where(Workspace, personal_user_id: ^a.id), :count) == 1
      assert Repo.aggregate(where(Membership, user_id: ^a.id), :count) == 1
    end

    test "resumes an interrupted run without duplicating what it already wrote" do
      users = for _ <- 1..3, do: insert_user()
      Backfill.run()
      # Start from nothing again for exactly these three.
      Repo.delete_all(from w in Workspace, where: w.personal_user_id in ^Enum.map(users, & &1.id))

      assert %{workspaces: 1, memberships: 1} = Backfill.run(batch_size: 1, max_batches: 1)
      assert Enum.count(users, &personal/1) == 1

      assert %{workspaces: 2, memberships: 2} = Backfill.run(batch_size: 1)
      assert Enum.all?(users, &personal/1)
      assert Backfill.run(batch_size: 1) == %{workspaces: 0, memberships: 0, projects: 0}
    end

    test "repairs a workspace an interrupted run left without its owner, but never un-revokes" do
      [kept, revoked] = [insert_user(), insert_user()]
      half = workspace!(name: "half", kind: :personal, personal_user_id: kept.id)
      gone = workspace!(name: "gone", kind: :personal, personal_user_id: revoked.id)
      member!(gone, revoked, :owner, revoked_at: DateTime.utc_now())

      assert %{memberships: memberships} = Backfill.run()
      assert memberships >= 1
      assert Store.membership(half.id, kept.id).role == :owner
      assert Store.membership(gone.id, revoked.id) == nil
      assert {:error, :not_found} = Access.workspace_access(revoked, gone.id)
    end

    test "fills an old writer's project fields, never its workspace, and stops when done" do
      owner = insert_user()
      project = old_writer_project(owner)
      scratch = old_writer_project(owner, repo_full_name: nil)
      blank = old_writer_project(owner, repo_full_name: "  ")

      assert %{projects: filled} = Backfill.run()
      assert filled >= 3

      assert %Project{
               created_by_user_id: created_by,
               normalized_repo_full_name: "acme/widget",
               workspace_id: nil
             } = Repo.get!(Project, project.id)

      assert created_by == owner.id
      assert Repo.get!(Project, scratch.id).normalized_repo_full_name == nil
      assert Repo.get!(Project, blank.id).normalized_repo_full_name == nil
      assert Backfill.run().projects == 0
    end
  end

  describe "bounded batches" do
    test "a batch past its statement timeout is cancelled and rolled back" do
      user = insert_user()

      assert_raise Postgrex.Error, ~r/statement timeout/, fn ->
        Store.bounded(
          fn ->
            Store.insert_personal_workspaces(10)
            Repo.query!("SELECT pg_sleep(1)")
          end,
          50
        )
      end

      assert personal(user) == nil
    end
  end

  describe "dual readers" do
    test "an old writer's project reads as legacy, with every fallback" do
      owner = insert_user()
      project = old_writer_project(owner)

      assert project.created_by_user_id == nil
      assert project.normalized_repo_full_name == nil
      assert Workspaces.layout(project) == :legacy
      assert Workspaces.created_by(project) == owner.id
      assert Workspaces.repo_key(project) == "acme/widget"
      refute Workspaces.scratch?(project)
      refute Workspaces.legacy_duplicate?(project)
      assert Workspaces.scratch?(old_writer_project(owner, repo_full_name: nil))

      # The legacy door admits its owner exactly as it did.
      assert {:ok, %{role: :owner}} = Access.project_access(owner, project.id)
      assert {:ok, %Project{}} = Access.project_of(owner, project.id)
    end

    test "this release dual-writes the equivalent fields and nothing else" do
      owner = insert_user()
      project = insert_project(user: owner, repo_full_name: "Acme/Gadget")

      assert project.created_by_user_id == owner.id
      assert project.normalized_repo_full_name == "acme/gadget"
      assert project.repo_full_name == "Acme/Gadget"
      assert Project.normalize_repo("  Acme/Gadget ") == "acme/gadget"
      assert Project.normalize_repo(" ") == nil
      assert project.workspace_id == nil
      assert project.legacy_duplicate_at == nil
      assert Workspaces.layout(project) == :legacy
      assert Workspaces.repo_key(project) == "acme/gadget"
      assert insert_project(user: owner, repo_full_name: nil).normalized_repo_full_name == nil

      # A client cannot mark itself, or place itself in a workspace.
      changeset =
        Project.changeset(%Project{}, %{
          workspace_id: "w",
          legacy_duplicate_at: DateTime.utc_now(),
          legacy_duplicate_of: "p"
        })

      refute Map.has_key?(changeset.changes, :workspace_id)
      refute Map.has_key?(changeset.changes, :legacy_duplicate_at)
      refute Map.has_key?(changeset.changes, :legacy_duplicate_of)
    end

    test "the previous release reads a row this release wrote in the workspace layout" do
      owner = insert_user()
      workspace = workspace!(name: "team", kind: :team)
      project = insert_project(user: owner, repo_full_name: "acme/mixed")
      Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])

      old = Repo.get!(PreviousReleaseProject, project.id)
      assert old.user_id == owner.id
      assert old.repo_full_name == "acme/mixed"

      current = Repo.get!(Project, project.id)
      assert Workspaces.layout(current) == {:workspace, workspace.id}
      assert Workspaces.created_by(current) == owner.id
    end

    test "every track reads as owner-paid until creator billing binds it" do
      owner = insert_user()
      creator = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, created_by: creator.id)

      # A track as an older release writes it: neither billing column.
      old_id = Ecto.UUID.generate()

      {1, _} =
        Repo.insert_all(Track, [
          %{
            id: old_id,
            project_id: project.id,
            rev: 1,
            slug: "old-writer",
            title: "Old",
            branch: "u/old-#{old_id}",
            workdir: "/w/old",
            origin_kind: :blank,
            created_by_login: "u",
            created_at: DateTime.utc_now()
          }
        ])

      for row <- [track, Repo.get!(Track, old_id)] do
        assert {row.payer_user_id, row.billing_policy} == {nil, nil}
        assert Track.payer(row, project) == {:legacy_owner, owner.id}
      end

      # Legacy by name as well as by default, and never inferred from the creator.
      explicit = %{track | billing_policy: :legacy_owner, payer_user_id: creator.id}
      assert Track.payer(explicit, project) == {:legacy_owner, owner.id}

      # A bound track pays its creator, whoever starts or prompts a thread,
      # and a payer whose account is gone is nil -- refuse, not the owner.
      bound = %{track | billing_policy: :starter, payer_user_id: creator.id}
      assert Track.payer(bound, project) == {:starter, creator.id}
      assert Track.payer(%{bound | payer_user_id: nil}, project) == {:starter, nil}

      # A project that is not the track's is a caller bug, not an answer.
      assert_raise FunctionClauseError, fn -> Track.payer(track, insert_project()) end

      # Changesets cannot bind billing; only the billing phase will.
      changeset = Track.changeset(track, %{billing_policy: :starter, payer_user_id: creator.id})
      refute Map.has_key?(changeset.changes, :billing_policy)
      refute Map.has_key?(changeset.changes, :payer_user_id)

      assert_raise Postgrex.Error, ~r/tracks_billing_policy/, fn ->
        Repo.query!("UPDATE ravix.tracks SET billing_policy = 'workspace' WHERE id = $1", [
          track.id
        ])
      end

      # Added NOT VALID under the expand's lock timeout, then validated.
      assert %{rows: [[true]]} =
               Repo.query!(
                 "SELECT convalidated FROM pg_constraint WHERE conname = 'tracks_billing_policy'"
               )
    end

    test "threads carry only starter attribution, never a payer" do
      track = insert_track()
      {:ok, thread} = Ravix.Tracks.Store.create_thread(%{track_id: track.id, title: "t"})

      assert Repo.get!(Thread, thread.id).started_by == nil
      refute :payer_user_id in Thread.__schema__(:fields)
      refute :billing_policy in Thread.__schema__(:fields)

      assert %{rows: []} =
               Repo.query!(
                 "SELECT 1 FROM information_schema.columns WHERE table_schema = 'ravix' " <>
                   "AND table_name = 'threads' AND column_name IN ('payer_user_id', 'billing_policy')"
               )
    end

    test "the Elixir and SQL normalizations agree, whitespace included" do
      owner = insert_user()

      inputs = [
        "Acme/Widget",
        " Acme/Widget ",
        "\tAcme/Widget\n",
        "\r\n Acme/Widget\t \r",
        "ACME/widget-2.0_x",
        "   ",
        "\t\n",
        nil
      ]

      rows = for repo <- inputs, do: {repo, old_writer_project(owner, repo_full_name: repo)}
      Backfill.run()

      for {repo, project} <- rows do
        assert Repo.get!(Project, project.id).normalized_repo_full_name ==
                 Project.normalize_repo(repo),
               "SQL and Elixir disagree about #{inspect(repo)}"
      end

      assert Project.normalize_repo("\tAcme/Widget\n") == "acme/widget"
      assert Project.normalize_repo("\t\n") == nil
    end
  end

  describe "the catalog constraint" do
    setup do
      owner = insert_user()
      workspace = workspace!(name: "team", kind: :team)
      %{owner: owner, workspace: workspace}
    end

    defp admit(project, workspace) do
      Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])
    end

    test "refuses a second project for one repository in one workspace, ignoring case", ctx do
      first = insert_project(user: ctx.owner, repo_full_name: "acme/one")
      second = insert_project(user: ctx.owner, repo_full_name: "ACME/One")
      admit(first, ctx.workspace)

      assert_raise Postgrex.Error, ~r/projects_workspace_repo/, fn ->
        admit(second, ctx.workspace)
      end

      # The changeset turns the same violation into an error, not a crash.
      attrs = project_attrs(user_id: ctx.owner.id, repo_full_name: "Acme/ONE")

      assert {:error, changeset} =
               %Project{workspace_id: ctx.workspace.id}
               |> Project.changeset(attrs)
               |> Repo.insert()

      assert %{repo_full_name: ["is already a project in this workspace"]} = errors_on(changeset)
    end

    test "ignores legacy rows, scratch projects, marked duplicates and other workspaces", ctx do
      # Legacy duplicates of one repository coexist, as they do in production.
      earlier = insert_project(user: ctx.owner, repo_full_name: "acme/two")
      later = insert_project(user: insert_user(), repo_full_name: "acme/two")
      assert Workspaces.repo_key(earlier) == Workspaces.repo_key(later)

      for _ <- 1..2,
          do: admit(insert_project(user: ctx.owner, repo_full_name: nil), ctx.workspace)

      admit(earlier, ctx.workspace)
      bump(later)
      assert {:ok, _} = Store.mark_legacy_duplicate(later.id, earlier.id)
      assert {1, _} = admit(later, ctx.workspace)

      elsewhere = workspace!(name: "other", kind: :team)
      assert {1, _} = admit(insert_project(repo_full_name: "acme/two"), elsewhere)
    end
  end

  # Order by persisted creation, which the factory stamps to the microsecond.
  defp bump(project, seconds \\ 60) do
    at = DateTime.add(project.created_at, seconds)
    Repo.update_all(where(Project, id: ^project.id), set: [created_at: at])
  end

  describe "legacy duplicates" do
    setup do
      owner = insert_user()
      raunak = insert_user()
      canonical = insert_project(user: owner, name: "ravix2", repo_full_name: "ravix-hq/ravix")
      duplicate = insert_project(user: raunak, name: "ravix", repo_full_name: "Ravix-HQ/ravix")
      bump(duplicate)
      %{owner: owner, raunak: raunak, canonical: canonical, duplicate: duplicate}
    end

    test "marks the later project, keeps its access, and reserves its repository", ctx do
      member = insert_user()
      insert_project_member(ctx.duplicate, member)

      assert {:ok, marked} = Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)
      assert marked.legacy_duplicate_of == ctx.canonical.id
      assert Workspaces.legacy_duplicate?(marked)
      refute Workspaces.legacy_duplicate?(Repo.get!(Project, ctx.canonical.id))

      # Nothing about who reaches it changed.
      assert {:ok, %{role: :owner}} = Access.project_access(ctx.raunak, marked.id)
      assert {:ok, %{role: :member}} = Access.project_access(member, marked.id)
      assert {:error, :not_found} = Access.project_access(ctx.owner, marked.id)

      assert Workspaces.reserved_for?(ctx.raunak, "RAVIX-HQ/RAVIX")
      refute Workspaces.reserved_for?(ctx.owner, "ravix-hq/ravix")
      refute Workspaces.reserved_for?(ctx.raunak, nil)

      # Marking again is a no-op, and the reservation outlives the project.
      assert {:ok, again} = Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)
      assert again.legacy_duplicate_at == marked.legacy_duplicate_at
      Repo.delete!(Repo.get!(Project, ctx.duplicate.id))

      assert [%RepositoryReservation{reserved_project_id: id, reason: :legacy_duplicate}] =
               Repo.all(where(RepositoryReservation, user_id: ^ctx.raunak.id))

      assert id == ctx.duplicate.id
      assert Workspaces.reserved_for?(ctx.raunak, "ravix-hq/ravix")
    end

    test "refuses anything but a later project on the same repository", ctx do
      assert {:error, :same_project} =
               Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.duplicate.id)

      assert {:error, :not_later} =
               Store.mark_legacy_duplicate(ctx.canonical.id, ctx.duplicate.id)

      assert {:error, :not_found} = Store.mark_legacy_duplicate(ctx.duplicate.id, "missing")
      assert {:error, :not_found} = Store.mark_legacy_duplicate("missing", ctx.canonical.id)

      other = insert_project(user: ctx.raunak, repo_full_name: "acme/else")
      bump(other)

      assert {:error, :different_repository} =
               Store.mark_legacy_duplicate(other.id, ctx.canonical.id)

      scratch = insert_project(user: ctx.raunak, repo_full_name: nil)

      assert {:error, :different_repository} =
               Store.mark_legacy_duplicate(scratch.id, ctx.canonical.id)

      Repo.update_all(where(Project, id: ^ctx.duplicate.id),
        set: [created_at: ctx.canonical.created_at]
      )

      assert {:error, :ambiguous_order} =
               Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)

      assert Repo.aggregate(RepositoryReservation, :count) == 0
      refute Workspaces.legacy_duplicate?(Repo.get!(Project, ctx.duplicate.id))
    end

    test "refuses re-marking against another canonical, and a duplicate as canonical", ctx do
      third = insert_project(user: insert_user(), repo_full_name: "ravix-hq/RAVIX")
      bump(third, 120)
      assert {:ok, marked} = Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)

      # Same pair again: a no-op. Another canonical: refused, nothing moves.
      assert {:ok, ^marked} = Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)

      assert {:error, :canonical_is_duplicate} =
               Store.mark_legacy_duplicate(third.id, ctx.duplicate.id)

      assert {:ok, _} = Store.mark_legacy_duplicate(third.id, ctx.canonical.id)
      other_earlier = insert_project(user: insert_user(), repo_full_name: "ravix-hq/ravix")
      bump(other_earlier, -600)

      assert {:error, :already_marked} =
               Store.mark_legacy_duplicate(ctx.duplicate.id, other_earlier.id)

      assert Repo.get!(Project, ctx.duplicate.id).legacy_duplicate_of == ctx.canonical.id
      assert Repo.aggregate(RepositoryReservation, :count) == 2
    end

    test "a duplicate in a workspace reserves the repository in that workspace", ctx do
      workspace = workspace!(name: "team", kind: :team)
      member!(workspace, ctx.raunak, :member)
      Repo.update_all(where(Project, id: ^ctx.duplicate.id), set: [workspace_id: workspace.id])

      assert {:ok, _} = Store.mark_legacy_duplicate(ctx.duplicate.id, ctx.canonical.id)

      assert [%RepositoryReservation{workspace_id: workspace_id, user_id: nil}] =
               Repo.all(RepositoryReservation)

      assert workspace_id == workspace.id
      assert {:ok, true} = Workspaces.reserved_in?(ctx.raunak, workspace.id, "Ravix-HQ/Ravix")
      assert {:ok, false} = Workspaces.reserved_in?(ctx.raunak, workspace.id, "acme/else")

      assert {:error, :not_found} =
               Workspaces.reserved_in?(ctx.owner, workspace.id, "ravix-hq/ravix")

      # A workspace reservation is not the owner's legacy one.
      refute Workspaces.reserved_for?(ctx.raunak, "ravix-hq/ravix")
    end
  end

  describe "the workspace door" do
    setup do
      [owner, admin, stranger] = for _ <- 1..3, do: insert_user()
      Backfill.run()
      workspace = personal(owner)
      member!(workspace, admin, :admin)
      %{owner: owner, admin: admin, stranger: stranger, workspace: workspace}
    end

    test "admits members with their role and answers not found for everybody else", ctx do
      assert {:ok, %{role: :owner, workspace: %Workspace{}}} =
               Workspaces.get(ctx.owner, ctx.workspace.id)

      assert {:ok, %{role: :admin}} = Access.workspace_access(ctx.admin, ctx.workspace.id)
      assert {:error, :not_found} = Access.workspace_access(ctx.stranger, ctx.workspace.id)
      assert {:error, :not_found} = Access.workspace_access(ctx.owner, personal(ctx.stranger).id)
      assert {:error, :not_found} = Access.workspace_access(ctx.owner, Ecto.UUID.generate())
      assert {:error, :not_found} = Access.workspace_access(ctx.owner, nil)
      assert Store.membership(nil, ctx.owner.id) == nil

      assert [%{role: :owner}] = Workspaces.list(ctx.owner)
      # One backfill batch shares a `created_at`, so compare without order.
      assert Map.new(Workspaces.list(ctx.admin), &{&1.workspace.id, &1.role}) == %{
               personal(ctx.admin).id => :owner,
               ctx.workspace.id => :admin
             }

      Repo.update_all(where(Membership, user_id: ^ctx.admin.id, workspace_id: ^ctx.workspace.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      assert {:error, :not_found} = Access.workspace_access(ctx.admin, ctx.workspace.id)
      assert [%{role: :owner}] = Workspaces.list(ctx.admin)

      Repo.update_all(where(Workspace, id: ^ctx.workspace.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert {:error, :not_found} = Access.workspace_access(ctx.owner, ctx.workspace.id)
      assert {:error, :not_found} = Workspaces.personal_workspace(ctx.owner)
    end

    test "a user the backfill has not reached has no workspace, which is not an error" do
      user = %User{id: Ecto.UUID.generate()}
      assert {:error, :not_found} = Workspaces.personal_workspace(user)
      assert Workspaces.list(user) == []
    end

    test "workspace membership grants nothing through the existing doors", ctx do
      project = insert_project(user: ctx.owner)
      Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: ctx.workspace.id])
      track = insert_track(project: project, created_by: ctx.owner.id)

      # The admin is a workspace member, but not a project or track member.
      assert {:error, :not_found} = Access.project_access(ctx.admin, project.id)
      assert {:error, :not_found} = Access.project_of(ctx.admin, project.id)
      assert {:error, :not_found} = Access.track_access(ctx.admin, track.id)
      assert {:error, :not_found} = Access.thread_access(ctx.admin, track.id)
      assert Access.open_tracks(ctx.admin, [project.id]) == []
      assert Access.access_of(ctx.admin.id, Repo.get!(Project, project.id)) == nil

      # The legacy owner is let in exactly as before.
      assert {:ok, %{role: :owner}} = Access.project_access(ctx.owner, project.id)
      assert {:ok, %{role: :owner}} = Access.track_access(ctx.owner, track.id)
    end
  end

  describe "installation connections" do
    test "one connection per installation per workspace; several workspaces may connect it" do
      user = insert_user()
      [one, two] = [workspace!(name: "one", kind: :team), workspace!(name: "two", kind: :team)]

      connect = fn workspace ->
        %Installation{}
        |> Installation.changeset(%{
          workspace_id: workspace.id,
          installation_id: 42,
          connected_by_user_id: user.id
        })
        |> Repo.insert()
      end

      assert {:ok, %Installation{connected_at: %DateTime{}}} = connect.(one)
      assert {:ok, _} = connect.(two)
      assert {:error, changeset} = connect.(one)
      assert %{workspace_id: ["has already been taken"]} = errors_on(changeset)

      assert %{installation_id: ["must be greater than 0"]} =
               errors_on(
                 Installation.changeset(%Installation{}, %{
                   workspace_id: one.id,
                   installation_id: 0
                 })
               )
    end
  end

  describe "schema constraints" do
    test "a personal workspace names its person, a team none, and one each" do
      user = insert_user()

      assert {:error, changeset} =
               Repo.insert(Workspace.changeset(%Workspace{}, %{name: "p", kind: :personal}))

      assert %{kind: ["is invalid"]} = errors_on(changeset)
      workspace!(name: "p", kind: :personal, personal_user_id: user.id)

      assert {:error, changeset} =
               Repo.insert(
                 Workspace.changeset(%Workspace{}, %{
                   name: "q",
                   kind: :personal,
                   personal_user_id: user.id
                 })
               )

      assert %{personal_user_id: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Repo.insert(
                 Workspace.changeset(%Workspace{}, %{
                   name: "t",
                   kind: :team,
                   personal_user_id: user.id
                 })
               )

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "memberships refuse an unknown role and a missing workspace" do
      user = insert_user()

      assert %{role: ["is invalid"]} =
               errors_on(
                 Membership.changeset(%Membership{}, %{
                   workspace_id: "w",
                   user_id: user.id,
                   role: "guest"
                 })
               )

      assert {:error, changeset} =
               Repo.insert(
                 Membership.changeset(%Membership{}, %{
                   workspace_id: "missing",
                   user_id: user.id,
                   role: :member
                 })
               )

      assert %{workspace_id: ["does not exist"]} = errors_on(changeset)
    end
  end
end
