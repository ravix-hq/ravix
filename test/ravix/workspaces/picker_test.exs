defmodule Ravix.Workspaces.PickerTest do
  @moduledoc """
  RAV-10's list: the current workspace's repositories only, most recently
  used first then alphabetical, legacy duplicates out, scratch apart, and
  what to preselect.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use Ravix.DataCase, async: false

  import Ravix.Factory

  alias Ravix.Projects
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Picker, Store}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    user = insert_user(login: "me")
    {:ok, _personal} = Store.ensure_personal_workspace(user)
    {:ok, team} = Workspaces.create(user, "Team")
    %{user: user, team: team}
  end

  defp views(user), do: Projects.list(user, include_machine: false)
  defp repos(picker), do: Enum.map(Picker.matches(picker), & &1.repo)

  defp in_team(project, team) do
    Store.move_project(project.id, team.id)
    project
  end

  defp used(project, user, at),
    do: insert_track(project: project, created_by: user.id, created_at: at)

  test "the personal workspace lists the person's legacy repositories, not a team's", ctx do
    insert_project(user: ctx.user, repo_full_name: "me/alpha")
    insert_project(user: ctx.user, repo_full_name: "me/beta")
    ctx.user |> then(&insert_project(user: &1, repo_full_name: "team/api")) |> in_team(ctx.team)

    picker = Picker.build(ctx.user, views(ctx.user), nil)
    assert picker.workspace.kind == :personal
    assert repos(picker) == ["me/alpha", "me/beta"]
  end

  test "opened from a team project, only that workspace's repositories", ctx do
    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    insert_project(user: ctx.user, repo_full_name: "team/web") |> in_team(ctx.team)
    insert_project(user: ctx.user, repo_full_name: "me/alpha")

    anchor = Enum.find(views(ctx.user), &(&1.id == api.id))
    picker = Picker.build(ctx.user, views(ctx.user), anchor)
    assert picker.workspace.id == ctx.team.id
    assert repos(picker) == ["team/api", "team/web"]
    assert Picker.preselect(picker, anchor).id == api.id
  end

  test "recently used first, then alphabetical; the query matches owner/repo", ctx do
    zeta = insert_project(user: ctx.user, repo_full_name: "me/zeta")
    insert_project(user: ctx.user, repo_full_name: "me/alpha")
    mid = insert_project(user: ctx.user, repo_full_name: "Other/Mid")
    insert_project(user: ctx.user, repo_full_name: "me/beta")
    used(zeta, ctx.user, ~U[2026-09-01 00:00:00.000000Z])
    used(mid, ctx.user, ~U[2026-09-20 00:00:00.000000Z])
    # Somebody else's use of a project does not make it recent for me.
    used(
      insert_project(user: ctx.user, repo_full_name: "me/yard"),
      insert_user(),
      DateTime.utc_now()
    )

    picker = Picker.build(ctx.user, views(ctx.user), nil)
    assert repos(picker) == ["Other/Mid", "me/zeta", "me/alpha", "me/beta", "me/yard"]

    # No anchor: the most recently used is preselected.
    assert Picker.preselect(picker, nil).id == mid.id

    assert repos(%{picker | query: "  ME/"}) == ["me/zeta", "me/alpha", "me/beta", "me/yard"]
    assert repos(%{picker | query: "other/m"}) == ["Other/Mid"]
    assert repos(%{picker | query: "nothing"}) == []
  end

  test "legacy duplicates are left out, and one repository is listed once", ctx do
    first =
      insert_project(
        user: ctx.user,
        repo_full_name: "me/app",
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    marked = insert_project(user: ctx.user, repo_full_name: "me/app")
    {:ok, _} = Store.mark_legacy_duplicate(marked.id, first.id)
    twin = insert_project(user: ctx.user, repo_full_name: "ME/App")
    used(twin, ctx.user, DateTime.utc_now())

    picker = Picker.build(ctx.user, views(ctx.user), nil)
    assert [%{project: %{id: id}}] = Picker.matches(picker)
    # The one used most recently stands for the repository.
    assert id == twin.id
    refute Enum.any?(picker.entries, &(&1.project.id == marked.id))
  end

  test "scratch projects are apart from the repositories, and preselected only last", ctx do
    scratch = insert_project(user: ctx.user, repo_full_name: nil, name: "Sandbox")

    picker = Picker.build(ctx.user, views(ctx.user), nil)
    assert picker.entries == []
    assert [%{id: id}] = picker.scratch
    assert id == scratch.id
    assert Picker.preselect(picker, nil).id == scratch.id

    repo = insert_project(user: ctx.user, repo_full_name: "me/app")
    picker = Picker.build(ctx.user, views(ctx.user), nil)
    assert Picker.preselect(picker, nil).id == repo.id
    anchor = Enum.find(views(ctx.user), &(&1.id == scratch.id))
    assert Picker.preselect(picker, anchor).id == scratch.id
  end

  test "a project in a workspace the person is not a member of falls back to personal", ctx do
    stranger = insert_user()
    {:ok, theirs} = Workspaces.create(stranger, "Theirs")
    shared = insert_project(user: stranger, repo_full_name: "them/x") |> in_team(theirs)
    insert_project_member(shared, ctx.user)
    insert_project(user: ctx.user, repo_full_name: "me/alpha")

    anchor = Enum.find(views(ctx.user), &(&1.id == shared.id))
    picker = Picker.build(ctx.user, views(ctx.user), anchor)
    assert picker.workspace.kind == :personal
    assert repos(picker) == ["me/alpha"]
  end

  test "owners and admins may add a repository; members may not", ctx do
    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    anchor = Enum.find(views(ctx.user), &(&1.id == api.id))
    assert Picker.build(ctx.user, views(ctx.user), anchor).can_add

    member = insert_user()
    :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.user.id)
    member_views = views(member)
    member_anchor = Enum.find(member_views, &(&1.id == api.id))
    picker = Picker.build(member, member_views, member_anchor)
    assert picker.workspace.id == ctx.team.id
    refute picker.can_add
    assert Picker.load_addable(picker, member).addable == []
  end

  test "the repositories to add are the catalog's without a project, narrowed by the query",
       ctx do
    {:ok, installation} = Store.bind_installation(ctx.team.id, 7, "team", ctx.user.id)

    Store.record_refresh(installation, :active, nil, [
      %{
        github_repo_id: 1,
        full_name: "team/api",
        private: false,
        default_branch: "main",
        pushed_at: nil
      },
      %{
        github_repo_id: 2,
        full_name: "team/web",
        private: true,
        default_branch: "main",
        pushed_at: nil
      }
    ])

    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    anchor = Enum.find(views(ctx.user), &(&1.id == api.id))

    picker = Picker.build(ctx.user, views(ctx.user), anchor) |> Picker.load_addable(ctx.user)
    assert picker.addable == [%{repo: "team/web", private: true}]

    assert Picker.addable_matches(%{picker | query: "WEB"}) == [
             %{repo: "team/web", private: true}
           ]

    assert Picker.addable_matches(%{picker | query: "api"}) == []
  end
end
