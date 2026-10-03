defmodule RavixWeb.StagePagesTest do
  # RAV-100: Inbox, Schedules and Not found share one page container, and
  # Home is a dashboard of projects with what is running and what needs you
  # beside it; a track's owner and age are on its project's list; an address
  # nothing answers is a 404 inside the app shell for somebody signed in; the
  # Inbox's and the Add a repository dialog's loading states hold the shape of
  # what arrives.
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Projects, Repo, Tracks}
  alias Ravix.Fountain.Client
  alias RavixWeb.Live.Guard

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

  # `live/2` will not connect to a page whose dead render is a 404, which is
  # what Not found's is, so a test arrives the way a link in the app does:
  # by patching there from a page that is found.
  defp not_found(conn, path) do
    {:ok, view, _} = live(conn, "/home")
    render_async(view, 1_000)
    render_patch(view, path)
    view
  end

  defp age_session_guard(state) do
    update_in(state.socket.assigns.session_guard, fn guard ->
      %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
    end)
  end

  describe "the page container" do
    test "Inbox, Schedules and Not found draw one container with one heading", %{
      conn: conn
    } do
      user = insert_user()
      insert_project(user: user)

      for {path, title} <- [
            {"/inbox", "Inbox"},
            {"/schedules", "Schedules"},
            {"/nowhere", "Page not found"}
          ] do
        view =
          if path == "/nowhere",
            do: not_found(log_in_user(conn, user), path),
            else: live_at(conn, user, path)

        assert has_element?(view, "#project-tabpanel .stage-page .stage-page-inner h1", title)

        assert view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(".stage-page")
               |> Enum.count() == 1
      end
    end

    test "Home with projects is the dashboard, with one heading and no page container", %{
      conn: conn
    } do
      user = insert_user()
      insert_project(user: user)
      view = live_at(conn, user, "/home")

      assert has_element?(view, "#project-tabpanel #home.home-dashboard")
      assert has_element?(view, "#home #home-side")

      assert has_element?(
               view,
               "#home .home-main #home-projects h1#home-projects-h",
               "All projects"
             )

      assert has_element?(view, "#home #home-activity")
      refute has_element?(view, ".stage-page")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#project-tabpanel h1")
             |> Enum.count() == 1
    end
  end

  describe "Home" do
    test "lists projects; each track's owner and age are on its project's list", %{conn: conn} do
      owner = insert_user(login: "rowan")
      colleague = insert_user(login: "sasha")
      project = insert_project(user: owner, name: "ravix", repo_full_name: "ravix-hq/ravix")
      insert_project_member(project, colleague)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      older =
        insert_track(
          project: project,
          title: "ravix/fix-login",
          created_by_login: "rowan",
          created_at: DateTime.add(now, -3, :hour)
        )

      newer =
        insert_track(
          project: project,
          title: "ravix/tidy-router",
          created_by_login: "sasha",
          created_by: colleague.id,
          created_at: DateTime.add(now, -5, :minute)
        )

      view = live_at(conn, owner, "/home")

      # Home lists the repository once, with its two open tracks counted and
      # drawn as two pills in its strip.
      row = "#home-project-#{project.id}"
      assert has_element?(view, "#{row} a#project-link-#{project.id}[href='/p/#{project.id}']")
      assert has_element?(view, "#{row} .chip", "ravix-hq/ravix")
      assert has_element?(view, row, "2 open tracks")

      assert view
             |> element("#{row} .lane-strip")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".lane-pill")
             |> Enum.count() == 2

      # Active tracks, at the side: newest activity first, each named with
      # its project and state.
      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#home-active a.home-active-row")
        |> LazyHTML.attribute("id")

      assert ids == ["home-active-#{newer.id}", "home-active-#{older.id}"]
      assert has_element?(view, "#home-side #home-active-#{newer.id}", "tidy-router")
      assert has_element?(view, "#home-active-#{newer.id} .home-active-meta", "ravix")
      assert has_element?(view, "#home-active-#{newer.id} .home-active-state", "Starting")
      assert has_element?(view, "#home-active-#{newer.id} .dot.starting")

      # New track is the top bar's, with one per project on its row; adding
      # a repository is the project list's New project.
      assert has_element?(view, "#topbar #top-new-track[data-new-track-trigger]", "New track")
      refute has_element?(view, "#home [data-new-track-trigger]")

      assert has_element?(
               view,
               "#{row} a#new-track-#{project.id}[href='/p/#{project.id}?new=track']"
             )

      assert has_element?(
               view,
               "#home-projects #home-add-repository[phx-value-name=new-project]",
               "New project"
             )

      # Two tracks of one repository read as two pieces of work on its page:
      # their own titles, who started them and when they last moved.
      view |> element("#project-link-#{project.id}") |> render_click()
      assert_patch(view, "/p/#{project.id}")
      view |> element("#project-tracks-list") |> render_click()

      assert has_element?(view, "#tracks-row-#{older.id} .tracks-title", "fix-login")
      assert has_element?(view, "#tracks-row-#{older.id} .tracks-row-meta", "3h ago by @rowan")
      assert has_element?(view, "#tracks-row-#{older.id} .tracks-row-age", "3h ago")
      assert has_element?(view, "#tracks-row-#{newer.id} .tracks-title", "tidy-router")
      assert has_element?(view, "#tracks-row-#{newer.id} .tracks-row-meta", "by @sasha")
    end

    test "other people's tracks are listed, each with whose it is", %{conn: conn} do
      user = insert_user()
      other = insert_user()
      project = insert_project(user: user)
      insert_project_member(project, other)
      theirs = insert_track(project: project, created_by: other.id, created_by_login: other.login)

      view = live_at(conn, user, "/home")
      # Nothing filters by who made a track; the row says whose it is.
      refute has_element?(view, "#rail-scope-mine")
      assert has_element?(view, "#home-active-#{theirs.id} .track-owner", "@#{other.login}")

      assert has_element?(
               view,
               "#home-active-#{theirs.id} .track-sharing[aria-label='Shared with you by @#{other.login}']"
             )
    end

    test "draws skeleton rows, not an empty list, before the rail arrives", %{conn: conn} do
      user = insert_user()
      insert_project(user: user)
      html = conn |> log_in_user(user) |> get("/home") |> html_response(200)

      assert html =~ ~s(id="rail-loading")
      assert html =~ "rail-row-skeleton"
      refute html =~ "No open tracks."
      refute html =~ "No projects in this section."
      refute html =~ "Start your first track"
    end
  end

  describe "the Inbox while it loads" do
    test "holds two cards the shape of a real one", %{conn: conn} do
      user = insert_user()
      insert_project(user: user)
      html = conn |> log_in_user(user) |> get("/inbox") |> html_response(200)

      skeletons =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#inbox-loading .inbox-item-skeleton")

      assert Enum.count(skeletons) == 2

      for part <- ~w(skeleton-chip skeleton-project skeleton-age skeleton-title skeleton-line) do
        assert skeletons |> LazyHTML.query(".#{part}") |> Enum.count() == 2
      end
    end
  end

  describe "Not found" do
    test "is a 404 inside the shell, with Inbox and Search to go on with", %{conn: conn} do
      user = insert_user()
      conn = log_in_user(conn, user)
      dead = get(conn, "/no/such/page")

      html = html_response(dead, 404)
      assert html =~ ~s(id="topbar")
      assert html =~ ~s(id="not-found")
      assert html =~ "Page not found · Ravix"

      view = not_found(conn, "/no/such/page")
      assert page_title(view) == "Page not found · Ravix"
      assert has_element?(view, "#not-found h1", "Page not found")
      refute has_element?(view, ".inbox-list")

      view |> element("#not-found-search") |> render_click()
      assert has_element?(view, "#search-dialog")

      render_click(view, "dismiss-switcher")
      view |> element("#not-found-inbox", "Go to Inbox") |> render_click()
      assert_patch(view, "/inbox")
      assert has_element?(view, "#inbox h1", "Inbox")
    end

    test "is the plain 404 page for somebody signed out", %{conn: conn} do
      html = conn |> get("/no/such/page") |> html_response(404)

      assert html =~ "404 · Page not found"
      refute html =~ ~s(id="topbar")
    end

    test "is the plain 404 page for a session that has ended", %{conn: conn} do
      user = insert_user()
      {token, session} = insert_session(user)
      Repo.delete!(session)

      html =
        conn
        |> Plug.Test.init_test_session(session_token: token)
        |> get("/no/such/page")
        |> html_response(404)

      assert html =~ "404 · Page not found"
      refute html =~ ~s(id="topbar")
    end

    test "answers a client that wants JSON 404, not 406", %{conn: conn} do
      user = insert_user()

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/json")
        |> get("/.well-known/oauth-authorization-server/mcp")

      assert json_response(conn, 404)
    end

    test "Search refuses a session revoked while the page is open", %{conn: conn} do
      user = insert_user()
      {token, session} = insert_session(user)

      view = not_found(Plug.Test.init_test_session(conn, session_token: token), "/no-such-page")
      assert has_element?(view, "#not-found")
      Repo.delete!(session)
      :sys.replace_state(view.pid, &age_session_guard/1)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#not-found-search") |> render_click()
    end

    test "names nothing of another person's project it was given an id of", %{conn: conn} do
      owner = insert_user()
      project = insert_project(user: owner, name: "Someone's secret")
      stranger = insert_user()

      conn = log_in_user(conn, stranger)
      assert conn |> get("/p/#{project.id}/nothing-here") |> html_response(404) =~ "not-found"
      view = not_found(conn, "/p/#{project.id}/nothing-here")
      html = render(view)

      assert has_element?(view, "#not-found")
      refute html =~ "Someone&#39;s secret"
      refute html =~ "Someone's secret"
    end
  end

  describe "Schedules" do
    test "one intro line, the rest behind Learn more, and an empty-state card", %{conn: conn} do
      user = insert_user()
      insert_project(user: user)
      view = live_at(conn, user, "/schedules")

      assert has_element?(view, "#schedules-panel .stage-page-sub details summary", "Learn more")
      assert has_element?(view, "#schedules-panel details #schedules-refresh-note")
      assert has_element?(view, "#schedules-panel .stage-page-actions button", "Refresh")
      assert has_element?(view, "#schedules-empty .empty h3", "No schedules yet")
      assert has_element?(view, "#schedules-empty .empty button", "Create schedule")
      assert has_element?(view, "#schedule-form p.hint", "Times are in the schedule's time zone")
    end
  end

  describe "the Add a repository dialog" do
    test "holds the GitHub account field's place while repositories load", %{conn: conn} do
      stub(Accounts, :capabilities, fn -> %{github: true} end)
      test = self()

      stub(Projects, :repos, fn _user, _id ->
        send(test, {:repos_asked, self()})

        receive do
          :answer ->
            {:ok, %{installations: [%{account: "acme", id: 42}], repos: [], selected: 42}}
        end
      end)

      user = insert_user()
      insert_project(user: user)
      view = live_at(conn, user, "/home")
      view |> element("#home-add-repository", "New project") |> render_click()
      assert_receive {:repos_asked, loader}

      assert has_element?(view, "#project-repos-loading[role=status] .skeleton-control")
      assert has_element?(view, "#project-repos-loading", "Loading GitHub repositories…")
      assert has_element?(view, "#project-repo[aria-busy=true]")
      refute has_element?(view, "#project-repositories")
      refute has_element?(view, "#installation")

      send(loader, :answer)
      render_async(view)
      refute has_element?(view, "#project-repos-loading")
      assert has_element?(view, "#installation")
      assert has_element?(view, "#project-repositories-none", "No GitHub repositories")
      assert has_element?(view, "#project-repo .repo-scratch input[checked]")
    end
  end
end
