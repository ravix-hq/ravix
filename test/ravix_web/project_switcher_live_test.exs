defmodule RavixWeb.ProjectSwitcherLiveTest do
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
    refute has_element?(view, "#yard .workspace-project")
    view |> element("#project-switcher-trigger") |> render_click()

    for project <- [owned, member, shared] do
      assert has_element?(view, "#project-switcher a[href='/p/#{project.id}'] .badge", "1")
    end

    refute render(view) =~ foreign.name
    refute render(view) =~ hidden.title
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "3")
    view |> element("#project-switcher a[href='/p/#{shared.id}']") |> render_click()
    assert_patch(view, "/p/#{shared.id}")
    refute has_element?(view, "#project-switcher")
    assert has_element?(view, ".track-tab", visible.title)
    refute render(view) =~ hidden.title
    refute has_element?(view, ".project-actions button")
    refute has_element?(view, "a.project-add")
    assert has_element?(view, ".yard-nav a[href='/inbox'] .badge", "3")
    render_patch(view, "/schedules")
    view |> element("#mobile-project-switcher-trigger") |> render_click()
    assert has_element?(view, "#project-switcher a[href='/p/#{shared.id}'] .badge", "1")
    assert has_element?(view, ".workspace-mobile-nav a[href='/schedules']")
    render_patch(view, "/p/#{foreign.id}")
    assert_patch(view, "/home")
    refute render(view) =~ foreign.name
    render_patch(view, "/p/#{shared.id}/t/#{hidden.id}")
    assert_patch(view, "/p/#{shared.id}")
    refute render(view) =~ hidden.title
  end

  test "membership removal drops projects while the switcher is open", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    member = insert_project()
    shared = insert_project()
    track = insert_track(project: shared)
    insert_project_member(member, user)
    insert_track_member(track, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "projects"})
    assert has_element?(view, "#project-switcher a[href='/p/#{member.id}']")
    assert has_element?(view, "#project-switcher a[href='/p/#{shared.id}']")
    People.remove_project_member(member.id, user.id)
    People.remove_member(track.id, user.id)
    Hub.publish(member.id, :people)
    Hub.publish(shared.id, :people)
    render_async(view, 5_000)
    refute render(view) =~ member.name
    refute render(view) =~ shared.name
  end

  test "search and URL patches recheck membership even without a hub message", %{conn: conn} do
    user = insert_user()
    project = insert_project()
    membership = insert_project_member(project, user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "projects"})
    Ravix.Repo.delete!(membership)
    view |> form("#project-switcher-search", q: project.name) |> render_change()
    refute has_element?(view, "#project-switcher a[href='/p/#{project.id}']")
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
    render_click(view, "dialog", %{name: "projects"})
    assert has_element?(view, "#project-switcher a[href='/p/#{project.id}'] .badge", "1")
  end

  test "revoking a session closes an open switcher and redirects to sign in", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {token, session} = insert_session(user)
    {:ok, view, _} = live(Plug.Test.init_test_session(conn, session_token: token), "/home")
    render_async(view, 5_000)
    render_click(view, "dialog", %{name: "projects"})
    assert has_element?(view, "#project-switcher a[href='/p/#{project.id}']")
    Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login")
  end
end
