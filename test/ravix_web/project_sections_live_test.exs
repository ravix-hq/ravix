defmodule RavixWeb.ProjectSectionsLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Ravix.Projects.Sections
  alias Ravix.Repo
  alias RavixWeb.Live.Guard

  test "create, move, filter Home by section, search, reload, rename and remove sections", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user, name: "Section project")
    other = insert_project(user: user, name: "Loose project")
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/home")
    render_async(view)
    assert has_element?(view, "#home-project-#{project.id} a[href='/p/#{project.id}']")
    # With one group there is nothing to choose between.
    refute has_element?(view, "#home-section-other")
    view |> element("#manage-sections") |> render_click()
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()
    {[section], %{}} = Sections.list(user)
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()
    assert render(view) =~ "has already been taken"
    view |> form("#rename-section-#{section.id}", section: %{name: "Active"}) |> render_submit()
    # An empty section offers nothing to pick on Home.
    refute has_element?(view, "#home-section-#{section.id}")

    # Manage sections is where a project moves, with no pointer needed.
    view |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    assert {[%{name: "Active"}], placements} = Sections.list(user)
    assert placements == %{project.id => section.id}
    render_click(view, "dismiss-switcher")
    assert has_element?(view, "#home-section-#{section.id}[aria-pressed=false]", "Active")
    assert has_element?(view, "#home-section-other", "Other projects")
    # Named sections come before Other projects.
    [_, after_section] = String.split(render(view), ~s(id="home-section-#{section.id}"), parts: 2)
    assert after_section =~ ~s(id="home-section-other")

    view |> element("#home-section-#{section.id}") |> render_click()
    assert has_element?(view, "#home-section-#{section.id}[aria-pressed=true]")
    assert has_element?(view, "#home-section-all[aria-pressed=false]")
    assert has_element?(view, "#home-project-#{project.id}")
    refute has_element?(view, "#home-project-#{other.id}")
    view |> element("#home-section-other") |> render_click()
    refute has_element?(view, "#home-project-#{project.id}")
    assert has_element?(view, "#home-project-#{other.id}")
    view |> element("#home-section-all") |> render_click()
    assert has_element?(view, "#home-project-#{project.id}")
    assert has_element?(view, "#home-project-#{other.id}")

    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: "SECTION") |> render_change()
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}']")
    view |> form("#search-form", q: "missing") |> render_change()
    assert has_element?(view, "#search-dialog", "No tracks match")
    {:ok, reloaded, _} = live(conn, "/home")
    render_async(reloaded)
    # The placement outlives the page: the section still holds one project.
    assert has_element?(reloaded, "#home-section-#{section.id} small", "1")
    assert has_element?(reloaded, "#home-section-other small", "1")
    reloaded |> element("#manage-sections") |> render_click()
    reloaded |> form("#move-project-#{project.id}", section: "") |> render_change()
    assert {[_], %{}} = Sections.list(user)
    reloaded |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    {[_], placements} = Sections.list(user)
    assert placements == %{project.id => section.id}
    render_click(reloaded, "delete-section", %{id: section.id})
    render_click(reloaded, "dismiss-switcher")
    refute has_element?(reloaded, "#home-section-#{section.id}")
    assert has_element?(reloaded, "#home-project-#{project.id} a[href='/p/#{project.id}']")
    assert has_element?(reloaded, "#home-project-#{other.id}")
  end

  test "Home's section filters name each section with projects, and say which one is chosen",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Filed project")
    loose = insert_project(user: user, name: "Loose project")
    {:ok, work} = Sections.create(user, %{name: "Work"})
    {:ok, empty} = Sections.create(user, %{name: "Later"})
    {:ok, _} = Sections.move(user, project.id, work.id)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)

    assert has_element?(view, "#manage-sections[phx-value-name=sections]", "Manage sections")
    assert has_element?(view, "#home-section-all[aria-pressed=true]", "All projects")
    assert has_element?(view, "#home-section-#{work.id}[aria-pressed=false]", "Work")
    assert has_element?(view, "#home-section-#{work.id} small", "1")
    # With named sections, the rest are labelled Other projects.
    assert has_element?(view, "#home-section-other", "Other projects")
    # An empty section is not offered as a filter; it still exists to manage.
    refute has_element?(view, "#home-section-#{empty.id}")

    view |> element("#home-section-#{work.id}") |> render_click()
    assert has_element?(view, "#home-section-#{work.id}[aria-pressed=true]")
    assert has_element?(view, "#home-section-all[aria-pressed=false]")
    assert has_element?(view, "#home-project-#{project.id}")
    refute has_element?(view, "#home-project-#{loose.id}")

    view |> element("#manage-sections") |> render_click()
    assert has_element?(view, "#rename-section-#{empty.id}")
    assert has_element?(view, "#project-section-#{project.id} option[selected]", "Work")
  end

  test "unsectioned projects alone have no section filters", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    assert has_element?(view, "#home-project-#{project.id} a[href='/p/#{project.id}']")
    assert has_element?(view, "#home-section-all[aria-pressed=true]")
    refute has_element?(view, "#home-section-other")
    refute has_element?(view, "#home-projects .hint", "No projects in this section.")
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
