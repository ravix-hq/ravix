defmodule RavixWeb.ProjectSectionsLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Ravix.Projects.Sections
  alias Ravix.Repo
  alias RavixWeb.Live.Guard

  test "create, move, search collapsed groups, reload, rename and remove sections", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Section project")
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/p/#{project.id}")
    render_async(view)
    render_click(view, "dismiss-switcher")
    assert has_element?(view, "#section-other a[href='/p/#{project.id}']")
    refute has_element?(view, "#section-other .section-label")
    view |> element("#manage-sections") |> render_click()
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()
    {[section], %{}} = Sections.list(user)
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()
    assert render(view) =~ "has already been taken"
    view |> form("#rename-section-#{section.id}", section: %{name: "Active"}) |> render_submit()
    render_click(view, "dismiss-switcher")
    assert has_element?(view, ".section-toggle", "Active")
    [_, after_section] = String.split(render(view), ~s(id="section-#{section.id}"), parts: 2)
    assert after_section =~ ~s(id="section-other")
    refute has_element?(view, "#project-sections select")

    view
    |> element("#project-sections")
    |> render_hook("move-project", %{project: project.id, section: section.id})

    assert has_element?(view, "#section-#{section.id} a[href='/p/#{project.id}']")
    assert has_element?(view, "#section-#{section.id} [data-collapse][aria-expanded=true]")
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: "SECTION") |> render_change()
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}']")
    view |> form("#search-form", q: "missing") |> render_change()
    assert has_element?(view, "#search-dialog", "No projects or tracks match")
    {:ok, reloaded, _} = live(conn, "/p/#{project.id}")
    render_async(reloaded)
    assert has_element?(reloaded, "#section-#{section.id} a[href='/p/#{project.id}']")
    reloaded |> element("#manage-sections") |> render_click()
    reloaded |> form("#move-project-#{project.id}", section: "") |> render_change()
    assert {[_], %{}} = Sections.list(user)
    reloaded |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    {[_], placements} = Sections.list(user)
    assert placements == %{project.id => section.id}
    render_click(reloaded, "delete-section", %{id: section.id})
    render_click(reloaded, "dismiss-switcher")
    assert has_element?(reloaded, "#section-other a[href='/p/#{project.id}']")
    refute has_element?(reloaded, "#section-#{section.id}")
  end

  test "forged section and project ids cannot change another person's layout", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    other = insert_user()
    foreign = insert_project(user: other)
    {:ok, section} = Sections.create(other, %{name: "Private section"})
    {:ok, own} = Sections.create(user, %{name: "Mine"})
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    refute render(view) =~ "Private section"

    for {event, params} <- [
          {"rename-section", %{section_id: section.id, section: %{name: "Changed"}}},
          {"toggle-section", %{id: section.id, collapsed: "true"}},
          {"delete-section", %{id: section.id}},
          {"move-project", %{project: project.id, section: section.id}},
          {"move-project", %{project: foreign.id, section: own.id}}
        ] do
      assert render_click(view, event, params) =~ "No such thing here."
    end

    assert {[^section], %{}} = Sections.list(other)
    assert {[^own], %{}} = Sections.list(user)
  end

  test "expired sessions cannot create a section", %{conn: conn} do
    user = insert_user()
    insert_project(user: user)
    {token, session} = insert_session(user)
    {:ok, view, _} = live(Plug.Test.init_test_session(conn, session_token: token), "/home")
    # Test revocation at the event boundary, after mount's async rail settles.
    render_async(view, 5_000)
    Repo.delete!(session)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.session_guard, fn guard ->
        %{guard | verified_at_ms: guard.verified_at_ms - Guard.ttl_ms() - 1}
      end)
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "create-section", %{section: %{name: "Denied"}})

    assert {[], %{}} = Sections.list(user)
  end
end
