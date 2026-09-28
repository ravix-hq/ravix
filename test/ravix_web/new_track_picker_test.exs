defmodule RavixWeb.NewTrackPickerTest do
  @moduledoc """
  RAV-10 in the New track dialog, and the scratch rail group (ADR 0009
  phase 4c): the list's contents per workspace, preselection, type-ahead,
  Add a repository returning selected, scratch apart, legacy duplicates
  absent, and the switch off keeping today's dialog and rail.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest
  import Ravix.WorkspaceGitHubFixture

  alias Ravix.Projects.Sections
  alias Ravix.{Tracks, Workspaces}
  alias Ravix.Workspaces.{Repositories, Store}

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    stub(Tracks, :list_many, fn user, ids, opts ->
      Map.new(ids, fn id ->
        {:ok, rows} = Tracks.list(user, id, opts)
        {id, rows}
      end)
    end)

    user = insert_user(login: "me", credential_set_id: "set-me")
    {:ok, _personal} = Store.ensure_personal_workspace(user)
    {:ok, team} = Workspaces.create(user, "Team")
    %{user: user, team: team, conn: log_in_user(build_conn(), user)}
  end

  defp in_team(project, team) do
    Store.move_project(project.id, team.id)
    project
  end

  defp options(view) do
    view
    |> element("#repo-picker-list")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[phx-click=picker-pick]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp open_top(conn, path) do
    {:ok, view, _} = live(conn, path)
    render_async(view)
    view |> element("#top-new-track") |> render_click()
    render_async(view)
    view
  end

  test "the top button lists the personal workspace's repositories, most recent preselected",
       ctx do
    alpha = insert_project(user: ctx.user, repo_full_name: "me/alpha")
    beta = insert_project(user: ctx.user, repo_full_name: "me/beta")
    insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    insert_track(project: beta, created_by: ctx.user.id)

    view = open_top(ctx.conn, "/home")
    assert has_element?(view, "#new-track-dialog #repo-picker")
    refute has_element?(view, "#new-track-project")
    assert options(view) == ["me/beta", "me/alpha"]
    assert has_element?(view, "#repo-option-#{beta.id}[aria-pressed=true]")
    assert has_element?(view, "#repo-picker-selected", "me/beta")
    refute has_element?(view, "#repo-option-#{alpha.id}[aria-pressed=true]")
  end

  test "opened from a project row, that project's workspace and that project", ctx do
    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    web = insert_project(user: ctx.user, repo_full_name: "team/web") |> in_team(ctx.team)
    insert_project(user: ctx.user, repo_full_name: "me/alpha")
    insert_track(project: api, created_by: ctx.user.id)

    {:ok, view, _} = live(ctx.conn, "/p/#{web.id}?new=track")
    render_async(view)
    assert options(view) == ["team/api", "team/web"]
    assert has_element?(view, "#repo-option-#{web.id}[aria-pressed=true]")
    assert has_element?(view, "#repo-picker label", "in Team")
  end

  test "type-ahead narrows by owner/repo, and picking changes the destination", ctx do
    insert_project(user: ctx.user, repo_full_name: "me/alpha")
    beta = insert_project(user: ctx.user, repo_full_name: "me/beta")
    insert_project(user: ctx.user, repo_full_name: "other/gamma")

    view = open_top(ctx.conn, "/home")
    view |> form("#repo-picker-form", q: "ME/B") |> render_change()
    assert options(view) == ["me/beta"]

    view |> form("#repo-picker-form", q: "nothing") |> render_change()
    assert options(view) == []
    assert has_element?(view, "#repo-picker-list", "No repository here matches.")

    view |> form("#repo-picker-form", q: "beta") |> render_submit()
    render_async(view)
    assert has_element?(view, "#repo-option-#{beta.id}[aria-pressed=true]")
    refute_patched(view)
  end

  test "legacy duplicates are absent, and scratch is its own option", ctx do
    first =
      insert_project(
        user: ctx.user,
        repo_full_name: "me/app",
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    marked = insert_project(user: ctx.user, repo_full_name: "me/app")
    {:ok, _} = Store.mark_legacy_duplicate(marked.id, first.id)
    scratch = insert_project(user: ctx.user, repo_full_name: nil, name: "Sandbox")

    view = open_top(ctx.conn, "/home")
    assert options(view) == ["me/app"]
    refute has_element?(view, "#repo-option-#{marked.id}")
    refute has_element?(view, "#repo-picker-list #repo-option-scratch")
    assert has_element?(view, "#repo-option-scratch", "No repository (scratch)")

    view |> element("#repo-option-scratch") |> render_click()
    render_async(view)
    assert has_element?(view, "#repo-option-scratch[aria-pressed=true]")
    assert has_element?(view, "#repo-picker-selected", "Sandbox")

    # A forged pick of a legacy duplicate is refused, through the list's own
    # event and through the old project select's.
    render_hook(view, "picker-pick", %{"project" => marked.id})
    assert has_element?(view, "#repo-option-scratch[aria-pressed=true]")
    render_hook(view, "new-track-project", %{"project" => marked.id})
    assert has_element?(view, "#repo-option-scratch[aria-pressed=true]")
    refute has_element?(view, "#repo-option-#{marked.id}")
    _ = scratch
  end

  test "a forged old-select pick of another workspace's project is refused", ctx do
    insert_project(user: ctx.user, repo_full_name: "me/app")
    team_project = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)

    view = open_top(ctx.conn, "/home")
    assert options(view) == ["me/app"]
    render_hook(view, "new-track-project", %{"project" => team_project.id})
    assert has_element?(view, "#repo-picker-selected", "me/app")
    refute has_element?(view, "#repo-option-#{team_project.id}")
  end

  test "no scratch project yet: scratch opens New project in scratch mode", ctx do
    insert_project(user: ctx.user, repo_full_name: "me/app")
    view = open_top(ctx.conn, "/home")
    view |> element("#repo-option-scratch") |> render_click()
    assert has_element?(view, "#new-project-dialog")
  end

  test "Add a repository adds through the workspace and returns with it selected", ctx do
    app = github(%{77 => %{account: "team", repos: [repo(1, "team/api"), repo(2, "team/web")]}})
    stub(Ravix.Config, :github, fn -> app end)
    {:ok, _} = Store.bind_installation(ctx.team.id, 77, "team", ctx.user.id)
    {:ok, _} = Repositories.refresh(ctx.user, ctx.team.id)
    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)

    {:ok, view, _} = live(ctx.conn, "/p/#{api.id}?new=track")
    render_async(view)
    assert has_element?(view, "#repo-picker-list li:last-child #repo-option-add")

    view |> element("#repo-option-add") |> render_click()
    assert has_element?(view, "#repo-picker-add [data-repo='team/web']")
    refute has_element?(view, "#repo-picker-add [data-repo='team/api']")

    provisioning(1)
    # The dialog's runtime choices for the new project are read from
    # Fountain too; that is not this test's subject.
    stub(Tracks, :open_options, fn _user, _id -> {:error, :not_found} end)
    view |> element("#repo-picker-add [data-repo='team/web']") |> render_click()
    render_async(view)

    web = Ravix.Repo.get_by!(Ravix.Projects.Project, repo_full_name: "team/web")
    assert has_element?(view, "#repo-option-#{web.id}[aria-pressed=true]")
    assert has_element?(view, "#repo-picker-selected", "team/web")
    assert options(view) |> Enum.sort() == ["team/api", "team/web"]
  end

  test "a member gets no Add a repository", ctx do
    api = insert_project(user: ctx.user, repo_full_name: "team/api") |> in_team(ctx.team)
    member = insert_user(login: "mem")
    :ok = Store.add_member(ctx.team.id, member.id, :member, ctx.user.id)

    {:ok, view, _} = live(log_in_user(build_conn(), member), "/p/#{api.id}?new=track")
    render_async(view)
    assert options(view) == ["team/api"]
    refute has_element?(view, "#repo-option-add")
    render_hook(view, "picker-add-open", %{})
    refute has_element?(view, "#repo-picker-add")
  end

  test "scratch projects have their own rail group", ctx do
    insert_project(user: ctx.user, repo_full_name: "me/app", name: "App")
    scratch = insert_project(user: ctx.user, repo_full_name: nil, name: "Sandbox")

    {:ok, view, _} = live(ctx.conn, "/home")
    render_async(view)
    assert has_element?(view, "#section-scratch", "Scratch")
    assert has_element?(view, "#section-scratch #project-row-#{scratch.id}")
    refute has_element?(view, "#section-other #project-row-#{scratch.id}")
  end

  test "the scratch group sits beside real sections, which keep their projects", ctx do
    app = insert_project(user: ctx.user, repo_full_name: "me/app", name: "App")
    scratch = insert_project(user: ctx.user, repo_full_name: nil, name: "Sandbox")
    {:ok, section} = Sections.create(ctx.user, %{"name" => "Work"})
    {:ok, _} = Sections.move(ctx.user, app.id, section.id)

    {:ok, view, _} = live(ctx.conn, "/home")
    render_async(view)
    assert has_element?(view, "#section-#{section.id} #project-row-#{app.id}")
    assert has_element?(view, "#section-scratch #project-row-#{scratch.id}[draggable=false]")
    refute has_element?(view, "#section-scratch[data-section-drop]")
  end

  describe "with RAVIX_WORKSPACE_ACCESS off" do
    setup do
      Application.put_env(:ravix, :workspace_access, false)
      :ok
    end

    test "New track is today's project select, and scratch stays among the projects", ctx do
      app = insert_project(user: ctx.user, repo_full_name: "me/app", name: "App")
      scratch = insert_project(user: ctx.user, repo_full_name: nil, name: "Sandbox")

      {:ok, view, _} = live(ctx.conn, "/p/#{app.id}")
      render_async(view)
      refute has_element?(view, "#section-scratch")
      assert has_element?(view, "#section-other #project-row-#{scratch.id}")

      view |> element("#top-new-track") |> render_click()
      render_async(view)
      refute has_element?(view, "#repo-picker")
      assert has_element?(view, "#new-track-project option[value='#{app.id}'][selected]")
      assert has_element?(view, "#new-track-project option[value='#{scratch.id}']")
    end
  end
end
