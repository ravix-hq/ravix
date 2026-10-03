defmodule RavixWeb.ProjectTracksTest do
  # The repository-style pages: Home lists projects, narrowed by the
  # sidebar's sections, and a project's page shows its tracks as a branch
  # graph or a list, with closed tracks on request.
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Fountain.Client
  alias Ravix.{Projects, Tracks}
  alias Ravix.Projects.Sections
  alias RavixWeb.Live.{HomeProjects, ProjectTracks}

  setup :verify_on_exit!

  setup do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    stub(Tracks, :list_many, fn user, ids, opts ->
      Map.new(ids, fn id ->
        {:ok, rows} = Tracks.list(user, id, opts)
        {id, rows}
      end)
    end)

    stub(Projects, :agent_health, fn _, _ -> {:error, :not_asked} end)
    :ok
  end

  defp live_at(conn, user, path) do
    {:ok, view, _} = live(log_in_user(conn, user), path)
    render_async(view)
    view
  end

  @now ~U[2026-10-03 12:00:00Z]

  defp row(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        created_at: @now,
        closed_at: nil,
        status: :ready,
        setup_state: "ready",
        threads: []
      },
      Map.new(attrs)
    )
  end

  describe "graph/4" do
    test "places open tracks newest first, then closed ones, on one time axis" do
      old = row(created_at: DateTime.add(@now, -4, :day))
      new = row(created_at: DateTime.add(@now, -1, :day), status: :running)

      closed =
        row(created_at: DateTime.add(@now, -3, :day), closed_at: DateTime.add(@now, -2, :day))

      graph = ProjectTracks.graph([old, new], [closed], @now)

      assert Enum.map(graph.rows, & &1.track.id) == [new.id, old.id, closed.id]
      # The window opens at the oldest track, so it starts at the left edge.
      assert [%{x0: "0.00%", y: 140, state: "idle", clipped: false} | _] =
               Enum.drop(graph.rows, 1)

      assert %{state: "working", label: "Working", x1: "86.00%"} = hd(graph.rows)

      # A closed track ends where it closed, a quarter of the way back from
      # now over a four-day window, and is labelled as closed.
      assert %{state: "closed", label: "Closed", closed: true, x1: x1} = List.last(graph.rows)
      assert x1 == "43.00%"
      assert graph.height == 56 * 4
      assert length(graph.ticks) == 4
    end

    test "holds the window to two weeks and marks an older track as clipped" do
      ancient = row(created_at: DateTime.add(@now, -60, :day))
      graph = ProjectTracks.graph([ancient], [], @now)

      assert [%{clipped: true, x0: "0.00%"}] = graph.rows
      # Fourteen days of ticks, labelled every second day to stay readable.
      assert length(graph.ticks) <= 8
    end

    test "puts a dot on a track for each thread, where the thread started" do
      opened = DateTime.add(@now, -2, :day)

      track =
        row(
          created_at: opened,
          threads: [%{created_at: opened}, %{created_at: DateTime.add(@now, -1, :day)}]
        )

      assert [%{threads: ["0.00%", "43.00%"]}] = ProjectTracks.graph([track], [], @now).rows
    end

    test "draws nothing but the default branch with no tracks" do
      assert %{rows: [], height: 56} = ProjectTracks.graph([], [], @now)
    end
  end

  test "names a track's origin in a few words" do
    assert ProjectTracks.origin(%{origin: %{kind: :pr, number: 212}}) == "PR #212"
    assert ProjectTracks.origin(%{origin: %{kind: :issue, number: 48}}) == "Issue #48"
    assert ProjectTracks.origin(%{origin: %{kind: :plan}}) == "Plan item"
    assert ProjectTracks.origin(%{origin: %{kind: :branch}}) == "Branch"
    assert ProjectTracks.origin(%{origin: %{kind: :blank}}) == nil
  end

  test "Home's summary counts open tracks by state" do
    rows = [row(status: :running), row([]), row([]), row(closed_at: @now)]
    assert HomeProjects.summary(rows) == "2 Idle · 1 Working"
    assert HomeProjects.summary([]) == "No open tracks"
    assert HomeProjects.summary({:error, :unavailable}) == "No open tracks"
  end

  describe "a project's page" do
    test "shows its tracks as a graph, then as a list", %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user, repo_full_name: "ravix-hq/ravix")

      track =
        insert_track(
          project: project,
          title: "ravix/fix-login",
          origin_kind: "issue",
          origin_number: 41
        )

      view = live_at(conn, user, "/p/#{project.id}")

      assert has_element?(view, "#crumb-tracks[aria-current=page]", "Tracks")
      assert has_element?(view, "#project-tracks-graph[aria-pressed=true]")
      assert has_element?(view, "#tracks-graph-row-#{track.id} .tracks-title", "fix-login")
      refute has_element?(view, "#tracks-list")

      view |> element("#project-tracks-list") |> render_click()

      assert has_element?(view, "#project-tracks-list[aria-pressed=true]")
      refute has_element?(view, "#tracks-graph")

      assert has_element?(
               view,
               "#tracks-row-#{track.id} a[href='/p/#{project.id}/t/#{track.id}']",
               "fix-login"
             )

      assert has_element?(view, "#tracks-row-#{track.id} .chip", "Issue #41")
      assert has_element?(view, "#tracks-row-#{track.id} .tracks-row-meta", track.branch)
    end

    test "lists closed tracks on request, without a link to open them", %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user)
      open = insert_track(project: project, title: "ravix/still-open")

      closed =
        insert_track(
          project: project,
          title: "ravix/all-done",
          closed_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      view = live_at(conn, user, "/p/#{project.id}")
      refute has_element?(view, "#tracks-graph-row-#{closed.id}")

      view |> element("#project-tracks-closed") |> render_click()
      render_async(view)

      assert has_element?(view, "#project-tracks-closed[aria-pressed=true]", "Hide closed")
      assert has_element?(view, "#tracks-graph-row-#{open.id} a.tracks-title")
      assert has_element?(view, "#tracks-graph-row-#{closed.id}.closed span.tracks-title")
      refute has_element?(view, "#tracks-graph-row-#{closed.id} a")
    end

    test "reopens a closed track from the list, when the project has a repository", %{
      conn: conn
    } do
      user = insert_user()
      project = insert_project(user: user, repo_full_name: "acme/widgets")
      insert_track(project: project, title: "ravix/still-open")

      closed =
        insert_track(
          project: project,
          title: "ravix/all-done",
          closed_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      view = live_at(conn, user, "/p/#{project.id}")
      view |> element("#project-tracks-list") |> render_click()
      view |> element("#project-tracks-closed") |> render_click()
      render_async(view)

      assert has_element?(view, "#tracks-row-#{closed.id}.closed")

      assert has_element?(
               view,
               "#reopen-track-#{closed.id}[phx-value-track='#{closed.id}']",
               "Reopen"
             )
    end

    test "says when its tracks could not be read, instead of offering a first track", %{
      conn: conn
    } do
      user = insert_user()
      project = insert_project(user: user)
      insert_track(project: project)

      stub(Tracks, :list_many, fn _user, ids, _opts ->
        Map.new(ids, &{&1, {:error, :unavailable}})
      end)

      view = live_at(conn, user, "/p/#{project.id}")

      assert has_element?(view, "#project-tracks-error", "couldn't be loaded")

      assert has_element?(
               view,
               "#project-tracks-error button[phx-value-id='#{project.id}']",
               "Retry"
             )

      refute has_element?(view, "#project-start")
    end

    test "a failed machine's dot says why in its tooltip", %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user)
      track = insert_track(project: project, sandbox_state: :failed)

      view = live_at(conn, user, "/p/#{project.id}")
      view |> element("#project-tracks-list") |> render_click()

      assert has_element?(
               view,
               "#tracks-row-#{track.id} .dot.error[aria-label='Error'][data-tip=\"Error: This track's machine failed.\"]"
             )
    end

    test "a project with no tracks still starts one from the page", %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user)
      view = live_at(conn, user, "/p/#{project.id}")

      assert has_element?(view, "#project-start #project-quick-start")
      refute has_element?(view, "#project-tracks")
    end
  end

  describe "the top bar" do
    test "is the workspace, search and places on Home, and a breadcrumb in a project",
         %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user, name: "atlas")
      view = live_at(conn, user, "/home")

      refute has_element?(view, "#yard")
      refute has_element?(view, "#sidebar")

      assert has_element?(
               view,
               "#topbar .topbar-item[href='/home'][aria-current=page]",
               "Projects"
             )

      assert has_element?(view, "#topbar .topbar-item[href='/inbox']", "Inbox")
      assert has_element?(view, "#topbar #quick-jump-trigger", "Search projects, tracks, threads")
      assert has_element?(view, "#topbar #top-new-track", "New track")

      render_patch(view, "/p/#{project.id}")
      assert has_element?(view, "#topbar .topbar-crumbs a[href='/home']")
      assert has_element?(view, "#topbar .topbar-crumbs a[aria-current=page]", "atlas")
      refute has_element?(view, "#topbar .topbar-nav")
      assert has_element?(view, "#topbar #quick-jump-trigger[aria-label=Search]")
    end
  end

  test "inside a project the bar keeps the Inbox count and never guesses the workspace",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    insert_track(project: project, setup_state: "failed")

    html = conn |> log_in_user(user) |> get("/p/#{project.id}") |> html_response(200)
    assert html =~ ~s(id="crumb-workspace-loading")

    view = live_at(conn, user, "/p/#{project.id}")
    refute has_element?(view, "#crumb-workspace-loading")
    assert has_element?(view, "#topbar .topbar-crumbs a[href='/home']", "@#{user.login}")

    assert has_element?(
             view,
             "#topbar-inbox[href='/inbox'][aria-label='Inbox, 1 need you'] .badge",
             "1"
           )
  end

  describe "previews and people" do
    setup do
      stub(Ravix.Config, :sprites, fn ->
        %Ravix.Config.Sprites{token: "test", base_url: "http://sprites.test"}
      end)

      stub(Ravix.Config, :previews, fn ->
        %Ravix.Config.Previews{domain: "preview.localhost", protocol: :http, public_port: ":5183"}
      end)

      stub(Ravix.Config, :fountain, fn ->
        %Ravix.Config.Fountain{url: "http://fountain.test", key: "test"}
      end)

      :ok
    end

    test "Home counts a project's running previews; its page lists them and its people",
         %{conn: conn} do
      owner = insert_user(login: "owner-here")
      member = insert_user(login: "member-here")
      project = insert_project(user: owner)
      insert_project_member(project, member)

      track =
        insert_track(project: project, title: "ravix/shop-front", opened_at: DateTime.utc_now())

      insert_preview(track: track, state: :ready, desired: :running)

      home = live_at(conn, owner, "/home")
      assert has_element?(home, "#home-project-#{project.id} .home-project-meta", "1 preview")

      view = live_at(conn, owner, "/p/#{project.id}")
      render_async(view, 1_000)

      assert has_element?(
               view,
               "#project-previews #project-preview-#{track.id}[href='/preview/#{track.id}']",
               "shop-front"
             )

      assert has_element?(
               view,
               "#project-people [aria-label='@member-here'], #project-people img[alt='@member-here']"
             )

      assert has_element?(view, "#project-people [title='@owner-here']")
    end
  end

  describe "Home's active tracks and Needs you" do
    test "lists every open track at the side, and what needs you with why", %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user, name: "atlas")
      starting = insert_track(project: project, title: "ravix/warming-up", setup_state: "pending")
      broken = insert_track(project: project, title: "ravix/broken", setup_state: "failed")
      quiet = insert_track(project: project, title: "ravix/quiet", opened_at: DateTime.utc_now())

      view = live_at(conn, user, "/home")

      assert has_element?(
               view,
               "#home-active-#{starting.id}[href='/p/#{project.id}/t/#{starting.id}']",
               "warming-up"
             )

      assert has_element?(view, "#home-side #home-active-#{quiet.id}", "quiet")
      assert has_element?(view, "#home-needs-#{broken.id}", "could not be set up")
      refute has_element?(view, "#home-needs-#{quiet.id}")
    end

    test "says when nothing is open and nothing needs you", %{conn: conn} do
      user = insert_user()
      insert_project(user: user)
      view = live_at(conn, user, "/home")

      assert has_element?(view, "#home-active-empty", "No open tracks")
      assert has_element?(view, "#home-needs-empty", "Nothing needs you")
    end
  end

  describe "a project's About column" do
    test "names its repository and whose subscription it runs on", %{conn: conn} do
      owner = insert_user(login: "owner-of-it")
      project = insert_project(user: owner, repo_full_name: "acme/widgets")
      insert_track(project: project)
      view = live_at(conn, owner, "/p/#{project.id}")

      assert has_element?(
               view,
               "#project-about a[href='https://github.com/acme/widgets']",
               "github.com/acme/widgets"
             )

      assert has_element?(view, "#project-about", "@owner-of-it's subscription")
    end
  end

  test "somebody invited to one track sees that track and no project actions", %{conn: conn} do
    owner = insert_user()
    guest = insert_user()
    project = insert_project(user: owner)
    shared = insert_track(project: project, title: "ravix/shared-one")
    hidden = insert_track(project: project, title: "ravix/not-shared")
    insert_track_member(shared, guest)

    view = live_at(conn, guest, "/p/#{project.id}")

    assert has_element?(view, "#tracks-graph-row-#{shared.id}")
    refute has_element?(view, "#tracks-graph-row-#{hidden.id}")
    refute has_element?(view, "#project-tracks-new")
    refute has_element?(view, "#project-tracks-closed")
    refute has_element?(view, "#crumb-settings")
    refute has_element?(view, "#crumb-plans")
  end

  describe "Home" do
    test "lists the person's projects, and a section narrows them", %{conn: conn} do
      user = insert_user()
      work = insert_project(user: user, name: "work-app", repo_full_name: "acme/work-app")
      play = insert_project(user: user, name: "dotfiles", repo_full_name: "me/dotfiles")
      insert_track(project: work, title: "ravix/fix-login")
      somebody_elses = insert_project(user: insert_user(), name: "not-mine")

      {:ok, section} = Sections.create(user, %{"name" => "Work"})
      {:ok, _} = Sections.move(user, work.id, section.id)

      view = live_at(conn, user, "/home")

      assert has_element?(view, "#home-project-#{work.id} a[href='/p/#{work.id}']", "work-app")
      assert has_element?(view, "#home-project-#{work.id} .mono", "acme/work-app")
      assert has_element?(view, "#home-project-#{work.id}", "1 open track")
      assert has_element?(view, "#home-project-#{work.id} .lane-pill")
      assert has_element?(view, "#home-project-#{play.id}", "No open tracks")
      refute has_element?(view, "#home-project-#{somebody_elses.id}")

      view |> element("#home-section-#{section.id}") |> render_click()

      assert has_element?(view, "#home-section-#{section.id}[aria-pressed=true]")
      assert has_element?(view, "#home-projects-h", "Work")
      assert has_element?(view, "#home-project-#{work.id}")
      refute has_element?(view, "#home-project-#{play.id}")

      view |> element("#home-section-all") |> render_click()
      assert has_element?(view, "#home-project-#{play.id}")

      # Each open track is a pill under Live tracks; the heading names the
      # section shown.
      assert has_element?(
               view,
               "#home-project-#{work.id} .lane-strip[aria-hidden=true] .lane-pill"
             )

      refute has_element?(view, "#home-project-#{play.id} .lane-pill")
      assert has_element?(view, "#home-projects-h", "All projects")

      # Managing sections and whose tracks to show are on Home's left.
      refute has_element?(view, "#rail-scope")
      view |> element("#home-side #manage-sections") |> render_click()
      assert has_element?(view, "#sections-dialog #move-project-#{play.id}")
      render_click(view, "dismiss", %{})

      # A chosen section that is removed leaves Home on all projects, rather
      # than on an empty list with no filter marked chosen.
      view |> element("#home-section-#{section.id}") |> render_click()
      render_click(view, "delete-section", %{"id" => section.id})
      assert has_element?(view, "#home-section-all[aria-pressed=true]")
      assert has_element?(view, "#home-project-#{work.id}")
      assert has_element?(view, "#home-project-#{play.id}")
    end
  end
end
