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
    {:ok, {[section], %{}}} = Sections.list(user, nil)
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()

    assert has_element?(
             view,
             "#new-section-form .error",
             "You already have a section called Work."
           )

    view |> form("#rename-section-#{section.id}", section: %{name: "Active"}) |> render_submit()
    # An empty section offers nothing to pick on Home.
    refute has_element?(view, "#home-section-#{section.id}")

    # Manage sections is where a project moves, with no pointer needed.
    view |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    assert {:ok, {[%{name: "Active"}], placements}} = Sections.list(user, nil)
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
    assert {:ok, {[_], %{}}} = Sections.list(user, nil)
    reloaded |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    {:ok, {[_], placements}} = Sections.list(user, nil)
    assert placements == %{project.id => section.id}
    render_click(reloaded, "delete-section", %{id: section.id})
    render_click(reloaded, "dismiss-switcher")
    refute has_element?(reloaded, "#home-section-#{section.id}")
    assert has_element?(reloaded, "#home-project-#{project.id} a[href='/p/#{project.id}']")
    assert has_element?(reloaded, "#home-project-#{other.id}")
  end

  # RAV-130: creating a section used to leave its name in the field, so the
  # next click made a duplicate, refused as a toast reading "name has already
  # been taken".
  test "creating a section empties its field and a taken name is refused under the field",
       %{conn: conn} do
    user = insert_user()
    _project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)
    view |> element("#manage-sections") |> render_click()
    # No browser history over either name field.
    assert has_element?(
             view,
             "#new-section-form[phx-hook=SectionForm] #section-name[autocomplete=off]"
           )

    view |> form("#new-section-form", section: %{name: "Ravioli"}) |> render_submit()
    {:ok, {[ravioli], %{}}} = Sections.list(user, nil)
    id = ravioli.id
    # The field is empty, the browser is told to empty and refocus it, and the
    # new section is pointed out in the dialog's list.
    refute has_element?(view, "#section-name[value]")
    assert_push_event(view, "section-created", %{id: ^id})

    assert has_element?(
             view,
             "#section-editor-#{id}.created #section-name-#{id}[autocomplete=off][value=Ravioli]"
           )

    # The same name again: a sentence under the field, the name kept there,
    # no toast, and nothing marked new.
    view |> form("#new-section-form", section: %{name: "Ravioli"}) |> render_submit()

    assert has_element?(
             view,
             "#new-section-form .error",
             "You already have a section called Ravioli."
           )

    assert has_element?(view, "#section-name[value=Ravioli]")
    refute render(view) =~ "already been taken"
    refute has_element?(view, ".created")
    refute_push_event(view, "section-created", %{})
    assert {:ok, {[_], %{}}} = Sections.list(user, nil)

    # A blank name is the changeset's other refusal, in the same place.
    view |> form("#new-section-form", section: %{name: "   "}) |> render_submit()
    assert has_element?(view, "#new-section-form .error", "can't be blank")

    # A name that goes through clears the refusal.
    view |> form("#new-section-form", section: %{name: "Pasta"}) |> render_submit()
    refute has_element?(view, "#new-section-form .error")
    {:ok, {sections, %{}}} = Sections.list(user, nil)
    pasta = Enum.find(sections, &(&1.name == "Pasta"))
    assert has_element?(view, "#section-editor-#{pasta.id}.created")
    refute has_element?(view, "#section-editor-#{id}.created")

    # Renaming to a taken name is refused in that section's own form, the
    # typed name kept, the other form untouched.
    view |> form("#rename-section-#{pasta.id}", section: %{name: "Ravioli"}) |> render_submit()

    assert has_element?(
             view,
             "#rename-section-#{pasta.id} .error",
             "You already have a section called Ravioli."
           )

    assert has_element?(view, "#section-name-#{pasta.id}[value=Ravioli]")
    refute has_element?(view, "#rename-section-#{id} .error")
    refute render(view) =~ "already been taken"
    refute has_element?(view, ".created")
    assert {:ok, {[%{name: "Pasta"}, %{name: "Ravioli"}], %{}}} = Sections.list(user, nil)

    # A rename that goes through replaces the refusal with the new name.
    view |> form("#rename-section-#{pasta.id}", section: %{name: "Lasagne"}) |> render_submit()
    refute has_element?(view, "#rename-section-#{pasta.id} .error")
    assert has_element?(view, "#section-name-#{pasta.id}[value=Lasagne]")

    # Reopening the dialog forgets a refusal and what was typed.
    view |> form("#new-section-form", section: %{name: "Lasagne"}) |> render_submit()
    assert has_element?(view, "#new-section-form .error")
    render_click(view, "dismiss-switcher")
    view |> element("#manage-sections") |> render_click()
    refute has_element?(view, "#new-section-form .error")
    refute has_element?(view, "#section-name[value]")
  end

  test "Home's section filters name each section with projects, and say which one is chosen",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Filed project")
    loose = insert_project(user: user, name: "Loose project")
    {:ok, work} = Sections.create(user, nil, %{name: "Work"})
    {:ok, empty} = Sections.create(user, nil, %{name: "Later"})
    {:ok, _} = Sections.move(user, nil, project.id, work.id)
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
    {:ok, section} = Sections.create(other, nil, %{name: "Private section"})
    {:ok, own} = Sections.create(user, nil, %{name: "Mine"})
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

    assert {:ok, {[^section], %{}}} = Sections.list(other, nil)
    assert {:ok, {[^own], %{}}} = Sections.list(user, nil)
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

    assert {:ok, {[], %{}}} = Sections.list(user, nil)
  end
end
