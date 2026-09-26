defmodule RavixWeb.WorkspaceLiveTest do
  use RavixWeb.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, Crypto, Hub, Previews, Projects, QueryCount, Repo, Tracks}
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.GitHub.{ChecksReport, Shapes}
  alias Ravix.Hub.Event
  alias Ravix.People.Store, as: People
  alias Ravix.Tracks.{Diff, Files}
  alias Ravix.Tracks.Transcript
  alias RavixWeb.Live.Guard

  setup :verify_on_exit!

  test "page titles follow navigation and background rail updates", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Title project")
    track = insert_track(project: project, title: "Track title")
    conn = log_in_user(conn, user)

    routes = [
      {"/home", "Home · Ravix"},
      {"/", "Inbox · Ravix"},
      {"/inbox", "Inbox · Ravix"},
      {"/schedules", "Schedules · Ravix"},
      {"/p/#{project.id}", "Title project · Ravix"},
      {"/p/#{project.id}/t/#{track.id}", "Track title · Title project · Ravix"}
    ]

    {:ok, view, _} = live(conn, "/home")

    for {path, title} <- routes do
      {:ok, direct, _} = live(conn, path)
      assert page_title(direct) == title
      GenServer.stop(direct.pid)
      render_patch(view, path)
      assert page_title(view) == title
      Hub.publish(project.id, :tracks)
      render(view)
      render_async(view, 5_000)
      assert page_title(view) == title
    end

    Repo.update_all(from(t in Ravix.Tracks.Track, where: t.id == ^track.id),
      set: [title: "Renamed track"]
    )

    Hub.publish(project.id, :turn, track_id: track.id)
    render(view)
    render_async(view, 5_000)
    assert page_title(view) == "Renamed track · Title project · Ravix"
  end

  test "sign in has its own document title", %{conn: conn} do
    {:ok, view, _} = live(conn, "/login")
    assert page_title(view) == "Sign in · Ravix"
  end

  test "inbox opens the unread non-default thread and clears all unread indicators", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    row = insert_track(project: project)

    {:ok, other} =
      Tracks.Store.create_thread(%{
        track_id: row.id,
        title: "Thread 2",
        conversation_id: "second"
      })

    threads = [
      %{id: row.id, title: "Default", status: :ready, unread: false},
      %{id: other.id, title: "Thread 2", status: :ready, unread: true}
    ]

    track = %{Tracks.present(row) | status: :ready, unread: true, threads: threads}
    stub_track(row)
    stub(Tracks, :list, fn _, _ -> {:ok, [track]} end)

    stub(Tracks, :get, fn _, _, _ ->
      {:ok, %{track: track, header: blank_header(), threads: threads, starters: [], models: []}}
    end)

    stub(Tracks, :mark_read, fn user, id, thread ->
      Mimic.call_original(Tracks, :mark_read, [user, id, thread])
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view)
    path = "/p/#{project.id}/t/#{row.id}?thread=#{other.id}"
    assert has_element?(view, ~s|.inbox-item[href="#{path}"]|)
    assert has_element?(view, ~s|a[href="/inbox"] .badge|, "1")
    view |> element(".inbox-item") |> render_click()
    assert_patch(view, path)
    child = find_live_child(view, "track-host")
    render_async(child)
    assert has_element?(child, ~s|[data-thread-id="#{other.id}"][aria-current="true"]|)
    assert Repo.get_by(Tracks.ThreadRead, thread_id: other.id, user_id: user.id)
    refute has_element?(view, ~s|a[href="/inbox"] .badge|)
    refute has_element?(view, ".track-tab .dot")
    refute has_element?(view, ".dot.unread")

    foreign = insert_track()
    render_patch(view, "/p/#{project.id}/t/#{row.id}?thread=#{foreign.id}")
    assert has_element?(child, ~s|[data-thread-id="#{other.id}"][aria-current="true"]|)
    refute Repo.get_by(Tracks.ThreadRead, thread_id: foreign.id, user_id: user.id)
  end

  test "the shell and deep-linked child render while the initial rail is blocked", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, title: "Deep-linked work")
    stub_track(track)
    test_pid = self()

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :mount, :stop],
        fn _, times, meta, _ ->
          case meta.socket do
            %{view: RavixWeb.WorkspaceLive, assigns: %{current_user: %{id: id}}} = socket
            when id == user.id ->
              send(
                test_pid,
                {:mount_finished, Phoenix.LiveView.connected?(socket), times.duration}
              )

            _ ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, [Tracks.present(track)]})
    end)

    conn = log_in_user(conn, user)
    dead = get(conn, "/p/#{project.id}/t/#{track.id}")
    assert html_response(dead, 200) =~ "rail-loading"
    refute_received {:rail_started, _}
    assert_receive {:mount_finished, false, dead_duration}

    {:ok, view, _} = live(dead)
    assert_receive {:rail_started, worker}
    assert_receive {:mount_finished, true, connected_duration}

    IO.puts(
      "WorkspaceLive.mount with rail blocked: dead=#{System.convert_time_unit(dead_duration, :native, :microsecond)}µs connected=#{System.convert_time_unit(connected_duration, :native, :microsecond)}µs"
    )

    assert has_element?(view, "#rail-loading")
    child = find_live_child(view, "track-host")
    assert render_async(child) =~ "Deep-linked work"
    refute_patched(view)
    send(worker, :release_rail)
    render_async(view)
    refute has_element?(view, "#rail-loading")
    assert has_element?(view, ".workspace-project-name[href='/p/#{project.id}']")
  end

  test "an unknown project waits for the rail before flashing and leaving", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    test_pid = self()

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, []})
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/missing")
    assert_receive {:rail_started, worker}
    refute_patched(view)
    refute render(view) =~ "no longer available"
    send(worker, :release_rail)
    assert render_async(view) =~ "That project or track is no longer available."
    assert_patch(view, "/")
  end

  test "a revoked session cannot apply its initial async rail", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    {token, session} = insert_session(user)
    test_pid = self()

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, []})
    end)

    {:ok, view, _} = live(Plug.Test.init_test_session(conn, session_token: token), "/home")
    assert_receive {:rail_started, worker}
    Repo.delete!(session)
    :sys.replace_state(view.pid, &age_session_guard/1)
    send(worker, :release_rail)
    assert_redirect(view, "/login")
  end

  test "membership removed during the initial read is not restored by its result", %{conn: conn} do
    user = insert_user()
    project = insert_project()
    insert_project_member(project, user)
    test_pid = self()

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, []})
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    assert_receive {:rail_started, worker}
    People.remove_project_member(project.id, user.id)
    send(worker, :release_rail)
    render_async(view)
    refute has_element?(view, ".workspace-project-name[href='/p/#{project.id}']")
    assert_patch(view, "/")
  end

  test "a pending unavailable URL cannot replace a newer selection", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    test_pid = self()

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, []})
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/missing")
    assert_receive {:rail_started, worker}
    render_patch(view, "/p/#{project.id}")
    assert_patch(view, "/p/#{project.id}")
    send(worker, :release_rail)
    render_async(view)
    assert page_title(view) == project.name <> " · Ravix"
    refute_patched(view)
    refute render(view) =~ "no longer available"
  end

  test "a removed track share is filtered even while another share keeps the project visible", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project()
    kept = insert_track(project: project, title: "Kept share")
    removed = insert_track(project: project, title: "Removed share")
    insert_track_member(kept, user)
    insert_track_member(removed, user)
    test_pid = self()

    expect(Tracks, :list, fn _, _ ->
      send(test_pid, {:rail_started, self()})
      receive do: (:release_rail -> {:ok, Enum.map([kept, removed], &Tracks.present/1)})
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    assert_receive {:rail_started, worker}
    People.remove_member(removed.id, user.id)
    send(worker, :release_rail)
    html = render_async(view)
    assert html =~ "Kept share"
    refute html =~ "Removed share"
  end

  test "notifications are independent for two threads on one track", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Ravix")
    row = insert_track(project: project, title: "Work")

    {:ok, other} =
      Tracks.Store.create_thread(%{track_id: row.id, title: "Next", conversation_id: "next"})

    view_row = Tracks.present(row)
    first = %{id: row.id, title: "Default", status: :running, unread: false}
    second = %{id: other.id, title: "Next", status: :running, unread: false}

    rail = fn a, b ->
      stub(Tracks, :list, fn _, _ -> {:ok, [%{view_row | threads: [a, b]}]} end)
    end

    rail.(first, second)
    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view)
    refute_push_event(view, "notify", %{})

    refresh = fn ->
      send(view.pid, {:hub, Event.new(:turn, project.id, track_id: row.id)})
      render_async(view, 1_000)
    end

    first = %{first | status: :ready, unread: true}
    rail.(first, second)
    refresh.()
    id = row.id

    assert_push_event(view, "notify", %{
      tracks: [%{id: ^id, thread_id: ^id, title: "Work"}]
    })

    second = %{second | status: :failed, unread: true}
    rail.(first, second)
    refresh.()
    thread_id = other.id

    assert_push_event(view, "notify", %{
      tracks: [%{id: ^id, thread_id: ^thread_id, status: :failed}]
    })

    refresh.()
    refute_push_event(view, "notify", %{})
    render_click(view, "open-notice", %{track: row.id, thread: other.id})
    assert_patch(view, "/p/#{project.id}/t/#{row.id}")
    foreign = insert_track()
    render_click(view, "open-notice", %{track: row.id, thread: foreign.id})
    refute_patched(view)
  end

  test "project labels distinguish owners for project and track guests", %{conn: conn} do
    owner = insert_user(login: "project-owner")
    project = insert_project(user: owner, name: "ravix")
    track = insert_track(project: project, title: "Visible track")
    hidden_track = insert_track(project: project, title: "Private sibling")
    member = insert_user()
    guest = insert_user()
    insert_project_member(project, member)
    insert_track_member(track, guest)
    hidden = insert_project(user: insert_user(login: "hidden-owner"), name: "Secret project")

    for {user, label} <- [
          {owner, "ravix"},
          {member, "project-owner / ravix"},
          {guest, "project-owner / ravix"}
        ] do
      {:ok, view, _} = live(log_in_user(conn, user), "/home")
      render_async(view)
      selector = ".workspace-project-name[href='/p/#{project.id}'] .project-label"
      assert has_element?(view, selector, label)
      assert has_element?(view, ".home-recent .project-label", label)
      assert has_element?(view, selector <> " .dim") == (user != owner)
      refute render(view) =~ hidden.name
      refute render(view) =~ "hidden-owner"
      render_patch(view, "/p/#{project.id}")
      assert page_title(view) == label <> " · Ravix"
      if user == guest, do: refute(render(view) =~ hidden_track.title)

      render_click(view, "dialog", %{name: "search"})
      render_change(view, "search", %{q: "PROJECT-OWNER"})
      assert has_element?(view, "#search-dialog h3", label)
      assert has_element?(view, "#search-dialog a", "Visible track")
      if user == guest, do: refute(has_element?(view, "#search-dialog a", hidden_track.title))
      render_click(view, "dismiss")

      if user != guest do
        render_click(view, "dialog", %{name: "people"})
        assert has_element?(view, "#people-dialog .project-label", label)
      end
    end

    assert {:ok, stranger, _} = live(log_in_user(conn, insert_user()), "/home")
    refute render(stranger) =~ "project-owner"
  end

  test "shared labels escape project text and revoked sessions cannot search them", %{conn: conn} do
    owner = insert_user(login: "label-owner")
    project = insert_project(user: owner, name: "<img src=x onerror=alert(1)>")
    guest = insert_user()
    insert_project_member(project, guest)
    insert_track(project: project)
    {token, session} = insert_session(guest)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(conn, session_token: token), "/p/#{project.id}")

    html = render_async(view)

    assert html =~ "&lt;img"
    refute has_element?(view, ".project-label img")
    Repo.delete!(session)
    :sys.replace_state(view.pid, &age_session_guard/1)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "dialog", %{name: "search"})
  end

  test "workspace help explains connections and returns to the workspace", %{conn: conn} do
    user = insert_user()
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    view |> element("#open-help") |> render_click()
    assert has_element?(view, "#help-dialog-title", "Help – AI tools")
    assert has_element?(view, "#help-mcp-command button[aria-label='Copy Claude Code command']")
    assert has_element?(view, "#help-a2a-request button[aria-label='Copy JSON-RPC request']")
    assert has_element?(view, "#help-dialog", "Connect Claude Code with MCP")
    assert has_element?(view, "#help-dialog code", Ravix.Config.public_url() <> "/mcp")
    assert has_element?(view, "#help-dialog", "SubscribeToTask")
    assert has_element?(view, "#help-dialog a[href='/settings/connections']")
    view |> element("#help-dialog button", "What's new") |> render_click()
    assert has_element?(view, "#changes-dialog", "Changes in Ravix since you last checked.")
    refute has_element?(view, "#changes-dialog .chip")
    view |> element("#changes-dialog button", "Mark all as read") |> render_click()
    view |> element("#changes-dialog button[aria-label='Close']") |> render_click()
    refute has_element?(view, "#help-dialog")
    assert has_element?(view, "#open-help")
  end

  test "what is new counts what shipped since somebody arrived, then stops", %{conn: conn} do
    [entry | _] = Ravix.Changelog.all()
    # Somebody who was here before the newest change has it to read; somebody
    # who arrived after it never missed it. Neither has opened the panel, so
    # this is the mark that stands in until they do.
    early = insert_user(created_at: DateTime.add(Ravix.Changelog.at(entry), -1, :day))
    late = insert_user(created_at: DateTime.add(Ravix.Changelog.at(entry), 1, :day))

    {:ok, view, _} = live(log_in_user(conn, early), "/home")
    render_async(view)
    # The count is in the account menu, and a dot on the closed menu's
    # trigger says there is something in there to read.
    assert has_element?(view, "#account-menu #open-changes .badge")
    assert has_element?(view, "#account-trigger #account-unseen", "new in What's new")
    view |> element("#open-changes") |> render_click()
    assert has_element?(view, "#changes-dialog", entry.title)
    # Opening it is the acknowledgement: the count goes, and stays gone.
    refute has_element?(view, "#open-changes .badge")
    refute has_element?(view, "#account-unseen")
    assert Repo.get!(Ravix.Accounts.User, early.id).changes_seen_at
    {:ok, again, _} = live(log_in_user(conn, early), "/home")
    render_async(again)
    refute has_element?(again, "#open-changes .badge")

    {:ok, fresh, _} = live(log_in_user(conn, late), "/home")
    render_async(fresh)
    refute has_element?(fresh, "#open-changes .badge")
    refute has_element?(fresh, "#account-unseen")
    render_click(fresh, "dialog", %{name: "changes"})
    refute has_element?(fresh, "#changes-dialog", entry.title)
  end

  test "a signed-out browser is sent to sign in from anywhere it lands", %{conn: conn} do
    for path <- ["/", "/home", "/inbox", "/p/no-project"] do
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, path)
    end
  end

  test "sign-in works without a configured backend", %{conn: conn} do
    {:ok, signin, _} = live(conn, "/login")
    render_async(signin)
    assert has_element?(signin, "h1", "Sign in to Ravix")

    assert has_element?(
             signin,
             "#signin-theme[data-phx-hook='Theme'], #signin-theme[phx-hook='Theme']"
           )

    assert render(signin) =~ "GitHub sign-in is not configured"
    refute has_element?(signin, "a[href='/auth/github']")
    refute has_element?(signin, "#new-project-form")
    # Nothing points back at a page that no longer exists.
    refute has_element?(signin, "a[href='/']")
  end

  test "somebody already signed in is sent on from /login to the workspace", %{conn: conn} do
    user = insert_user()

    assert {:error, {:live_redirect, %{to: "/"}}} = live(log_in_user(conn, user), "/login")
  end

  test "home actions open fresh project forms and recent projects stay scoped", %{conn: conn} do
    user = insert_user()
    own = insert_project(user: user, name: "Recent work")
    hidden = insert_project(user: insert_user(), name: "Private work")
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    assert has_element?(view, ".home-recent a[href='/p/#{own.id}']", "Recent work")
    refute render(view) =~ hidden.name
    assert has_element?(view, ".home-action[disabled]", "Open a local project")
    view |> element(".home-action", "Open a GitHub project") |> render_click()
    view |> form("#new-project-form", new_project: [name: "Abandoned name"]) |> render_change()
    render_click(view, "dismiss")
    view |> element(".home-action", "Quick start") |> render_click()
    # A pristine form renders no `value` at all, which is how the field
    # comes up empty; the point of the assertion is that the abandoned name
    # is not still in it.
    assert has_element?(view, "#project-name:not([value])")
    assert has_element?(view, "#project-repo option[value='']", "No repository")
    refute render(view) =~ "Abandoned name"
  end

  test "inbox shows only failed and unread ready tracks", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    rows =
      for title <- ["Review this", "Still working", "Needs help"],
          do: insert_track(project: project, title: title)

    tracks =
      Enum.zip_with(rows, [:ready, :running, :failed], fn row, status ->
        row |> Tracks.present(project: project) |> struct!(status: status, unread: true)
      end)

    stub(Tracks, :list, fn actual_user, project_id ->
      assert actual_user.id == user.id
      assert project_id == project.id
      {:ok, tracks}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view)
    assert has_element?(view, ".inbox-item", "Review this")
    assert has_element?(view, ".inbox-item", "Needs help")
    refute has_element?(view, ".inbox-item", "Still working")
    refute has_element?(view, ".inbox-empty")

    stub(Tracks, :list, fn _, _ ->
      {:ok, Enum.map(tracks, &struct!(&1, status: :ready, unread: false))}
    end)

    refute has_element?(view, "button", "Refresh")
    Hub.publish(project.id, :turn, track_id: hd(rows).id)
    render(view)
    # A project event updates the inbox without a manual refresh.
    render_async(view)
    refute has_element?(view, ".inbox-item")
    assert has_element?(view, ".inbox-empty", "You're all caught up")
  end

  test "desktop notifications use each viewer's project label", %{conn: conn} do
    owner = insert_user(login: "notice-owner")
    project = insert_project(user: owner, name: "ravix")
    row = insert_track(project: project)
    member = insert_user()
    guest = insert_user()
    insert_project_member(project, member)
    insert_track_member(row, guest)
    track = Tracks.present(row, project: project)

    # What is announced is a thread's change, so the default thread carries it.
    at = fn status, unread ->
      default = %{id: track.id, title: "Default", status: status, unread: unread}
      struct!(track, status: status, unread: unread, threads: [default])
    end

    for user <- [owner, member, guest] do
      stub(Tracks, :list, fn _, _ -> {:ok, [at.(:running, false)]} end)
      {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
      render_async(view)
      stub(Tracks, :list, fn _, _ -> {:ok, [at.(:ready, true)]} end)
      send(view.pid, {:hub, Event.new(:turn, project.id, track_id: row.id)})
      render_async(view)
      label = if user == owner, do: "ravix", else: "notice-owner / ravix"
      assert_push_event(view, "notify", %{tracks: [%{project: ^label}]})
    end
  end

  test "a track that comes to need somebody is announced to the browser, once", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Ravix")
    waiting = insert_track(project: project, title: "Already waiting")
    working = insert_track(project: project, title: "Working")

    [waiting, working] =
      Enum.map([waiting, working], &Tracks.present(&1, project: project))

    # Each row carries its default thread, which is what is announced.
    default = fn view ->
      %{
        view
        | threads: [
            %{id: view.id, title: "Default", status: view.status, unread: view.unread}
          ]
      }
    end

    waiting = default.(struct!(waiting, status: :failed, unread: true))

    rail = fn working ->
      stub(Tracks, :list, fn _, _ -> {:ok, [waiting, default.(working)]} end)
    end

    rail.(struct!(working, status: :running, unread: false))
    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view)
    turn = fn -> send(view.pid, {:hub, Event.new(:turn, project.id, track_id: working.id)}) end
    assert has_element?(view, ".inbox-item", "Already waiting")
    # What was waiting when the page opened is the inbox's to show, not news.
    refute_push_event(view, "notify", %{})

    rail.(struct!(working, status: :ready, unread: true))
    turn.()
    render_async(view)
    id = working.id

    assert_push_event(view, "notify", %{
      tracks: [%{id: ^id, title: "Working", project: "Ravix", status: :ready}]
    })

    # Said once: the same rail read again is not news again, and the failed
    # track, still failed, is never repeated.
    turn.()
    render_async(view)
    refute_push_event(view, "notify", %{})

    # Read, then finished again, is news again.
    rail.(struct!(working, status: :ready, unread: false))
    turn.()
    render_async(view)
    refute_push_event(view, "notify", %{})
    rail.(struct!(working, status: :ready, unread: true))
    turn.()
    render_async(view)
    assert_push_event(view, "notify", %{tracks: [%{id: ^id}]})

    # Clicking the notification opens the track through the page, which
    # checks it against the rail; a track this person cannot see is nowhere
    # to go, and a made-up one is not a crash.
    render_click(view, "open-notice", %{"track" => id})
    assert_patch(view, "/p/#{project.id}/t/#{id}")
    other = insert_track(project: insert_project(user: insert_user()))
    render_click(view, "open-notice", %{"track" => other.id})
    render_click(view, "open-notice", %{"track" => 7})
    refute_patched(view)
    assert has_element?(view, "#notify[phx-hook='Notify'], #notify[data-phx-hook='Notify']")
  end

  test "the rail and inbox are scoped to the signed-in user", %{conn: conn} do
    user = insert_user()
    own = insert_project(user: user, name: "My project")
    insert_project(name: "Someone else's project", user: insert_user())
    track = insert_track(project: own, title: "My work")
    {:ok, view, _} = live(log_in_user(conn, user), "/")
    render_async(view)
    assert has_element?(view, "a", "My project")
    refute has_element?(view, "#yard a", "My work")
    refute render(view) =~ "Someone else"
    view |> element("a.workspace-project-name") |> render_click()
    assert_patch(view, "/p/#{own.id}")
    assert has_element?(view, "button", "New track")
    assert has_element?(view, "a[href='/p/#{own.id}/t/#{track.id}']")
  end

  test "project disclosure and inline creation follow scoped navigation", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    insert_track(project: project)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    refute has_element?(view, "#yard .workspace-track")
    refute has_element?(view, ".track-tabs")
    view |> element("a.project-add") |> render_click()
    assert_patch(view, "/p/#{project.id}?new=track")
    assert has_element?(view, "#new-track-form")
    assert has_element?(view, ".track-tabs .workspace-track")
    view |> form("#new-track-form", new_track: [title: "Keep this name"]) |> render_change()
    view |> element("button", "Advanced") |> render_click()
    refute has_element?(view, "#track-advanced[hidden]")
    view |> element("button", "Hide advanced") |> render_click()
    assert has_element?(view, "#track-advanced[hidden]")
    assert has_element?(view, "#track-title[value='Keep this name']")
    render_click(view, "dismiss")
    assert_patch(view, "/p/#{project.id}")
    refute has_element?(view, "#new-track-form")
  end

  test "track tabs follow the selected project and mark the current track", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)
    other = insert_project(user: user)
    other_track = insert_track(project: other)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(view)

    assert has_element?(
             view,
             ".track-tabs a[aria-current='page'][href='/p/#{project.id}/t/#{track.id}']"
           )

    refute has_element?(view, "#yard .workspace-track")
    refute has_element?(view, ".track-tabs a[href='/p/#{other.id}/t/#{other_track.id}']")
    view |> element(".workspace-project-name[href='/p/#{other.id}']") |> render_click()
    assert has_element?(view, ".track-tabs a[href='/p/#{other.id}/t/#{other_track.id}']")
    refute has_element?(view, ".track-tabs a[href='/p/#{project.id}/t/#{track.id}']")
  end

  test "track tabs drop the shared namespace and show each track's state", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    tracks =
      for {title, status, unread} <- [
            {"ravix/idle", :ready, false},
            {"ravix/busy", :running, false},
            {"ravix/booting", :opening, false},
            {"ravix/broken", :failed, false},
            {"ravix/answered", :ready, true},
            {"feature/login", :ready, false}
          ] do
        insert_track(project: project, title: title)
        |> Tracks.present(project: project)
        |> struct!(status: status, unread: unread)
      end

    tracks =
      List.update_at(tracks, 5, fn track ->
        struct!(track, origin: struct!(track.origin, kind: :plan, title: "Login"))
      end)

    # Everything the tabs say comes from the rail's one list.
    stub(Tracks, :list, fn _user, _project_id -> {:ok, tracks} end)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    tab = fn track -> ".track-tabs a[href='/p/#{project.id}/t/#{track.id}']" end
    [idle, busy, booting, broken, answered, feature] = tracks

    # The namespace every default title shares is left off the tab; the full
    # title is still its accessible name and tooltip.
    assert has_element?(view, "#{tab.(idle)}[aria-label='ravix/idle'][title='ravix/idle']")
    assert render(element(view, "#{tab.(idle)} .track-title")) =~ ~r{>idle</span>}
    # A title outside the namespace is shown whole, and a plan's track says so.
    assert has_element?(view, "#{tab.(feature)} .track-title", "feature/login")

    assert has_element?(
             view,
             "#{tab.(feature)}[aria-label='feature/login, from a project plan']"
           )

    for {track, label} <- [
          {busy, "Working"},
          {booting, "Starting"},
          {broken, "Error"},
          {answered, "Unread reply"}
        ] do
      assert has_element?(view, "#{tab.(track)} .dot[role=img][aria-label='#{label}']")
      assert has_element?(view, "#{tab.(track)}[aria-label='#{track.title}, #{label}']")
      refute has_element?(view, "#{tab.(track)} .track-num")
    end

    # A read, idle track has nothing to report and keeps its ordinal.
    refute has_element?(view, "#{tab.(idle)} [role=img]")
    assert has_element?(view, "#{tab.(idle)} .track-num", "1")
  end

  test "hiding advanced options drops the origin they carried", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, repo: "owner/repo")
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?new=track")
    render_async(view)

    view |> element("button", "Advanced") |> render_click()
    render_click(view, "origin", %{"kind" => "branch"})
    refute render(view) =~ "New worktree from"

    # `hidden` does not disable an input: without a reset the ref select would
    # still submit and open the track from a ref the form no longer shows.
    view |> element("button", "Hide advanced") |> render_click()
    assert has_element?(view, "#track-advanced[hidden]")
    assert render(view) =~ "New worktree from"
    assert has_element?(view, "button.primary", "Blank")
  end

  test "an empty inbox carries no count", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view)

    assert render(view) =~ "You&#39;re all caught up"
    refute has_element?(view, "a.yard-item .badge")
  end

  test "shared project labels identify the owner for project and track members", %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner, name: "Shared work")
    track = insert_track(project: project)
    label = "#{owner.login} / #{project.name}"

    People.add_member(track.id, member.id, owner.id)
    {:ok, shared, _} = live(log_in_user(conn, member), "/p/#{project.id}")
    render_async(shared)
    assert has_element?(shared, ".workspace-project-name", label)
    assert has_element?(shared, "strong", label)

    People.add_project_member(project.id, member.id, owner.id)
    {:ok, project_member, _} = live(log_in_user(conn, member), "/home")
    render_async(project_member)
    assert has_element?(project_member, ".home-recent a[href='/p/#{project.id}']", label)

    {:ok, own, _} = live(log_in_user(conn, owner), "/p/#{project.id}")
    render_async(own)
    assert has_element?(own, ".workspace-project-name", project.name)
    refute has_element?(own, ".workspace-project-name", label)
  end

  test "track-only members cannot open project creation through a URL", %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    People.add_member(track.id, member.id, owner.id)
    {:ok, view, _} = live(log_in_user(conn, member), "/p/#{project.id}?new=track")
    render_async(view)
    refute has_element?(view, "#new-track-form")
    refute has_element?(view, "a.project-add")
    refute has_element?(view, "button", "New track")
    refute has_element?(view, "#yard button.project-action")
  end

  test "the open project's people and settings are actions on its own row", %{conn: conn} do
    user = insert_user()
    mine = insert_project(user: user, name: "Mine")
    other = insert_project(user: user, name: "Other one")
    shared = insert_project(user: insert_user(login: "sharer"), name: "Shared")
    insert_project_member(shared, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{mine.id}")
    render_async(view)

    row = "#yard [data-project-id='#{mine.id}'].current"
    assert has_element?(view, "#{row} button[aria-label='People in Mine']")
    assert has_element?(view, "#{row} button[aria-label='Project settings for Mine']")
    assert has_element?(view, "#{row} a.project-add[aria-label='New track in Mine']")
    # Every row offers a new track; only the open one has dialogs to open,
    # because they act on the open project.
    closed = "#yard [data-project-id='#{other.id}']"
    refute has_element?(view, "#{closed}.current")
    assert has_element?(view, "#{closed} a.project-add")
    refute has_element?(view, "#{closed} button.project-action")
    # The nested links under the open project are gone.
    refute has_element?(view, ".project-links")

    view |> element("#{row} button[aria-label='People in Mine']") |> render_click()
    assert has_element?(view, "#people-dialog")
    render_click(view, "dismiss")

    stub(Projects, :settings, fn _, id when id == mine.id ->
      {:ok,
       %{
         name: "Mine",
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

    view |> element("#{row} button[aria-label='Project settings for Mine']") |> render_click()
    assert has_element?(view, "#settings-dialog")

    # A member who does not own the project has its people but not its settings.
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{shared.id}")
    render_async(view)
    row = "#yard [data-project-id='#{shared.id}'].current"
    assert has_element?(view, "#{row} button[aria-label='People in sharer / Shared']")
    refute has_element?(view, "#{row} button[aria-label^='Project settings']")
  end

  test "the account menu holds preferences, help and signing out", %{conn: conn} do
    user = insert_user(login: "menuuser")
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)

    # One row at the top opens it; nothing of it is left at the foot.
    assert has_element?(
             view,
             "#yard button#account-trigger[popovertarget='account-menu']",
             "@menuuser"
           )

    refute has_element?(view, ".workspace-account")
    menu = "#yard #account-menu[popover]"

    for item <- [
          "#theme-picker",
          "#notify",
          "a[href='/api/auth/install']",
          "a[href='/auth/signout']"
        ] do
      assert has_element?(view, "#{menu} #{item}")
    end

    # Each item that opens a dialog also hides the menu, and returns focus to
    # the trigger when the dialog closes, since the item itself is hidden.
    for {id, dialog} <- [
          {"open-account", "#account-dialog"},
          {"open-help", "#help-dialog"},
          {"open-changes", "#changes-dialog"}
        ] do
      item = "#{menu} button##{id}[popovertarget='account-menu'][popovertargetaction='hide']"
      assert has_element?(view, item)
      assert view |> element(item) |> render() =~ "#account-trigger"
      view |> element(item) |> render_click()
      assert has_element?(view, dialog)
      render_click(view, "dismiss")
    end
  end

  test "a track URL cannot name a different project", %{conn: conn} do
    user = insert_user()
    one = insert_project(user: user)
    two = insert_project(user: user)
    track = insert_track(project: two)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{one.id}/t/#{track.id}")
    render_async(view)
    assert_patch(view, "/")
  end

  test "project creation calls the context and navigates to the new project", %{conn: conn} do
    user = insert_user()

    expect(Projects, :create, fn actual_user, attrs ->
      assert actual_user.id == user.id
      assert attrs["name"] == "New project"
      assert attrs["runtime"] == "codex"
      project = insert_project(user: user, name: attrs["name"])
      {:ok, %{id: project.id}}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/")
    render_async(view)
    view |> element(".workspace-actions button", "Add a project") |> render_click()

    view
    |> form("#new-project-form", new_project: [name: "New project", repo: "", runtime: "codex"])
    |> render_submit()

    render_async(view)
    assert has_element?(view, "a.workspace-project-name", "New project")
    assert has_element?(view, "#plans-panel")
  end

  test "signing out somewhere else takes this page with it, without being poked", %{conn: conn} do
    user = insert_user()
    {token, _session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/")
    render_async(view)

    # Signing out announces itself, so the page goes at once rather than
    # waiting for whatever it does next. Before, a page nobody was touching
    # kept its screen until its next message, which might be minutes.
    Accounts.end_session(Crypto.sha256(token))
    assert_redirect(view, "/login", 1_000)
  end

  test "a session gone without notice is still caught, on the page's next act", %{conn: conn} do
    user = insert_user()
    {token, session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/")
    render_async(view)

    # PubSub is best-effort and Ravix runs on more than one instance (ADR
    # 0003), so the notice above can go missing. A row deleted without one is
    # that case, and it is also what an expiry looks like from here, since no
    # code runs at the moment a session runs out.
    #
    # The page holds its answer for at most `Guard.ttl_ms/0`. Ageing that
    # stands in for the wait, and is the whole of what the held answer costs:
    # a revocation that used to be seen on the very next message is seen
    # within fifteen seconds when nothing announced it.
    Repo.delete!(session)
    assert render(view) =~ user.login

    :sys.replace_state(view.pid, &age_session_guard/1)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "dialog", %{name: "new-project"})
  end

  # Put the page's held answer far enough in the past that it has run out.
  defp age_session_guard(state) do
    update_in(state.socket.assigns.session_guard, fn guard ->
      %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
    end)
  end

  test "removed project membership clears the rail on a hub notification", %{conn: conn} do
    owner = insert_user()
    user = insert_user()
    project = insert_project(user: owner)
    People.add_project_member(project.id, user.id, owner.id)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    refute has_element?(view, "button", "Settings")
    People.remove_project_member(project.id, user.id)
    Hub.publish(project.id, :people)
    # `:people` is one of the three that can change which projects exist at
    # all, so it re-reads the whole rail, and that read is a task now.
    refute render_async(view) =~ project.name
  end

  test "the rail ignores the two events it cannot render", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, title: "On the rail")
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    assert render(view) =~ "On the rail"

    cost = fn name ->
      QueryCount.queries(
        fn ->
          send(view.pid, {:hub, Event.new(name, project.id, track_id: track.id)})
          render(view)
        end,
        from: view.pid
      )
    end

    # The rail shows a track's title, branch, status and last activity. Who
    # is looking at a track and what is in its prompt queue are neither, and
    # the queue moves on every prompt sent, delivered or cancelled -- so
    # re-listing every project's tracks for each of those was the largest
    # thing this page did for nothing anybody could see.
    #
    # A comparison rather than a number, because the session guard attached
    # at mount reads a row on every message before this page's own clauses
    # see it. What is asserted is that these two cost that and nothing more.
    ignored = Enum.map([:here, :queue], cost)
    assert [guard] = Enum.uniq(ignored), "the ignored events differ: #{inspect(ignored)}"

    # And that the guard is the whole of it: an event this page does act on
    # reads more than that, in whichever process it reads.
    assert cost.(:settings) == guard
    assert render_async(view) =~ "On the rail"
  end

  test "a turn re-reads the tracks of the project it names, and no others", %{conn: conn} do
    user = insert_user()
    a = insert_project(user: user)
    b = insert_project(user: user)
    on_a = insert_track(project: a, title: "Alpha one")
    on_b = insert_track(project: b, title: "Beta one")

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{a.id}")
    render_async(view)
    assert render(view) =~ "Alpha one"

    # Renamed underneath the page, without the hub being told, so that what
    # is on screen afterwards says which of the two lists was read again. A
    # turn is the most frequent event the rail sees --- one at each end of
    # everything every agent does, on every project this person can see ---
    # and re-reading them all meant a live Fountain call per project, in this
    # process, with the page unable to draw or answer a click meanwhile.
    rename = fn track, title ->
      Repo.update_all(
        from(t in Ravix.Tracks.Track, where: t.id == ^track.id),
        set: [title: title]
      )
    end

    rename.(on_a, "Alpha two")
    rename.(on_b, "Beta two")

    send(view.pid, {:hub, Event.new(:turn, a.id, track_id: on_a.id)})
    html = render_async(view)

    assert html =~ "Alpha two"
    view |> element(".workspace-project-name[href='/p/#{b.id}']") |> render_click()
    assert render(view) =~ "Beta one"
    refute html =~ "Beta two"
  end

  test "a read mark clears the reader's own dot in every tab and re-reads nothing", %{
    conn: conn
  } do
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    People.add_project_member(project.id, member.id, owner.id)
    track = insert_track(project: project, title: "Unread here")
    test_pid = self()

    # The rail's list is the Fountain read this page makes, so this is where
    # a read is counted. Every rail starts with the track wanting attention.
    stub(Tracks, :list, fn user, project_id ->
      send(test_pid, {:listed, user.id})
      assert project_id == project.id
      {:ok, [track |> Tracks.present(project: project) |> struct!(status: :ready, unread: true)]}
    end)

    {:ok, tab_a, _} = live(log_in_user(conn, owner), "/p/#{project.id}")
    render_async(tab_a)
    {:ok, tab_b, _} = live(log_in_user(conn, owner), "/p/#{project.id}")
    render_async(tab_b)
    {:ok, theirs, _} = live(log_in_user(conn, member), "/p/#{project.id}")
    render_async(theirs)

    for view <- [tab_a, tab_b, theirs] do
      assert has_element?(view, ".track-tab [role=img][aria-label='Unread reply']")
      assert has_element?(view, ".badge", "1")
    end

    # The mounts' reads (a page is rendered once over HTTP and once on its
    # socket), accounted for; what follows must add none.
    for view <- [tab_a, tab_b, theirs], do: render_async(view)
    drain = fn drain -> receive(do: ({:listed, _} -> drain.(drain)), after: (0 -> :ok)) end
    drain.(drain)

    assert :ok = Tracks.mark_read(owner, track.id)

    # `render_async/1` waits out any rail read the event might have started
    # in each page before the stub's message is looked for, so an absent
    # message is an absent read rather than a slow one.
    for view <- [tab_a, tab_b, theirs], do: render_async(view)

    # Both of the reader's tabs cleared the dot from the event alone...
    refute has_element?(tab_a, ".track-tab [role=img][aria-label='Unread reply']")
    refute has_element?(tab_b, ".track-tab [role=img][aria-label='Unread reply']")
    refute has_element?(tab_a, ".badge")

    # ...somebody else's rail kept its own mark, which the event says nothing
    # about...
    assert has_element?(theirs, ".track-tab [role=img][aria-label='Unread reply']")

    # ...and nobody went back to Fountain. This used to be a `:tracks` event
    # that re-read every rail on the project, live, whenever anybody opened
    # a track.
    refute_received {:listed, _}
  end

  test "a track loads its transcript, sends prompts, and renders its files", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)

    expect(Tracks, :prompt, fn actual_user, id, payload ->
      assert actual_user.id == user.id
      assert id == track.id
      assert payload.prompt == "Build it"
      {:ok, %{}}
    end)

    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(parent)
    child = find_live_child(parent, "track-host")
    render_async(child)
    assert has_element?(child, "#composer-form")
    assert render(child) =~ "app.ex"
    child |> form("#composer-form", text: "Build it") |> render_submit()
    assert_push_event(child, "composer:clear", %{})
  end

  test "track membership revocation redirects before processing transcript data", %{conn: conn} do
    owner = insert_user()
    user = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, conversation_id: "conversation-test")
    People.add_member(track.id, user.id, owner.id)
    stub_track(track)
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(parent)
    child = find_live_child(parent, "track-host")
    render_async(child)
    People.remove_member(track.id, user.id)
    send(child.pid, {:transcript, track.id, %{"id" => 1, "data" => "private output"}})
    assert_redirect(parent, "/", 1_000)
  end

  test "project settings submit scoped changes", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    settings = %{
      name: project.name,
      runtime: "claude",
      model: "model",
      instructions: "",
      setup_script: "",
      packages: %{},
      env_keys: [],
      vault_keys: [],
      catalog: Catalog.empty()
    }

    stub(Projects, :settings, fn _, id ->
      assert id == project.id
      {:ok, settings}
    end)

    expect(Projects, :update_settings, fn actual_user, id, attrs ->
      assert actual_user.id == user.id
      assert id == project.id
      assert attrs["packages"]["apt"] == ["git", "curl"]
      refute Map.has_key?(attrs, "instructions")
      {:ok, %{rev: 2}}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    view |> element("button", "Settings") |> render_click()

    view
    |> form("#environment-settings-form", settings: [apt: "git curl"])
    |> render_submit()

    # The save runs under `start_async`; the flash only exists once it lands.
    assert render_async(view) =~ "Settings saved"
  end

  test "file, diff, check, and preview panels consume their context shapes", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)

    # Real structs, not map literals with the right-looking keys. The panel
    # now dispatches on which struct it was handed, so a stub that answers
    # with a map exercises nothing -- and `@enforce_keys` is what stops these
    # drifting from what the contexts really return.
    stub(Tracks, :file, fn _, _, _ ->
      {:ok,
       %Files.Content{
         path: "app.ex",
         content: "hello file",
         encoding: "utf-8",
         size: 10,
         truncated: false
       }}
    end)

    patch =
      "diff --git a/app.ex b/app.ex\n--- a/app.ex\n+++ b/app.ex\n@@ -0,0 +1 @@\n+hello change\n"

    files = Diff.parse(patch)

    stub(Tracks, :diff, fn _, _ ->
      {:ok,
       %Diff{
         path: "/workspace/app",
         repo_root: "/workspace/app",
         changes: Enum.map(files, & &1.change),
         files: files,
         diff: patch,
         truncated: false
       }}
    end)

    stub(Tracks, :checks, fn _, _ ->
      {:ok,
       %ChecksReport{
         ref: "track-branch",
         sha: "abc123",
         pull: nil,
         pushed: true,
         runs: [
           %Shapes.CheckRun{
             name: "CI passed",
             status: "completed",
             conclusion: "success",
             url: "https://example.test/check",
             started_at: nil,
             completed_at: nil
           }
         ]
       }}
    end)

    stub(Ravix.Previews, :status, fn _, _ ->
      {:ok,
       %Previews.View{
         state: :stopped,
         available: true,
         unavailable_reason: nil,
         config: nil,
         override: nil,
         error: nil,
         logs: "",
         url: nil
       }}
    end)

    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(parent)
    child = find_live_child(parent, "track-host")
    render_async(child)
    child |> element("button", "app.ex") |> render_click()
    assert render(child) =~ "hello file"
    child |> element("button", "Changes") |> render_click()
    render_async(child)
    child |> element(".change-file", "app.ex") |> render_click()
    assert has_element?(child, ".diff-line.diff-add code", "hello change")
    child |> element("button", "Checks") |> render_click()
    assert render_async(child) =~ "CI passed"
    child |> element("button", "Preview") |> render_click()
    assert render_async(child) =~ "stopped"
    assert has_element?(child, "#preview-config-form")
  end

  test "failed prompts keep the composer and report the error", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)
    expect(Tracks, :prompt, fn _, _, _ -> {:error, {:unavailable, "Please try again"}} end)
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(parent)
    child = find_live_child(parent, "track-host")
    render_async(child)
    child |> form("#composer-form", text: "Keep this draft") |> render_submit()
    # The refusal is a toast, and the toasts are the workspace's: the nested
    # page hands its flash up rather than drawing a second stack.
    render(child)
    assert has_element?(parent, "#flash-group[aria-live=polite] #flash-error", "Please try again")
    refute render(child) =~ "Please try again"
    assert has_element?(child, "#composer-form")
    refute_push_event(child, "composer:clear", %{}, 50)
  end

  test "an uploaded image survives a failed prompt and is sent again on retry", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    render_async(parent)
    child = find_live_child(parent, "track-host")
    render_async(child)

    image = <<137, 80, 78, 71, 13, 10, 26, 10>>

    upload =
      file_input(child, "#composer-form", :images, [
        %{name: "test.png", content: image, type: "image/png"}
      ])

    assert render_upload(upload, "test.png") =~ "test.png"

    expect(Tracks, :prompt, fn _, _, payload ->
      assert payload.images == [%{data: Base.encode64(image), media_type: "image/png"}]
      {:error, {:unavailable, "Try again"}}
    end)

    child |> form("#composer-form", text: "Describe this image") |> render_submit()
    assert render(child) =~ "1 attached image(s) retained for retry"
    refute_push_event(child, "composer:clear", %{}, 50)

    expect(Tracks, :prompt, fn _, _, payload ->
      assert payload.images == [%{data: Base.encode64(image), media_type: "image/png"}]
      {:ok, %{}}
    end)

    child |> form("#composer-form", text: "Describe this image") |> render_submit()
    assert_push_event(child, "composer:clear", %{})
    refute render(child) =~ "attached image(s) retained for retry"
  end

  test "a new preview tab gets a fresh ticket tied to the signed-in session", %{conn: conn} do
    user = insert_user()

    expect(Ravix.Previews, :open, fn actual_user, "track-id", hash ->
      assert actual_user.id == user.id
      assert byte_size(hash) > 0
      {:ok, %{open_url: "https://track.preview.example/__ravix/open#ticket"}}
    end)

    conn = conn |> log_in_user(user) |> get("/preview/track-id")
    assert redirected_to(conn) == "https://track.preview.example/__ravix/open#ticket"
  end

  describe "moving between tracks" do
    setup %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user)
      one = insert_track(project: project, title: "First track", conversation_id: "c-one")
      two = insert_track(project: project, title: "Second track", conversation_id: "c-two")

      stub(Tracks, :get, fn _user, id, _opts ->
        row = Repo.get!(Ravix.Tracks.Track, id)

        {:ok,
         %{
           track: Tracks.present(row),
           header: blank_header(),
           threads: [],
           starters: [],
           models: []
         }}
      end)

      stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, Transcript.empty("")} end)
      stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
      stub(Tracks, :beat, fn _, _, _ -> :ok end)
      stub(Tracks, :mark_read, fn _, _, _thread_opts -> :ok end)
      stub(Tracks, :files, fn _, _, _ -> {:error, {:unavailable, "no machine"}} end)

      {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{one.id}")
      render_async(parent)
      child = find_live_child(parent, "track-host")
      render_async(child)

      %{user: user, project: project, one: one, two: two, parent: parent, child: child}
    end

    test "the page moves to the next track rather than being rebuilt for it", ctx do
      assert render(ctx.child) =~ "First track"
      was = ctx.child.pid
      test_pid = self()

      # Held open so that what the page draws *before* the new track's detail
      # answers is what the assertions below see. That is the whole point of
      # the hand-over: the rail already knows this track's title and branch,
      # so a switch costs no Fountain round trip before something correct is
      # on the screen.
      stub(Tracks, :get, fn _user, id, _opts ->
        send(test_pid, {:reading_detail, self()})

        receive do
          :release_detail -> :ok
        after
          5_000 -> flunk("the detail read was never released")
        end

        row = Repo.get!(Ravix.Tracks.Track, id)

        {:ok,
         %{
           track: Tracks.present(row),
           header: blank_header(),
           threads: [],
           starters: [],
           models: []
         }}
      end)

      render_patch(ctx.parent, "/p/#{ctx.project.id}/t/#{ctx.two.id}")
      assert_receive {:reading_detail, reader}, 5_000

      # Same process: no join, no second access check, no `allow_upload/3`,
      # and nothing thrown away that belonged to the person rather than the
      # track.
      assert find_live_child(ctx.parent, "track-host").pid == was

      html = render(ctx.child)
      assert html =~ "Second track"
      refute html =~ "First track"
      assert html =~ ctx.two.branch

      send(reader, :release_detail)
      render_async(ctx.child)
      assert render(ctx.child) =~ "Second track"
    end

    test "the transcript starts over for the track arrived at", ctx do
      # The scroll container keeps its id across a switch now, so `data-track`
      # is what tells the hook it is somewhere new and should pin to the
      # bottom again. Without it a reader who had scrolled up in one track
      # would land part-way up the next.
      assert has_element?(ctx.child, ~s{#transcript-scroll[data-track="#{ctx.one.id}"]})

      render_patch(ctx.parent, "/p/#{ctx.project.id}/t/#{ctx.two.id}")
      render_async(ctx.child)

      assert has_element?(ctx.child, ~s{#transcript-scroll[data-track="#{ctx.two.id}"]})
    end

    test "a track this person cannot reach is refused before anything is read", ctx do
      other = insert_user()
      elsewhere = insert_project(user: other)
      theirs = insert_track(project: elsewhere, title: "Not yours")
      test_pid = self()

      # Nothing may answer, so that the refusal can only have come from the
      # page's own check. The `:track_async_access` hook would catch a result
      # for a track this person lost --- that is its job --- but catching it
      # *there* means the read was made and the hand-over's track was already
      # assigned, which is somebody else's title, branch and worktree drawn on
      # the screen for as long as Fountain took.
      stub(Tracks, :get, fn _user, id, _opts ->
        send(test_pid, {:read_attempted, id})
        Process.sleep(:infinity)
      end)

      # Sent straight to the page, because the question is what *it* does with
      # a hand-over it should not honour. The rail only ever offers tracks it
      # read for this person, but a hand-over is a message like any other, and
      # a page that took one on trust would draw whatever sent it.
      {:ok, their_project} = Ravix.Projects.get(other, elsewhere.id)
      send(ctx.child.pid, {:select_track, their_project, Tracks.present(theirs)})

      # A nested page's redirect surfaces on the page that hosts it.
      assert_redirect(ctx.parent, "/", 1_000)
      refute_receive {:read_attempted, _}, 200
    end
  end

  describe "the yard on a phone" do
    setup %{conn: conn} do
      user = insert_user()
      project = insert_project(user: user, name: "Pocket work")
      {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
      render_async(view)
      %{view: view, project: project}
    end

    test "the menu opens it over the page and says so to assistive technology", ctx do
      menu = "nav.workspace-mobile-nav button[aria-controls=yard]"
      refute has_element?(ctx.view, "aside#yard.forced")
      assert has_element?(ctx.view, "#{menu}[aria-expanded=false]")
      refute has_element?(ctx.view, ".yard-scrim")

      ctx.view |> element(menu) |> render_click()
      assert has_element?(ctx.view, "aside#yard.forced")
      assert has_element?(ctx.view, "#{menu}[aria-expanded=true]")
      # Everything the yard holds is now reachable on a phone, which it was
      # not: the rail was `display: none` under the breakpoint and nothing
      # set the class that shows it.
      assert has_element?(
               ctx.view,
               "#yard.forced #account-menu a[href='/auth/signout']",
               "Sign out"
             )

      assert has_element?(
               ctx.view,
               "#yard.forced button[aria-label='Project settings for Pocket work']"
             )

      assert has_element?(ctx.view, "#yard.forced button.yard-close[aria-label='Close menu']")

      # And the same button closes it again.
      ctx.view |> element(menu) |> render_click()
      refute has_element?(ctx.view, "aside#yard.forced")
    end

    test "the x, Escape and the scrim each close it", ctx do
      for close <- [
            fn v -> v |> element("#yard button.yard-close") |> render_click() end,
            fn v -> v |> element(".yard-scrim") |> render_keydown(%{"key" => "Escape"}) end,
            fn v -> v |> element(".yard-scrim") |> render_click() end
          ] do
        render_click(ctx.view, "yard")
        assert has_element?(ctx.view, "aside#yard.forced")
        close.(ctx.view)
        refute has_element?(ctx.view, "aside#yard.forced")
        # Escape is only listened for while the yard is open; the listener
        # is on the scrim, and the scrim only exists then.
        refute has_element?(ctx.view, "[phx-window-keydown=yard-close]")
      end
    end

    test "following a link in it closes it, because every link is a patch", ctx do
      render_click(ctx.view, "yard")
      assert has_element?(ctx.view, "aside#yard.forced")
      render_patch(ctx.view, "/inbox")
      refute has_element?(ctx.view, "aside#yard.forced")
      assert has_element?(ctx.view, "button[aria-controls=yard][aria-expanded=false]")
    end
  end

  describe "notices" do
    setup %{conn: conn} do
      user = insert_user()
      insert_project(user: user)
      {:ok, view, _} = live(log_in_user(conn, user), "/home")
      render_async(view)
      %{view: view}
    end

    test "a notice lets itself go; an error waits to be dismissed", ctx do
      # The timer is a message to this process, so the test delivers the
      # message rather than waiting out six seconds.
      send(ctx.view.pid, {:flash, :info, "Saved."})
      assert has_element?(ctx.view, "#flash-info", "Saved.")
      send(ctx.view.pid, {:clear_flash, :info, "Saved."})
      refute has_element?(ctx.view, "#flash-info")

      send(ctx.view.pid, {:flash, :error, "Could not save."})
      assert has_element?(ctx.view, "#flash-error", "Could not save.")
      send(ctx.view.pid, {:clear_flash, :error, "Could not save."})
      # No timer is ever set for an error; and even a stray clear would only
      # take a flash that still says what the clear names.
      refute has_element?(ctx.view, "#flash-error")
      send(ctx.view.pid, {:flash, :error, "Could not save."})
      send(ctx.view.pid, {:clear_flash, :error, "Something else"})
      assert has_element?(ctx.view, "#flash-error", "Could not save.")
    end

    test "a stale clear does not cut a newer notice short", ctx do
      send(ctx.view.pid, {:flash, :info, "First."})
      send(ctx.view.pid, {:flash, :info, "Second."})
      send(ctx.view.pid, {:clear_flash, :info, "First."})
      assert has_element?(ctx.view, "#flash-info", "Second.")
      send(ctx.view.pid, {:clear_flash, :info, "Second."})
      refute has_element?(ctx.view, "#flash-info")
    end
  end

  defp stub_track(track) do
    stub(Tracks, :get, fn _, _, _ ->
      {:ok,
       %{
         track: Tracks.present(track),
         header: blank_header(),
         threads: [],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, Transcript.empty("")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _thread_opts -> :ok end)

    stub(Tracks, :files, fn _, _, _ ->
      {:ok,
       %Files.Listing{
         path: track.workdir,
         truncated: false,
         entries: [%Files.Entry{name: "app.ex", type: "file", size: 10}]
       }}
    end)
  end

  # The ribbon a track with no repository and no setup script gets. A real
  # `Ravix.Tracks.Header` rather than `%{}`: the template reads a field off
  # it, and a stub that answers with an empty map is how a page renders
  # in a test and raises in production.
  defp blank_header,
    do: %Ravix.Tracks.Header{
      copy_of: nil,
      branched_from: nil,
      created: %{dir: "t", files: nil},
      has_setup_script: false
    }
end
