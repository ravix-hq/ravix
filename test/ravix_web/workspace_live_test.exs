defmodule RavixWeb.WorkspaceLiveTest do
  use RavixWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, Crypto, Hub, Projects, Tracks}
  alias Ravix.Tracks.Transcript

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
    view |> form("#new-project-form", name: "Abandoned name") |> render_change()
    render_click(view, "dismiss")
    view |> element(".home-action", "Quick start") |> render_click()
    assert has_element?(view, "#project-name[value='']")
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
        row |> Tracks.present(project: project) |> Map.merge(%{status: status, unread: true})
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
      {:ok, Enum.map(tracks, &Map.merge(&1, %{status: :ready, unread: false}))}
    end)

    view |> element("button", "Refresh") |> render_click()
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
    view |> form("#new-track-form", title: "Keep this name") |> render_change()
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
    Ravix.People.add_member(track.id, member.id, owner.id)
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
    view |> form("#new-project-form", name: "New project", repo: "") |> render_submit()
    render_async(view)
    assert has_element?(view, "a.workspace-project-name", "New project")
    assert render(view) =~ "Each track is its own worktree"
  end

  test "expired sessions cannot mutate through an already connected page", %{conn: conn} do
    user = insert_user()
    {token, _session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, session_token: token)
    {:ok, view, _} = live(conn, "/")
    Accounts.end_session(Crypto.sha256(token))

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "dialog", %{name: "new-project"})
  end

  test "removed project membership clears the rail on a hub notification", %{conn: conn} do
    owner = insert_user()
    user = insert_user()
    project = insert_project(user: owner)
    Ravix.People.add_project_member(project.id, user.id, owner.id)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    refute has_element?(view, "button", "Settings")
    Ravix.People.remove_project_member(project.id, user.id)
    Hub.publish(project.id, "people")
    refute render(view) =~ project.name
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
    child = find_live_child(parent, "track-#{track.id}")
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
    Ravix.People.add_member(track.id, user.id, owner.id)
    stub_track(track)
    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    child = find_live_child(parent, "track-#{track.id}")
    render_async(child)
    Ravix.People.remove_member(track.id, user.id)
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
      catalog: nil
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
    view |> form("#settings-form", instructions: "Be precise", apt: "git curl") |> render_submit()
    assert render(view) =~ "Settings saved"
  end

  test "file, diff, check, and preview panels consume their context shapes", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation-test")
    stub_track(track)

    stub(Tracks, :file, fn _, _, _ ->
      {:ok,
       %{path: "app.ex", content: "hello file", encoding: "utf-8", size: 10, truncated: false}}
    end)

    stub(Tracks, :diff, fn _, _ ->
      {:ok,
       %{
         files: [%{path: "app.ex", added: 1, removed: 0}],
         diff: "+hello change",
         truncated: false
       }}
    end)

    stub(Tracks, :checks, fn _, _ ->
      {:ok,
       %{
         pull: nil,
         pushed: true,
         runs: [
           %{
             name: "CI passed",
             status: "completed",
             conclusion: "success",
             url: "https://example.test/check"
           }
         ]
       }}
    end)

    stub(Ravix.Previews, :status, fn _, _ ->
      {:ok,
       %{
         state: :stopped,
         available: true,
         unavailable_reason: nil,
         config: nil,
         logs: "",
         url: nil
       }}
    end)

    {:ok, parent, _} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    child = find_live_child(parent, "track-#{track.id}")
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
    child = find_live_child(parent, "track-#{track.id}")
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
    child = find_live_child(parent, "track-#{track.id}")
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

    expect(Ravix.Previews, :act, fn actual_user, "track-id", "open", %{session_hash: hash} ->
      assert actual_user.id == user.id
      assert byte_size(hash) > 0
      {:ok, %{open_url: "https://track.preview.example/__ravix/open#ticket"}}
    end)

    conn = conn |> log_in_user(user) |> get("/preview/track-id")
    assert redirected_to(conn) == "https://track.preview.example/__ravix/open#ticket"
  end

  defp stub_track(track) do
    stub(Tracks, :get, fn _, _ ->
      {:ok, %{track: Tracks.present(track), header: %{}, starters: []}}
    end)

    stub(Tracks, :events, fn _, _ -> {:ok, Transcript.empty("")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _ -> :ok end)

    stub(Tracks, :files, fn _, _, _ ->
      {:ok,
       %{
         path: track.workdir,
         truncated: false,
         entries: [%{name: "app.ex", type: "file", size: 10}]
       }}
    end)
  end
end
