defmodule RavixWeb.WorkspaceSectionsLiveTest do
  @moduledoc """
  Sidebar sections belong to the current workspace (RAV-127): the page
  lists and creates them for the workspace that is current, switching
  swaps them, a section of another workspace takes no project, a revoked
  session or membership changes nothing, and with the switch off the
  sections are as they always were.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ravix.{Accounts, Repo, Workspaces}
  alias Ravix.Projects.{Section, Sections}
  alias Ravix.Workspaces.Store
  alias RavixWeb.Live.Guard

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    me = insert_user(login: "me")
    {:ok, personal} = Store.ensure_personal_workspace(me)
    {:ok, team} = Workspaces.create(me, "Team")
    mine = insert_project(user: me, name: "Mine", repo_full_name: "me/app")
    team_project = insert_project(user: me, name: "TeamApp", repo_full_name: "team/api")
    1 = Store.move_project(team_project.id, team.id)

    %{
      me: me,
      personal: personal,
      team: team,
      mine: mine,
      team_project: team_project,
      conn: log_in_user(build_conn(), me)
    }
  end

  defp open(conn, path) do
    {:ok, view, _} = live(conn, path)
    render_async(view)
    view
  end

  defp create_section(view, name) do
    view |> element("#manage-sections") |> render_click()
    view |> form("#new-section-form", section: %{name: name}) |> render_submit()
    render_click(view, "dismiss-switcher")
    Repo.get_by!(Section, name: name)
  end

  test "each workspace has its own sections, created there and swapped on switching", ctx do
    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "me")

    home = create_section(view, "Home")
    assert home.workspace_id == ctx.personal.id
    assert has_element?(view, "#section-#{home.id} .section-toggle", "Home")
    assert has_element?(view, "#section-empty-#{home.id}", "No projects")

    view
    |> element("#project-sections")
    |> render_hook("move-project", %{project: ctx.mine.id, section: home.id})

    assert has_element?(view, "#section-#{home.id} a[href='/p/#{ctx.mine.id}']")

    # The team: Home is not there, filled or not; a section made here is,
    # even while empty, so there is somewhere to drag a project to.
    view |> element("#workspace-select-#{ctx.team.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    refute has_element?(view, "#section-#{home.id}")
    assert has_element?(view, "#section-other a[href='/p/#{ctx.team_project.id}']")

    work = create_section(view, "Work")
    assert work.workspace_id == ctx.team.id
    assert has_element?(view, "#section-empty-#{work.id}", "No projects")
    refute has_element?(view, "#section-#{home.id}")

    # Manage sections offers only this workspace's sections and projects.
    view |> element("#manage-sections") |> render_click()
    assert has_element?(view, "#rename-section-#{work.id}")
    refute has_element?(view, "#rename-section-#{home.id}")
    assert has_element?(view, "#move-project-#{ctx.team_project.id} option[value='#{work.id}']")
    refute has_element?(view, "#move-project-#{ctx.team_project.id} option[value='#{home.id}']")
    refute has_element?(view, "#move-project-#{ctx.mine.id}")
    view |> form("#move-project-#{ctx.team_project.id}", section: work.id) |> render_change()
    render_click(view, "dismiss-switcher")
    assert has_element?(view, "#section-#{work.id} a[href='/p/#{ctx.team_project.id}']")

    # A section of the other workspace, named by id, takes nothing.
    assert render_click(view, "move-project", %{project: ctx.team_project.id, section: home.id}) =~
             "That section is in another workspace."

    assert render_click(view, "move-project", %{project: ctx.mine.id, section: work.id}) =~
             "That project is in another workspace."

    assert {:ok, {[^work], placements}} = Sections.list(ctx.me, ctx.team.id)
    assert placements == %{ctx.team_project.id => work.id}

    # Back home: Home and its project, no Work.
    view |> element("#workspace-select-#{ctx.personal.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#section-#{home.id} a[href='/p/#{ctx.mine.id}']")
    refute has_element?(view, "#section-#{work.id}")

    # And the next page opens where the switcher left it, sections included.
    view = open(ctx.conn, "/home")
    assert has_element?(view, "#section-#{home.id} a[href='/p/#{ctx.mine.id}']")
    refute has_element?(view, "#section-#{work.id}")
  end

  test "a removed member's sections in that workspace go with it, on the open page", ctx do
    boss = insert_user(login: "boss")
    {:ok, boss_team} = Workspaces.create(boss, "Boss Team")
    :ok = Store.add_member(boss_team.id, ctx.me.id, :member, boss.id)
    {:ok, _} = Accounts.put_current_workspace(ctx.me, boss_team.id)
    {:ok, visiting} = Sections.create(ctx.me, boss_team.id, %{name: "Visiting"})
    {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})

    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "Boss Team")
    assert has_element?(view, "#section-#{visiting.id}")
    refute has_element?(view, "#section-#{home.id}")

    :ok = Workspaces.remove_member(boss, boss_team.id, ctx.me.id)
    render_async(view)

    assert has_element?(view, "#workspace-switcher-trigger", "me")
    refute has_element?(view, "#section-#{visiting.id}")
    assert has_element?(view, "#section-#{home.id}")

    # Creating now lands in the personal workspace, not the one left.
    later = create_section(view, "Later")
    assert later.workspace_id == ctx.personal.id
    # The section stays where it was, out of reach rather than deleted.
    assert {:error, :not_found} = Sections.list(ctx.me, boss_team.id)
    assert Repo.get!(Section, visiting.id).workspace_id == boss_team.id
  end

  test "an expired session cannot create or place in a workspace's sections", ctx do
    {token, session} = insert_session(ctx.me)
    {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})
    conn = Plug.Test.init_test_session(build_conn(), session_token: token)
    {:ok, view, _} = live(conn, "/home")
    render_async(view, 5_000)
    assert has_element?(view, "#section-#{home.id}")
    Repo.delete!(session)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.session_guard, fn guard ->
        %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
      end)
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "create-section", %{section: %{name: "Denied"}})

    assert {:ok, {[^home], %{}}} = Sections.list(ctx.me, ctx.personal.id)
    assert {:ok, {[], %{}}} = Sections.list(ctx.me, ctx.team.id)
  end

  describe "with RAVIX_WORKSPACE_ACCESS off" do
    setup do
      Application.put_env(:ravix, :workspace_access, false)
      :ok
    end

    test "every section is shown, any takes any project, and new ones are personal", ctx do
      {:ok, home} = Sections.create(ctx.me, ctx.personal.id, %{name: "Home"})
      {:ok, work} = Sections.create(ctx.me, ctx.team.id, %{name: "Work"})
      view = open(ctx.conn, "/home")

      refute has_element?(view, "#workspace-switcher")
      assert has_element?(view, "#section-#{home.id}")
      assert has_element?(view, "#section-#{work.id}")
      assert has_element?(view, "#section-other a[href='/p/#{ctx.mine.id}']")
      assert has_element?(view, "#section-other a[href='/p/#{ctx.team_project.id}']")

      view
      |> element("#project-sections")
      |> render_hook("move-project", %{project: ctx.team_project.id, section: home.id})

      assert has_element?(view, "#section-#{home.id} a[href='/p/#{ctx.team_project.id}']")

      later = create_section(view, "Later")
      assert later.workspace_id == ctx.personal.id
      assert has_element?(view, "#section-#{later.id}")
      assert {:ok, {sections, _}} = Sections.list(ctx.me, nil)
      assert Enum.map(sections, & &1.name) == ["Home", "Later", "Work"]
    end
  end
end
