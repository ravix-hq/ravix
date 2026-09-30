defmodule RavixWeb.ProjectTreeLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Fountain, Hub, Tracks}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.People.Store, as: People

  setup :verify_on_exit!

  test "owned, member and track-only projects have scoped counts and patch navigation", %{
    conn: conn
  } do
    user = insert_user()
    owned = insert_project(user: user, name: "Owned")
    member = insert_project(name: "Member")
    shared = insert_project(name: "Shared")
    foreign = insert_project(name: "Never visible")
    insert_project_member(member, user)

    rows =
      for project <- [owned, member, shared, shared] do
        insert_track(
          project: project,
          conversation_id: Ecto.UUID.generate(),
          opened_at: DateTime.utc_now()
        )
      end

    [_, _, visible, hidden] = rows
    creator = insert_user()

    for project <- [owned, member] do
      insert_track(
        project: project,
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: creator.id,
        title: "Private omitted #{project.id}"
      )
    end

    insert_track_member(visible, user)

    client =
      FakeTransport.client(
        for project <- [owned, member, shared] do
          data =
            for row <- rows, row.project_id == project.id do
              %{
                id: row.conversation_id,
                status: "idle",
                last_active_at: "2026-09-27T00:00:00Z",
                sandbox_id: "sandbox"
              }
            end

          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [], %{data: data}}}
        end
      )

    stub(Fountain, :client, fn -> client end)
    {:ok, view, _} = live(log_in_user(conn, user), "/inbox")
    render_async(view, 5_000)
    assert has_element?(view, "#yard .workspace-project")
    view |> element("#quick-jump-trigger") |> render_click()

    view |> form("#search-form", q: hidden.title) |> render_change()
    refute has_element?(view, "#search-dialog a[href='/p/#{shared.id}/t/#{hidden.id}']")
    assert has_element?(view, "#search-dialog", "No projects, tracks or plans match")
    view |> form("#search-form", q: visible.title) |> render_change()
    assert has_element?(view, "#search-dialog a[href='/p/#{shared.id}/t/#{visible.id}']")
    view |> form("#search-form", q: "") |> render_change()

    for project <- [owned, member, shared] do
      assert has_element?(view, "#search-dialog a[href='/p/#{project.id}'] .badge", "1")
    end

    refute render(view) =~ "Private omitted"
    refute render(view) =~ foreign.name
    refute render(view) =~ hidden.title
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "3")
    view |> element("#search-dialog a[href='/p/#{shared.id}']") |> render_click()
    assert_patch(view, "/p/#{shared.id}")
    refute has_element?(view, "#search-dialog")
    assert has_element?(view, ".track-tab", visible.title)
    refute render(view) =~ hidden.title
    refute has_element?(view, ".project-actions button")
    refute has_element?(view, "[data-project-id='#{shared.id}'] a.project-add")
    assert has_element?(view, "[data-project-id='#{member.id}'] a.project-add")
    assert has_element?(view, "[data-project-id='#{owned.id}'] a.project-add")
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "3")
    render_patch(view, "/schedules")
    view |> element("#mobile-quick-jump-trigger") |> render_click()
    assert has_element?(view, "#search-dialog a[href='/p/#{shared.id}'] .badge", "1")
    assert has_element?(view, ".workspace-mobile-nav a[href='/schedules']")
    render_patch(view, "/p/#{foreign.id}")
    assert_patch(view, "/home")
    refute render(view) =~ "Private omitted"
    refute render(view) =~ foreign.name
    render_patch(view, "/p/#{shared.id}/t/#{hidden.id}")
    assert_patch(view, "/p/#{shared.id}")
    refute render(view) =~ hidden.title
  end

  test "private tracks appear only for their creator and invitees in tree, counts and search", %{
    conn: conn
  } do
    owner = insert_user()
    creator = insert_user()
    invitee = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, creator)
    insert_project_member(project, member)

    track =
      insert_track(
        project: project,
        title: "Secret work",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: creator.id
      )

    insert_track_member(track, invitee)
    # Presentation supplies activity, while the real bulk Access query decides visibility.
    stub(Tracks, :list_many, fn user, ids, _opts ->
      Ravix.Accounts.Access.open_tracks(user, ids)
      |> Enum.group_by(fn {_row, project} -> project.id end, fn {row, _} ->
        %{Tracks.present(row) | status: :ready, unread: true}
      end)
    end)

    for {viewer, visible?} <- [{owner, false}, {member, false}, {creator, true}, {invitee, true}] do
      {:ok, view, _} = live(log_in_user(conn, viewer), "/home")
      render_async(view, 5_000)
      assert has_element?(view, "#project-track-tab-#{track.id}") == visible?
      assert has_element?(view, "#project-link-#{project.id} .badge", "1") == visible?
      assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "1") == visible?
      render_click(view, "dialog", %{name: "search"})
      view |> form("#search-form", q: "Secret work") |> render_change()

      assert has_element?(view, "#search-dialog a[href='/p/#{project.id}/t/#{track.id}']") ==
               visible?

      view |> form("#search-form", q: "") |> render_change()

      assert has_element?(view, "#search-dialog a[href='/p/#{project.id}'] .badge", "1") ==
               visible?

      unless visible?, do: refute(render(view) =~ "Secret work")
      GenServer.stop(view.pid)
    end
  end

  test "a removed creator loses private rows, badges and quick-jump results", %{conn: conn} do
    creator = insert_user()
    insert_project(user: creator)
    project = insert_project()
    insert_project_member(project, creator)

    track =
      insert_track(
        project: project,
        created_by: creator.id,
        visibility: :private,
        sandbox_layout: :dedicated,
        title: "Revoked creator private work",
        conversation_id: Ecto.UUID.generate(),
        opened_at: DateTime.utc_now()
      )

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [],
          %{
            data: [
              %{
                id: track.conversation_id,
                status: "idle",
                last_active_at: "2026-09-28T00:00:00Z",
                sandbox_id: "sandbox"
              }
            ]
          }}}
      ])

    stub(Fountain, :client, fn -> client end)
    {:ok, view, _} = live(log_in_user(conn, creator), "/home")
    render_async(view, 5_000)
    assert has_element?(view, "#project-track-tab-#{track.id}")
    assert has_element?(view, "#project-link-#{project.id} .badge", "1")
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-track-link-#{track.id}")

    People.remove_project_member(project.id, creator.id)
    render_async(view, 5_000)
    assert Ravix.Repo.get!(Ravix.Tracks.Track, track.id).creator_revoked_at
    refute has_element?(view, "#project-link-#{project.id}")
    refute render(view) =~ track.title
    refute has_element?(view, ".yard-nav a[href='/inbox'] .badge")

    # Returning to the project does not silently restore revoked creator rights.
    insert_project_member(project, creator)
    render_click(view, "refresh")
    render_async(view, 5_000)
    assert has_element?(view, "#project-link-#{project.id}")
    refute has_element?(view, "#project-track-tab-#{track.id}")
    refute has_element?(view, "#project-link-#{project.id} .badge")
    refute has_element?(view, ".yard-nav a[href='/inbox'] .badge")
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: track.title) |> render_change()
    refute has_element?(view, "#search-track-link-#{track.id}")
    assert has_element?(view, "#search-dialog", "No projects, tracks or plans match")
    view |> form("#search-form", q: "") |> render_change()
    refute has_element?(view, "#search-dialog a[href='/p/#{project.id}'] .badge")
  end

  test "a failed project offers scoped retry and recovers without reloading other projects", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)
    other = insert_project(user: user)
    track = insert_track(project: project)

    stub(Tracks, :list_many, fn _, _, _ ->
      %{project.id => {:error, :unavailable}, other.id => []}
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 5_000)
    panel = "#project-tracks-#{project.id}"
    assert has_element?(view, panel, "Couldn't load tracks")
    refute has_element?(view, panel, "No open tracks")
    assert has_element?(view, "#project-tracks-#{other.id}", "No open tracks")
    render_click(view, "dialog", %{name: "search"})
    render_click(view, "dismiss")
    assert has_element?(view, panel, "Couldn't load tracks")

    parent = self()

    expect(Tracks, :list, fn ^user, id, [fresh: true] ->
      assert id == project.id
      send(parent, {:retry_started, self()})
      receive do: (:finish -> {:error, :not_found})
    end)

    view |> element(panel <> " button", "Retry") |> render_click()
    assert_receive {:retry_started, worker}
    assert has_element?(view, panel <> " button[disabled]", "Retrying…")
    render_click(view, "retry-tracks", %{id: project.id})
    refute_receive {:retry_started, _}
    send(worker, :finish)
    render_async(view, 5_000)
    assert has_element?(view, panel, "Couldn't load tracks")
    assert has_element?(view, panel <> " button:not([disabled])", "Retry")

    expect(Tracks, :list, fn ^user, id, [fresh: true] ->
      assert id == project.id
      {:ok, [Tracks.present(track)]}
    end)

    view |> element(panel <> " button", "Retry") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#project-track-tab-#{track.id}")
    refute has_element?(view, panel, "Couldn't load tracks")
    render_click(view, "retry-tracks", %{id: insert_project().id})
  end

  test "new-track action on the current project preserves the selected track", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)
    path = "/p/#{project.id}/t/#{track.id}"
    {:ok, view, _} = live(log_in_user(conn, user), path)
    render_async(view)
    child = find_live_child(view, "track-host")
    view |> element("#new-track-#{project.id}") |> render_click()
    assert_patch(view, path <> "?new=track")
    assert has_element?(view, "#new-track-dialog")
    assert find_live_child(view, "track-host").pid == child.pid
    view |> element("#new-track-dialog button[aria-label=Close]") |> render_click()
    assert_patch(view, path)
    refute has_element?(view, "#new-track-dialog")
    assert find_live_child(view, "track-host").pid == child.pid
  end

  test "membership removal drops projects while the quick-jump is open", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    member = insert_project(name: "Revoked project membership")
    shared = insert_project(name: "Revoked track membership")
    track = insert_track(project: shared)
    insert_project_member(member, user)
    insert_track_member(track, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-dialog a[href='/p/#{member.id}']")
    assert has_element?(view, "#search-dialog a[href='/p/#{shared.id}']")
    People.remove_project_member(member.id, user.id)
    People.remove_member(track.id, user.id)
    Hub.publish(member.id, :people)
    Hub.publish(shared.id, :people)
    render_async(view, 5_000)
    refute has_element?(view, "#project-link-#{member.id}")
    refute has_element?(view, "#search-project-link-#{member.id}")
    refute render(view) =~ member.name
    refute render(view) =~ shared.name
  end

  test "search and URL patches recheck membership even without a hub message", %{conn: conn} do
    user = insert_user()
    project = insert_project()
    membership = insert_project_member(project, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "search"})
    Ravix.Repo.delete!(membership)
    view |> form("#search-form", q: project.name) |> render_change()
    refute has_element?(view, "#search-dialog a[href='/p/#{project.id}']")
    render_patch(view, "/p/#{project.id}")
    assert_patch(view, "/home")
    refute has_element?(view, ".workspace-project")
  end

  test "a late turn result cannot restore revoked tracks or unread counts", %{conn: conn} do
    user = insert_user()
    project = insert_project()
    kept = insert_track(project: project)
    removed = insert_track(project: project)
    membership = insert_project_member(project, user)
    insert_track_member(kept, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view, 5_000)
    parent = self()

    expect(Tracks, :list, fn _, _, _ ->
      send(parent, {:reading, self()})

      receive do: (:finish ->
                     {:ok,
                      for(
                        row <- [kept, removed],
                        do: %{Tracks.present(row) | status: :ready, unread: true}
                      )})
    end)

    Hub.publish(project.id, :turn)
    assert_receive {:reading, worker}
    Ravix.Repo.delete!(membership)
    send(worker, :finish)
    render_async(view, 5_000)
    refute render(view) =~ removed.title
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}'] .badge", "1")
  end

  test "a late turn result cannot restore newly private tracks for a project member", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project()
    kept = insert_track(project: project)
    removed = insert_track(project: project)
    insert_project_member(project, user)
    insert_track_member(kept, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view, 5_000)
    parent = self()

    expect(Tracks, :list, fn _, _, _ ->
      send(parent, {:reading, self()})

      receive do: (:finish ->
                     {:ok,
                      for(
                        row <- [kept, removed],
                        do: %{Tracks.present(row) | status: :ready, unread: true}
                      )})
    end)

    Hub.publish(project.id, :turn)
    assert_receive {:reading, worker}

    removed
    |> Ecto.Changeset.change(visibility: :private, sandbox_layout: :dedicated)
    |> Ravix.Repo.update!()

    send(worker, :finish)
    render_async(view, 5_000)
    refute render(view) =~ removed.title
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}'] .badge", "1")
  end

  test "revoking a session closes an open quick-jump and redirects to sign in", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {token, session} = insert_session(user)
    {:ok, view, _} = live(Plug.Test.init_test_session(conn, session_token: token), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}']")
    Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login")
  end
end
