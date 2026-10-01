defmodule RavixWeb.WorkspaceScopeLiveTest do
  @moduledoc """
  The current workspace scopes the page (ADR 0009 follow-up): the switcher
  sets it, it persists per person, the rail, quick-jump, badges, the Inbox
  and New track show only it, a `/p/:id` link follows its project into its
  workspace, its menu opens settings, legacy shares sit in "Shared with
  you", and with the switch off nothing changes.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on, application-wide.
  """
  use RavixWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Ravix.{Accounts, Projects, QueryCount, Repo, Tracks, Workspaces}
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Tracks.{Header, Track, Transcript}
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

  # A project changing workspace, as the owner's Move to workspace does:
  # the row, then the notices open pages hear.
  defp move(project, workspace_id) do
    from = Repo.get!(Ravix.Projects.Project, project.id)
    from |> Ecto.Changeset.change(workspace_id: workspace_id) |> Repo.update!()
    Workspaces.members_changed(from.workspace_id)
    Workspaces.members_changed(workspace_id)
  end

  defp search(view, query) do
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: query) |> render_change()
  end

  test "everybody starts in their personal workspace, and switching scopes rail, search, badges, Inbox and New track",
       ctx do
    view = open(ctx.conn, "/inbox")

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
    render_click(view, "dismiss", %{})

    view |> element("#workspace-select-#{ctx.team.id}") |> render_click()
    render_async(view)

    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id
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

    # It persists: a fresh page opens where this person left off.
    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}")
    refute has_element?(view, "#project-row-#{ctx.mine.id}")
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
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert {:error, :not_found} = Accounts.put_current_workspace(ctx.me, theirs.id)
  end

  test "a removed member falls back to their personal workspace, on the open page and the next",
       ctx do
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

    # Personal, even though a team workspace is still there (RAV-33).
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    refute has_element?(view, "#workspace-select-#{boss_team.id}")
    refute has_element?(view, "#project-row-#{boss_project.id}")
    assert has_element?(view, "#project-row-#{ctx.mine.id}")

    view = open(ctx.conn, "/home")
    assert has_element?(view, "#workspace-switcher-trigger", "me")
  end

  test "removed from a workspace while one of its tracks is open, the page lets go of it", ctx do
    boss = insert_user(login: "boss")
    {:ok, boss_team} = Workspaces.create(boss, "Boss Team")
    :ok = Store.add_member(boss_team.id, ctx.me.id, :member, boss.id)
    boss_project = insert_project(user: boss, name: "BossApp", repo_full_name: "boss/app")
    Store.move_project(boss_project.id, boss_team.id)
    track = insert_track(project: boss_project, title: "boss-track", created_by: boss.id)

    view = open(ctx.conn, "/p/#{boss_project.id}/t/#{track.id}")
    assert has_element?(view, "#workspace-switcher-trigger", "Boss Team")
    assert render(view) =~ "boss-track"

    :ok = Workspaces.remove_member(boss, boss_team.id, ctx.me.id)

    # The open track page re-reads its access on the removal notice and
    # sends the whole page home: a redirect, not a crash.
    assert_redirect(view, "/")

    view = open(ctx.conn, "/")
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    refute has_element?(view, "#workspace-select-#{boss_team.id}")
    refute render(view) =~ "boss-track"
    refute render(view) =~ "BossApp"

    # The link itself is now not found, not a crash either.
    render_patch(view, "/p/#{boss_project.id}/t/#{track.id}")
    assert_patch(view, "/home")
    assert render(view) =~ "Project not found."
  end

  test "somebody else's project moved elsewhere while open leaves the page, not the choice",
       ctx do
    boss = insert_user(login: "boss")
    {:ok, here} = Workspaces.create(boss, "Here")
    {:ok, there} = Workspaces.create(boss, "There")
    :ok = Store.add_member(here.id, ctx.me.id, :member, boss.id)
    :ok = Store.add_member(there.id, ctx.me.id, :member, boss.id)
    moving = insert_project(user: boss, name: "Moving", repo_full_name: "boss/moving")
    Store.move_project(moving.id, here.id)
    {:ok, _} = Accounts.put_current_workspace(ctx.me, here.id)

    view = open(ctx.conn, "/p/#{moving.id}")
    assert has_element?(view, "#workspace-switcher-trigger", "Here")

    # Still reachable in There, but a background read does not follow it.
    move(moving, there.id)
    render(view)
    render_async(view)

    assert_patch(view, "/")
    assert has_element?(view, "#workspace-switcher-trigger", "Here")
    refute has_element?(view, "#project-row-#{moving.id}")
    assert Repo.reload!(ctx.me).current_workspace_id == here.id
  end

  test "the owner's move from another tab leaves this page, and its choice stands", ctx do
    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.team.id)
    view = open(ctx.conn, "/p/#{ctx.team_project.id}")

    move(ctx.team_project, ctx.personal.id)
    render(view)
    render_async(view)

    assert_patch(view, "/")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    refute has_element?(view, "#project-row-#{ctx.team_project.id}")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id

    # It is in the target's rail once the owner switches there.
    view |> element("#workspace-select-#{ctx.personal.id}") |> render_click()
    assert has_element?(view, "#project-row-#{ctx.team_project.id}")
  end

  test "the page moving a project from its settings goes with it", ctx do
    stub(Projects, :settings, fn _, _ ->
      {:ok,
       %{
         name: ctx.team_project.name,
         runtime: "claude",
         model: "model",
         instructions: "",
         setup_script: "",
         packages: %{},
         env_keys: [],
         vault_keys: [],
         catalog: Catalog.empty()
       }}
    end)

    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.team.id)
    view = open(ctx.conn, "/p/#{ctx.team_project.id}")
    render_patch(view, "/p/#{ctx.team_project.id}/settings/workspace")
    render_async(view)

    move(ctx.team_project, ctx.personal.id)
    render(view)
    render_async(view)

    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert has_element?(view, "#project-row-#{ctx.team_project.id}.current")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.personal.id
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
    assert has_element?(view, "#workspace-switcher-trigger", "me")
    assert Repo.reload!(ctx.me).current_workspace_id == nil
  end

  # The rail read, held until the test lets it answer, as the setup's stub
  # would have answered it.
  defp hold_rail do
    test_pid = self()

    expect(Tracks, :list_many, fn user, ids, _opts ->
      send(test_pid, {:rail_started, self()})

      receive do
        :release_rail ->
          Ravix.Accounts.Access.open_tracks(user, ids)
          |> Enum.group_by(fn {_row, project} -> project.id end, fn {row, _} ->
            %{Tracks.present(row) | status: :ready, unread: true}
          end)
      end
    end)
  end

  defp switcher_name(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#workspace-switcher-trigger .truncate")
    |> LazyHTML.text()
    |> String.trim()
  end

  test "the first paint names the session's current workspace and shows skeletons, never an empty Inbox",
       ctx do
    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.team.id)
    hold_rail()

    dead = get(ctx.conn, "/inbox")
    html = html_response(dead, 200)
    refute_received {:rail_started, _}

    # The disconnected render resolves the workspace the connected one will.
    assert switcher_name(html) == "Team"
    refute html =~ ~s(id="workspace-switcher-skeleton")
    assert html =~ ~r/id="workspace-select-#{ctx.team.id}"[^>]*aria-current="true"/
    assert html =~ "rail-row-skeleton"
    assert html =~ "inbox-item-skeleton"
    refute html =~ "all caught up"
    refute html =~ "Loading projects…</p>"

    {:ok, view, _} = live(dead)
    assert_receive {:rail_started, worker}
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert has_element?(view, "#rail-loading .rail-row-skeleton")
    assert has_element?(view, "#inbox-loading .inbox-item-skeleton")
    refute has_element?(view, ".inbox-empty")

    send(worker, :release_rail)
    render_async(view)
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id
    refute has_element?(view, "#inbox-loading")
    refute has_element?(view, "#rail-loading")
    assert has_element?(view, ".inbox-item", "team-track")
  end

  test "the first paint resolves a workspace the viewer cannot reach to their default", ctx do
    stranger = insert_user(login: "stranger")
    {:ok, theirs} = Workspaces.create(stranger, "Theirs")

    ctx.me
    |> Ecto.Changeset.change(current_workspace_id: theirs.id)
    |> Repo.update!()

    html = ctx.conn |> get("/inbox") |> html_response(200)
    assert switcher_name(html) == "me"
    refute html =~ "Theirs"
    refute html =~ "/w/#{theirs.id}"
  end

  test "a first page naming a project in another workspace shows a switcher skeleton until it follows",
       ctx do
    {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
    hold_rail()

    html = ctx.conn |> get("/p/#{ctx.team_project.id}") |> html_response(200)
    assert html =~ ~s(id="workspace-switcher-skeleton")
    assert switcher_name(html) == ""

    {:ok, view, _} = live(ctx.conn, "/p/#{ctx.team_project.id}")
    assert_receive {:rail_started, worker}
    assert has_element?(view, "#workspace-switcher-skeleton")
    refute has_element?(view, "#workspace-switcher-trigger")

    send(worker, :release_rail)
    render_async(view)
    refute has_element?(view, "#workspace-switcher-skeleton")
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
  end

  test "the gear and the workspace menu open the current workspace's settings", ctx do
    view = open(ctx.conn, "/home")
    members = "/w/#{ctx.personal.id}/settings/members"

    # The header gear is named, and titled, "Workspace settings" (RAV-72). It
    # asks the server rather than following a path drawn here (RAV-104).
    assert has_element?(
             view,
             ~s(button#workspace-settings-gear[phx-click="workspace-settings"][aria-label="Workspace settings"][data-tip="Workspace settings"][data-leaves-page])
           )

    assert has_element?(view, "#workspace-menu #workspace-settings", "Workspace settings")

    # The switcher's entries are choices, not links to that page.
    refute has_element?(view, ~s(#workspace-menu [role=group] a))

    view |> element("#workspace-settings-gear") |> render_click()
    assert_patch(view, members)
    assert has_element?(view, "#settings-title", "Members")
    assert page_title(view) == "Members · me · Ravix"
  end

  # RAV-104. In a browser the pick is a round trip, and a settings click made
  # during it used to follow the path drawn for the workspace being left;
  # a settings URL makes its workspace current, so the pick was undone. The
  # click is an event now, answered after the pick it followed.
  test "workspace settings opened right after a switch are the new workspace's", ctx do
    view = open(ctx.conn, "/home")
    refute has_element?(view, ~s(#workspace-settings-gear[href]))
    refute has_element?(view, ~s(#workspace-menu #workspace-settings[href]))

    view |> element("#workspace-select-#{ctx.team.id}") |> render_click()
    view |> element("#workspace-menu #workspace-settings") |> render_click()
    assert_patch(view, "/w/#{ctx.team.id}/settings/members")
    assert Repo.reload!(ctx.me).current_workspace_id == ctx.team.id
    assert has_element?(view, "#workspace-switcher-trigger", "Team")
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
          fn -> view |> element("#workspace-select-#{ctx.team.id}") |> render_click() end,
          from: view.pid
        )

      {:ok, _} = Accounts.put_current_workspace(Repo.reload!(ctx.me), ctx.personal.id)
      assert has_element?(view, "#project-row-#{ctx.team_project.id}")
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

  # RAV-128: a project's name is read against the container it lives in,
  # and only where the viewer is not already inside it. The sidebar, the
  # crumbs, the title and quick-jump are scoped to the current workspace;
  # Schedules spans every workspace the viewer reaches.
  describe "project names" do
    # The track page, with the track's own reads stood in for, as
    # `RavixWeb.TrackLiveTest` does: the crumb is the parent's project view.
    defp open_track(conn, project, track) do
      stub(Tracks, :get, fn _, id, _opts ->
        row = Repo.get!(Track, id)

        {:ok,
         %{
           track: Tracks.present(row, role: :member),
           header: %Header{
             copy_of: nil,
             branched_from: nil,
             created: %{dir: "t", files: nil},
             has_setup_script: false
           },
           threads: [],
           starters: [],
           models: []
         }}
      end)

      stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
      stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
      stub(Tracks, :beat, fn _, _, _ -> :ok end)
      stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

      {:ok, parent, _} = live(conn, "/p/#{project.id}/t/#{track.id}")
      render_async(parent, 5_000)
      child = find_live_child(parent, "track-host")
      render_async(child, 5_000)
      render_async(child, 5_000)
      {parent, child}
    end

    test "a team workspace's creator and its other members read the same bare name inside it",
         ctx do
      mate = insert_user(login: "mate")
      :ok = Store.add_member(ctx.team.id, mate.id, :member, ctx.me.id)
      project = ctx.team_project
      track = ctx.tracks.team

      for user <- [ctx.me, mate] do
        {:ok, _} = Accounts.put_current_workspace(user, ctx.team.id)
        conn = log_in_user(build_conn(), user)

        view = open(conn, "/p/#{project.id}")
        assert has_element?(view, "#workspace-switcher-trigger", "Team")

        assert view |> element("#project-link-#{project.id} .project-label") |> render() =~
                 "TeamApp"

        refute has_element?(view, "#project-link-#{project.id} .project-label .dim")
        assert has_element?(view, ~s|[aria-label="Tracks in TeamApp"]|)
        assert has_element?(view, "#workspace-stage .crumbs .project-label", "TeamApp")
        refute has_element?(view, "#workspace-stage .crumbs .project-label .dim")
        assert page_title(view) == "TeamApp · Ravix"

        {parent, child} = open_track(conn, project, track)
        assert page_title(parent) == "team-track · TeamApp · Ravix"
        assert has_element?(child, "#track-header .project-crumb .project-label", "TeamApp")
        refute has_element?(child, "#track-header .project-crumb .project-label .dim")
      end
    end

    test "across workspaces, the workspace names it: Schedules, for everybody", ctx do
      mate = insert_user(login: "mate")
      :ok = Store.add_member(ctx.team.id, mate.id, :member, ctx.me.id)

      view = open(ctx.conn, "/schedules")
      html = view |> element("#schedule-form") |> render()
      assert html =~ "Team / TeamApp"
      # The viewer's own legacy project, and one somebody shared, as before.
      assert html =~ ">Mine<"
      assert html =~ "friend / Friendly"

      view = open(log_in_user(build_conn(), mate), "/schedules")
      assert view |> element("#schedule-form") |> render() =~ "Team / TeamApp"
    end

    test "a legacy project somebody shared still says whose it is, and the viewer's own does not",
         ctx do
      {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
      view = open(ctx.conn, "/p/#{ctx.shared.id}")

      assert has_element?(view, "#project-link-#{ctx.shared.id} .project-label .dim", "friend /")

      assert view |> element("#project-link-#{ctx.shared.id} .project-label") |> render() =~
               "Friendly"

      assert has_element?(view, ~s|[aria-label="Tracks in friend / Friendly"]|)
      assert has_element?(view, "#workspace-stage .crumbs .project-label .dim", "friend /")
      assert page_title(view) == "friend / Friendly · Ravix"

      assert view |> element("#project-link-#{ctx.mine.id} .project-label") |> render() =~ "Mine"
      refute has_element?(view, "#project-link-#{ctx.mine.id} .project-label .dim")

      {parent, child} = open_track(ctx.conn, ctx.shared, ctx.tracks.shared)
      assert page_title(parent) == "shared-track · friend / Friendly · Ravix"
      assert has_element?(child, "#track-header .project-crumb .project-label .dim", "friend /")
    end

    test "quick-jump finds a workspace project by its workspace's name and a legacy one by its owner's",
         ctx do
      {:ok, _} = Workspaces.rename(ctx.me, ctx.team.id, "Orbit")
      {:ok, _} = Accounts.put_current_workspace(ctx.me, ctx.team.id)
      view = open(ctx.conn, "/inbox")

      search(view, "orbit")
      assert has_element?(view, "#search-project-link-#{ctx.team_project.id}")
      assert has_element?(view, "#search-track-link-#{ctx.tracks.team.id}")
      # Drawn as the sidebar draws it: inside the workspace, bare.
      assert has_element?(
               view,
               "#search-project-link-#{ctx.team_project.id} .search-label",
               "TeamApp"
             )

      refute view
             |> element("#search-project-link-#{ctx.team_project.id} .search-label")
             |> render() =~ "Orbit /"

      render_click(view, "dismiss-switcher", %{})

      {:ok, _} = Accounts.put_current_workspace(Repo.reload!(ctx.me), ctx.personal.id)
      view = open(ctx.conn, "/inbox")
      search(view, "friend")

      assert has_element?(
               view,
               "#search-project-link-#{ctx.shared.id} .search-label",
               "friend / Friendly"
             )

      assert has_element?(view, "#search-track-link-#{ctx.tracks.shared.id}")
      refute has_element?(view, "#search-project-link-#{ctx.mine.id}")
    end
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

      # The workspace does not count yet, so its project is labelled the
      # legacy way (RAV-128): the owner's, bare; a share, the owner's login.
      refute has_element?(view, "#project-link-#{ctx.team_project.id} .project-label .dim")
      assert has_element?(view, "#project-link-#{ctx.shared.id} .project-label .dim", "friend /")

      assert {:error, :not_found} = Workspaces.current(ctx.me)
      assert {:error, :not_found} = Accounts.put_current_workspace(ctx.me, ctx.personal.id)
      render_click(view, "workspace-select", %{"workspace" => ctx.personal.id})
      assert Repo.reload!(ctx.me).current_workspace_id == nil
    end
  end
end
