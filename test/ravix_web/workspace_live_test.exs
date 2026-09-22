defmodule RavixWeb.WorkspaceLiveTest do
  use RavixWeb.ConnCase, async: false
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

  test "a signed-out browser is sent to sign in from anywhere it lands", %{conn: conn} do
    for path <- ["/", "/home", "/inbox", "/p/no-project"] do
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, path)
    end
  end

  test "sign-in works without a configured backend", %{conn: conn} do
    {:ok, signin, _} = live(conn, "/login")
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
    assert has_element?(view, ".inbox-item", "Review this")
    assert has_element?(view, ".inbox-item", "Needs help")
    refute has_element?(view, ".inbox-item", "Still working")
    refute has_element?(view, ".inbox-empty")

    stub(Tracks, :list, fn _, _ ->
      {:ok, Enum.map(tracks, &struct!(&1, status: :ready, unread: false))}
    end)

    view |> element("button", "Refresh") |> render_click()
    # The refresh re-reads the rail in a task; the inbox is drawn from it.
    render_async(view)
    refute has_element?(view, ".inbox-item")
    assert has_element?(view, ".inbox-empty", "You're all caught up")
  end

  test "the rail and inbox are scoped to the signed-in user", %{conn: conn} do
    user = insert_user()
    own = insert_project(user: user, name: "My project")
    insert_project(name: "Someone else's project", user: insert_user())
    track = insert_track(project: own, title: "My work")
    {:ok, view, _} = live(log_in_user(conn, user), "/")
    assert has_element?(view, "a", "My project")
    assert has_element?(view, "a", "My work")
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
    assert has_element?(view, "#project-tracks-#{project.id}[hidden]")
    view |> element("button[phx-value-id='#{project.id}']") |> render_click()
    refute has_element?(view, "#project-tracks-#{project.id}[hidden]")
    view |> element("button[phx-value-id='#{project.id}']") |> render_click()
    assert has_element?(view, "#project-tracks-#{project.id}[hidden]")
    render_click(view, "toggle-project", %{id: "someone-elses-project"})
    refute render(view) =~ "someone-elses-project"
    view |> element("a.project-add") |> render_click()
    assert_patch(view, "/p/#{project.id}?new=track")
    assert has_element?(view, "#new-track-form")
    refute has_element?(view, "#project-tracks-#{project.id}[hidden]")
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

  test "a collapsed project stays collapsed across patches", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")

    # Arriving expands the group; collapsing it is the reader's decision and
    # the next patch must not undo it.
    refute has_element?(view, "#project-tracks-#{project.id}[hidden]")
    view |> element("button[phx-value-id='#{project.id}']") |> render_click()
    assert has_element?(view, "#project-tracks-#{project.id}[hidden]")

    render_click(view, "dismiss")
    assert_patch(view, "/p/#{project.id}/t/#{track.id}")
    assert has_element?(view, "#project-tracks-#{project.id}[hidden]")
  end

  test "hiding advanced options drops the origin they carried", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, repo: "owner/repo")
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?new=track")

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

  test "disclosure state reaches assistive technology as a string", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    insert_track(project: project)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")

    # A bare `aria-expanded` is invalid ARIA and reads as undefined, which is
    # what a raw boolean renders to in HEEx.
    assert has_element?(view, "button[aria-expanded='false'][phx-value-id='#{project.id}']")
    view |> element("button[phx-value-id='#{project.id}']") |> render_click()
    assert has_element?(view, "button[aria-expanded='true'][phx-value-id='#{project.id}']")
  end

  test "an empty inbox carries no count", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")

    assert render(view) =~ "You&#39;re all caught up"
    refute has_element?(view, "a.yard-item .badge")
  end

  test "track-only members cannot open project creation through a URL", %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    People.add_member(track.id, member.id, owner.id)
    {:ok, view, _} = live(log_in_user(conn, member), "/p/#{project.id}?new=track")
    refute has_element?(view, "#new-track-form")
    refute has_element?(view, "a.project-add")
    refute has_element?(view, "button", "New track")
  end

  test "a track URL cannot name a different project", %{conn: conn} do
    user = insert_user()
    one = insert_project(user: user)
    two = insert_project(user: user)
    track = insert_track(project: two)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(log_in_user(conn, user), "/p/#{one.id}/t/#{track.id}")
  end

  test "project creation calls the context and navigates to the new project", %{conn: conn} do
    user = insert_user()

    expect(Projects, :create, fn actual_user, attrs ->
      assert actual_user.id == user.id
      assert attrs["name"] == "New project"
      project = insert_project(user: user, name: attrs["name"])
      {:ok, %{id: project.id}}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/")
    view |> element(".workspace-actions button", "Add a project") |> render_click()

    view
    |> form("#new-project-form", new_project: [name: "New project", repo: ""])
    |> render_submit()

    render_async(view)
    assert has_element?(view, "a.workspace-project-name", "New project")
    assert render(view) =~ "Each track is its own worktree"
  end

  test "signing out somewhere else takes this page with it, without being poked", %{conn: conn} do
    user = insert_user()
    {token, _session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/")

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
    assert html =~ "Beta one"
    refute html =~ "Beta two"
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
      assert attrs["instructions"] == "Be precise"
      {:ok, %{rev: 2}}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    view |> element("button", "Settings") |> render_click()

    view
    |> form("#settings-form", settings: [instructions: "Be precise", apt: "git curl"])
    |> render_submit()

    assert render(view) =~ "Settings saved"
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

    stub(Tracks, :diff, fn _, _ ->
      {:ok,
       %Diff{
         path: "/workspace/app",
         repo_root: "/workspace/app",
         changes: [%Diff.Change{path: "app.ex", added: 1, removed: 0, status: :modified}],
         diff: "+hello change",
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
    child = find_live_child(parent, "track-host")
    render_async(child)
    child |> element("button", "app.ex") |> render_click()
    assert render(child) =~ "hello file"
    child |> element("button", "Changes") |> render_click()
    assert render_async(child) =~ "+hello change"
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
    child = find_live_child(parent, "track-host")
    render_async(child)
    child |> form("#composer-form", text: "Keep this draft") |> render_submit()
    assert render(child) =~ "Please try again"
    assert has_element?(child, "#composer-form")
    refute_push_event(child, "composer:clear", %{}, 50)
  end

  test "an uploaded image survives a failed prompt and is sent again on retry", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
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
        {:ok, %{track: Tracks.present(row), header: blank_header(), starters: []}}
      end)

      stub(Tracks, :events, fn _, _ -> {:ok, Transcript.empty("")} end)
      stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
      stub(Tracks, :beat, fn _, _, _ -> :ok end)
      stub(Tracks, :mark_read, fn _, _ -> :ok end)
      stub(Tracks, :files, fn _, _, _ -> {:error, {:unavailable, "no machine"}} end)

      {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{one.id}")
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
        {:ok, %{track: Tracks.present(row), header: blank_header(), starters: []}}
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

  defp stub_track(track) do
    stub(Tracks, :get, fn _, _, _ ->
      {:ok, %{track: Tracks.present(track), header: blank_header(), starters: []}}
    end)

    stub(Tracks, :events, fn _, _ -> {:ok, Transcript.empty("")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _ -> :ok end)

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
