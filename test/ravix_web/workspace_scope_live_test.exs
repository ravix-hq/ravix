defmodule RavixWeb.WorkspaceScopeLiveTest do
  @moduledoc """
  The current workspace scopes the page (ADR 0009 follow-up): the switcher
  sets it, it persists per person, the rail, quick-jump, badges, the Inbox
  and New track show only it, a `/p/:id` link follows its project into its
  workspace, the gear opens settings, legacy shares sit in "Shared with
  you", and with the switch off nothing changes.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.{Accounts, QueryCount, Repo, Tracks, Workspaces}
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    # Every visible track has an unread reply, so each is one Inbox item and
    # one badge; the real bulk Access query still decides what is visible.
    stub(Tracks, :list_many, fn user, ids, _opts ->
      Ravix.Accounts.Access.open_tracks(user, ids)
      |> Enum.group_by(fn {_row, project} -> project.id end, fn {row, _} ->
        %{Tracks.present(row) | status: :ready, unread: true}
      end)
    end)

    me = insert_user(login: "me", credential_set_id: "set-me")
    {:ok, personal} = Store.ensure_personal_workspace(me)
    {:ok, team} = Workspaces.create(me, "Team")

    mine = insert_project(user: me, name: "Mine", repo_full_name: "me/app")
    team_project = insert_project(user: me, name: "TeamApp", repo_full_name: "team/api")
    Store.move_project(team_project.id, team.id)

    friend = insert_user(login: "friend")
    shared = insert_project(user: friend, name: "Friendly", repo_full_name: "friend/lib")
    insert_project_member(shared, me)

    tracks = %{
      mine: insert_track(project: mine, title: "mine-track", created_by: me.id),
      team: insert_track(project: team_project, title: "team-track", created_by: me.id),
      shared: insert_track(project: shared, title: "shared-track")
    }

    %{
      me: me,
      personal: personal,
      team: team,
      mine: mine,
      team_project: team_project,
      shared: shared,
      friend: friend,
      tracks: tracks,
      conn: log_in_user(build_conn(), me)
    }
  end

  defp open(conn, path) do
    {:ok, view, _} = live(conn, path)
    render_async(view)
    view
  end

  defp repo_options(view) do
    view
    |> element("#repo-picker-list")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[phx-click=picker-pick]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp search(view, query) do
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: query) |> render_change()
  end

  test "a team member starts in their team, and switching scopes rail, search, badges, Inbox and New track",
       ctx do
    view = open(ctx.conn, "/inbox")

    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}")
    refute has_element?(view, "#project-row-#{ctx.mine.id}")
    refute has_element?(view, "#project-row-#{ctx.shared.id}")
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "1")
    assert has_element?(view, ".inbox-item", "team-track")
    refute has_element?(view, ".inbox-item", "mine-track")
    assert has_element?(view, "#inbox-elsewhere", "2 in other workspaces")

    search(view, "track")
    assert has_element?(view, "#search-track-link-#{ctx.tracks.team.id}")
    refute has_element?(view, "#search-track-link-#{ctx.tracks.mine.id}")
    refute has_element?(view, "#search-track-link-#{ctx.tracks.shared.id}")
    render_click(view, "dismiss-switcher", %{})

    view |> element("#top-new-track") |> render_click()
    render_async(view)
    assert repo_options(view) == ["team/api"]
    render_click(view, "dismiss", %{})

    view |> element("#workspace-select-#{ctx.personal.id}") |> render_click()
    render_async(view)

    assert Repo.reload!(ctx.me).current_workspace_id == ctx.personal.id
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert has_element?(view, "#project-row-#{ctx.mine.id}")
    assert has_element?(view, "#project-row-#{ctx.shared.id}")
    refute has_element?(view, "#project-row-#{ctx.team_project.id}")
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "2")
    assert has_element?(view, ".inbox-item", "mine-track")
    refute has_element?(view, ".inbox-item", "team-track")
    assert has_element?(view, "#inbox-elsewhere", "1 in other workspaces")

    search(view, "track")
    assert has_element?(view, "#search-track-link-#{ctx.tracks.mine.id}")
    assert has_element?(view, "#search-track-link-#{ctx.tracks.shared.id}")
    refute has_element?(view, "#search-track-link-#{ctx.tracks.team.id}")
    render_click(view, "dismiss-switcher", %{})

    view |> element("#top-new-track") |> render_click()
    render_async(view)
    refute "team/api" in repo_options(view)
    assert "me/app" in repo_options(view)

    # It persists: a fresh page opens where this person left off.
    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert has_element?(view, "#project-row-#{ctx.mine.id}")
    refute has_element?(view, "#project-row-#{ctx.team_project.id}")
  end

  test "switching away from an open project leaves it for the new workspace's home", ctx do
    view = open(ctx.conn, "/p/#{ctx.team_project.id}")
    view |> element("#workspace-select-#{ctx.personal.id}") |> render_click()
    assert_patch(view, "/home")
    refute has_element?(view, "#project-row-#{ctx.team_project.id}")
  end

  test "a workspace the viewer is not in cannot be made current", ctx do
    stranger = insert_user(login: "stranger")
    {:ok, theirs} = Workspaces.create(stranger, "Theirs")
    view = open(ctx.conn, "/home")

    render_click(view, "workspace-select", %{"workspace" => theirs.id})
    assert Repo.reload!(ctx.me).current_workspace_id == nil
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert {:error, :not_found} = Accounts.put_current_workspace(ctx.me, theirs.id)
  end

  test "a removed member falls back to the default, on the open page and the next", ctx do
    boss = insert_user(login: "boss")
    {:ok, boss_team} = Workspaces.create(boss, "Boss Team")
    :ok = Store.add_member(boss_team.id, ctx.me.id, :member, boss.id)
    boss_project = insert_project(user: boss, name: "BossApp", repo_full_name: "boss/app")
    Store.move_project(boss_project.id, boss_team.id)
    {:ok, _} = Accounts.put_current_workspace(ctx.me, boss_team.id)

    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "Boss Team")
    assert has_element?(view, "#project-row-#{boss_project.id}")

    :ok = Workspaces.remove_member(boss, boss_team.id, ctx.me.id)
    render_async(view)

    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    refute has_element?(view, "#workspace-select-#{boss_team.id}")
    refute has_element?(view, "#project-row-#{boss_project.id}")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}")

    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
  end

  test "a /p/:id link into another of the viewer's workspaces switches to it", ctx do
    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)

    # On a page that is already open, as a patch.
    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    render_patch(view, "/p/#{ctx.team_project.id}/t/#{ctx.tracks.team.id}")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}.current")
    refute has_element?(view, "#project-row-#{ctx.mine.id}")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id

    # And as the first page, before the rail has arrived.
    {:ok, _} = Accounts.put_current_workspace(Repo.reload!(ctx.me), ctx.personal.id)
    view = open(ctx.conn, "/p/#{ctx.team_project.id}")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}.current")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id

    # A legacy share lives in the personal workspace, so a link to it goes there.
    render_patch(view, "/p/#{ctx.shared.id}")
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert has_element?(view, "#section-shared #project-row-#{ctx.shared.id}")
  end

  test "a /p/:id link into a workspace the viewer is not in is not found", ctx do
    stranger = insert_user(login: "stranger")
    {:ok, theirs} = Workspaces.create(stranger, "Theirs")
    hidden = insert_project(user: stranger, name: "Hidden", repo_full_name: "stranger/app")
    Store.move_project(hidden.id, theirs.id)

    view = open(ctx.conn, "/home")
    render_patch(view, "/p/#{hidden.id}")
    assert_patch(view, "/home")
    assert render(view) =~ "Project not found."
    refute render(view) =~ "Hidden"
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert Repo.reload!(ctx.me).current_workspace_id == nil
  end

  test "the gear opens the current workspace's settings and members", ctx do
    view = open(ctx.conn, "/home")

    assert has_element?(
             view,
             ~s(#workspace-settings[href="/w/#{ctx.team.id}"][aria-label="Settings and members of Team"])
           )

    # The switcher's entries are choices, not links to that page.
    refute has_element?(view, ~s(#workspace-menu a[href^="/w/"]))

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#workspace-settings") |> render_click()

    assert to == "/w/#{ctx.team.id}"
  end

  test "Shared with you lists legacy projects shared into the personal workspace", ctx do
    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
    scratch = insert_project(user: ctx.me, name: "Sandbox", repo_full_name: nil)
    view = open(ctx.conn, "/home")

    assert has_element?(view, "#section-shared", "Shared with you")
    assert has_element?(view, "#section-shared #project-row-#{ctx.shared.id}")
    refute has_element?(view, "#section-shared[data-section-drop]")
    assert has_element?(view, "#section-other #project-row-#{ctx.mine.id}")
    assert has_element?(view, "#section-scratch #project-row-#{scratch.id}")
    refute has_element?(view, "#section-shared #project-row-#{ctx.mine.id}")

    # Once its owner moves it into a workspace this person is in, it lives there.
    Store.move_project(ctx.shared.id, ctx.team.id)
    view = open(ctx.conn, "/home")
    refute has_element?(view, "#section-shared")
    refute has_element?(view, "#project-row-#{ctx.shared.id}")
  end

  test "the rail stays one track query however many workspaces it spans", ctx do
    switch = fn ->
      view = open(ctx.conn, "/home")

      {_html, sources} =
        QueryCount.count(
          fn -> view |> element("#workspace-select-#{ctx.personal.id}") |> render_click() end,
          from: view.pid
        )

      {:ok, _} = Accounts.put_current_workspace(Repo.reload!(ctx.me), ctx.team.id)
      assert has_element?(view, "#project-row-#{ctx.mine.id}")
      sources
    end

    before = switch.()

    for n <- 1..3 do
      {:ok, extra} = Workspaces.create(ctx.me, "Extra #{n}")
      project = insert_project(user: ctx.me, name: "Extra#{n}", repo_full_name: "extra/#{n}")
      Store.move_project(project.id, extra.id)
      insert_track(project: project, title: "extra-#{n}")
    end

    # Switching re-reads membership and visibility, with the tracks of every
    # workspace discovered in the same single query: three more workspaces,
    # projects and tracks cost nothing more.
    assert switch.() == before
  end

  describe "with RAVIX_WORKSPACE_ACCESS off" do
    setup do
      Application.put_env(:ravix, :workspace_access, false)
      :ok
    end

    test "nothing is scoped: every project, no switcher, no Shared with you", ctx do
      view = open(ctx.conn, "/inbox")

      refute has_element?(view, "#workspace-switcher")
      refute has_element?(view, "#section-shared")
      refute has_element?(view, "#inbox-elsewhere")
      assert has_element?(view, "#project-row-#{ctx.mine.id}")
      assert has_element?(view, "#project-row-#{ctx.shared.id}")
      assert has_element?(view, "#project-row-#{ctx.team_project.id}")
      assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "3")

      assert {:error, :not_found} = Workspaces.current(ctx.me)
      assert {:error, :not_found} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
      render_click(view, "workspace-select", %{"workspace" => ctx.personal.id})
      assert Repo.reload!(ctx.me).current_workspace_id == nil
    end
  end
end
