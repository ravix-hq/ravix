defmodule Ravix.Workspaces.RaviSeedTest do
  @moduledoc """
  The Ravi workspace seed (ADR 0009 phase 4a): a dry run writes nothing,
  apply writes the owners' decisions once, a re-run changes nothing, and a
  missing owner refuses the whole step. The legacy duplicate's open track
  keeps working for its members.
  """
  # Not async: the Mix task tests below swap the global `Mix.shell/1`, and a
  # concurrent test whose own Mix task prints through it
  # (`Ravix.Workspaces.PersonalAssignmentTest`) then captures nothing.
  use Ravix.DataCase, async: false

  # The explicit canonical override logs a warning by design.
  @moduletag :capture_log

  import Ravix.Factory

  alias Mix.Tasks.Ravix.SeedRaviWorkspace
  alias Ravix.Accounts.Access
  alias Ravix.Projects.Project
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, RaviSeed, RepositoryReservation, Store, Workspace}

  @canonical "d2fe4837-0e69-4a51-8201-e41d000fcb45"
  @duplicate "a7782c96-2407-4f0d-a62f-4c2215039d6f"

  setup do
    jh = insert_user(login: "jhgaylor")
    raunak = insert_user(login: "RaunakSingwi")
    early = ~U[2026-09-01 00:00:00.000000Z]
    late = ~U[2026-09-20 00:00:00.000000Z]

    # Raunak's is the older of the two: the owners chose the later one anyway.
    duplicate =
      insert_project(
        id: @duplicate,
        user: raunak,
        name: "ravix",
        repo_full_name: "ravix-hq/ravix",
        created_at: early
      )

    canonical =
      insert_project(
        id: @canonical,
        user: jh,
        name: "ravix2",
        repo_full_name: "Ravix-HQ/Ravix",
        created_at: late
      )

    other = insert_project(user: raunak, repo_full_name: "ravix-hq/fountain")
    personal = insert_project(user: jh, repo_full_name: "jhgaylor/dotfiles")
    stranger = insert_project(repo_full_name: "ravix-hq/elsewhere")
    archived = insert_project(user: jh, repo_full_name: "ravix-hq/old", archived_at: late)

    %{
      jh: jh,
      raunak: raunak,
      duplicate: duplicate,
      canonical: canonical,
      other: other,
      personal: personal,
      stranger: stranger,
      archived: archived
    }
  end

  defp reload(%Project{id: id}), do: Repo.get!(Project, id)
  defp ravi, do: Repo.all(from w in Workspace, where: w.name == "Ravi")

  test "a dry run reports the plan and writes nothing", ctx do
    assert {:ok, summary} = RaviSeed.run()
    refute summary.applied
    assert summary.workspace == %{id: nil, name: "Ravi", create: true}
    assert summary.owners == ["jhgaylor", "RaunakSingwi"]

    by_id = Map.new(summary.projects, &{&1.id, &1})
    assert Map.keys(by_id) |> Enum.sort() == Enum.sort([@duplicate, @canonical, ctx.other.id])
    assert %{action: :move, rename: "ravix-hq/ravix", duplicate_of: nil} = by_id[@canonical]
    assert %{action: :move, rename: nil, duplicate_of: @canonical} = by_id[@duplicate]
    assert %{action: :move} = by_id[ctx.other.id]

    assert ravi() == []
    assert reload(ctx.canonical).name == "ravix2"
    assert is_nil(reload(ctx.duplicate).legacy_duplicate_at)
    assert Enum.all?([ctx.canonical, ctx.duplicate, ctx.other], &is_nil(reload(&1).workspace_id))

    lines = RaviSeed.format(summary)
    assert hd(lines) =~ "Dry run"
    assert Enum.any?(lines, &(&1 =~ "legacy duplicate of #{@canonical}"))
  end

  test "apply writes the owners' decisions, and a re-run changes nothing", ctx do
    assert {:ok, %{applied: true, workspace: %{id: id}}} = RaviSeed.run(apply: true)
    assert [%Workspace{id: ^id, kind: :team}] = ravi()

    owners =
      Repo.all(from m in Membership, where: m.workspace_id == ^id, select: {m.user_id, m.role})

    assert Enum.sort(owners) == Enum.sort([{ctx.jh.id, :owner}, {ctx.raunak.id, :owner}])

    canonical = reload(ctx.canonical)
    assert %{name: "ravix-hq/ravix", workspace_id: ^id, user_id: jh_id} = canonical
    assert jh_id == ctx.jh.id

    duplicate = reload(ctx.duplicate)
    assert %{workspace_id: ^id, legacy_duplicate_of: @canonical, name: "ravix"} = duplicate
    assert Workspaces.legacy_duplicate?(duplicate)
    assert duplicate.user_id == ctx.raunak.id

    assert %Project{workspace_id: ^id} = reload(ctx.other)

    for untouched <- [ctx.personal, ctx.stranger, ctx.archived],
        do: assert(is_nil(reload(untouched).workspace_id))

    assert [%RepositoryReservation{reserved_project_id: @duplicate}] =
             Repo.all(RepositoryReservation)

    # Again: the same workspace, nothing new.
    assert {:ok, again} = RaviSeed.run(apply: true)
    assert again.workspace.id == id
    assert [_] = ravi()
    assert Enum.all?(again.projects, &(&1.action == :in_place and is_nil(&1.rename)))
    assert Repo.aggregate(RepositoryReservation, :count) == 1
    assert Repo.aggregate(from(m in Membership, where: m.workspace_id == ^id), :count) == 2
    assert reload(ctx.canonical).name == "ravix-hq/ravix"
  end

  test "an owner removed from Ravi is neither re-added nor reported as an owner", ctx do
    assert {:ok, %{workspace: %{id: id}}} = RaviSeed.run(apply: true)
    {:ok, _} = Store.revoke_membership(id, ctx.raunak.id, ctx.jh.id)

    assert {:error, {:revoked_owner, "RaunakSingwi"} = reason} = RaviSeed.run(apply: true)
    assert RaviSeed.describe_error(reason) =~ "@RaunakSingwi was removed from Ravi"
    assert is_nil(Store.membership(id, ctx.raunak.id))
    assert [_] = ravi()
  end

  test "Ravi is still found when the first owner is the one removed", ctx do
    assert {:ok, %{workspace: %{id: id}}} = RaviSeed.run(apply: true)
    {:ok, _} = Store.revoke_membership(id, ctx.jh.id, ctx.raunak.id)

    assert {:error, {:revoked_owner, "jhgaylor"}} = RaviSeed.run()
    assert [_] = ravi()
  end

  test "an owner demoted in Ravi refuses the step", ctx do
    assert {:ok, %{workspace: %{id: id}}} = RaviSeed.run(apply: true)
    {:ok, _} = Store.set_role(id, ctx.raunak.id, :admin, ctx.jh.id)

    assert {:error, {:not_owner, "RaunakSingwi"} = reason} = RaviSeed.run()
    assert RaviSeed.describe_error(reason) =~ "not as an owner"
  end

  test "a missing owner refuses the whole step", ctx do
    Repo.delete!(ctx.raunak |> Ecto.Changeset.change())
    assert {:error, {:missing_owner, "raunaksingwi"}} = RaviSeed.run(apply: true)
    assert RaviSeed.describe_error({:missing_owner, "raunaksingwi"}) =~ "@raunaksingwi"
    assert ravi() == []
    assert is_nil(reload(ctx.canonical).workspace_id)
  end

  test "a missing or mismatched canonical pair refuses the step", ctx do
    Repo.update_all(from(p in Project, where: p.id == ^@duplicate),
      set: [repo_full_name: "ravix-hq/other", normalized_repo_full_name: "ravix-hq/other"]
    )

    assert {:error, {:not_canonical_repo, @duplicate}} = RaviSeed.run()

    Repo.delete_all(from p in Project, where: p.id == ^ctx.duplicate.id)
    assert {:error, {:missing_project, @duplicate}} = RaviSeed.run()
    assert RaviSeed.describe_error({:missing_project, @duplicate}) =~ @duplicate
  end

  test "first-created-wins refuses this pair; the explicit override marks it" do
    assert {:error, :not_later} = Store.mark_legacy_duplicate(@duplicate, @canonical)

    assert {:ok, %Project{legacy_duplicate_of: @canonical}} =
             Store.mark_legacy_duplicate(@duplicate, @canonical, canonical: :explicit)
  end

  test "two undecided projects of one repository are left where they are", ctx do
    twin = insert_project(user: ctx.jh, repo_full_name: "ravix-hq/fountain")
    assert {:ok, summary} = RaviSeed.run(apply: true)

    assert Enum.filter(summary.projects, &(&1.action == :conflict))
           |> Enum.map(& &1.id)
           |> Enum.sort() ==
             Enum.sort([ctx.other.id, twin.id])

    assert is_nil(reload(ctx.other).workspace_id)
    assert is_nil(reload(twin).workspace_id)
    assert RaviSeed.format(summary) |> Enum.any?(&(&1 =~ "another undecided project"))
  end

  test "a project already in another workspace is left there", ctx do
    {:ok, elsewhere} = Store.create_team_workspace(ctx.jh.id, "Elsewhere")
    Store.move_project(ctx.other.id, elsewhere.id)

    assert {:ok, summary} = RaviSeed.run(apply: true)
    assert %{action: :elsewhere} = Enum.find(summary.projects, &(&1.id == ctx.other.id))
    assert reload(ctx.other).workspace_id == elsewhere.id
  end

  test "the legacy duplicate's open track keeps working for its members", ctx do
    track = insert_track(project: ctx.duplicate, created_by_login: "RaunakSingwi")
    guest = insert_user()
    insert_track_member(track, guest)
    project_member = insert_user()
    insert_project_member(ctx.duplicate, project_member)

    assert {:ok, _} = RaviSeed.run(apply: true)

    assert {:ok, %{role: :owner}} = Access.project_access(ctx.raunak, @duplicate)
    assert {:ok, %{role: :member}} = Access.project_access(project_member, @duplicate)
    assert {:ok, %{role: :member}} = Access.track_access(guest, track.id)
    assert {:ok, %{role: :owner}} = Access.track_access(ctx.raunak, track.id)
    # And jhgaylor, an owner of Ravi, is not handed Raunak's project by it.
    assert {:error, :not_found} = Access.project_access(ctx.jh, @duplicate)
  end

  describe "the Mix task" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "dry run by default, --apply writes, and a refusal raises" do
      SeedRaviWorkspace.run([])
      assert_received {:mix_shell, :info, ["Dry run" <> _]}
      assert ravi() == []

      SeedRaviWorkspace.run(["--apply"])
      assert_received {:mix_shell, :info, ["Applied" <> _]}
      assert [_] = ravi()

      assert_raise Mix.Error, ~r/Usage/, fn ->
        SeedRaviWorkspace.run(["--nope"])
      end
    end
  end
end
