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
    {:ok, {[section], %{}}} = Sections.list(user, nil)
    view |> form("#new-section-form", section: %{name: "Work"}) |> render_submit()

    assert has_element?(
             view,
             "#new-section-form .error",
             "You already have a section called Work."
           )

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

    assert has_element?(
             view,
             "#section-#{section.id} [phx-click=toggle-section][aria-expanded=true]"
           )

    view |> element("#section-#{section.id} .section-toggle") |> render_click()
    assert {:ok, {[%{collapsed: true}], _}} = Sections.list(user, nil)
    refute has_element?(view, "#section-#{section.id} .section-toggle[data-collapse]")
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: "SECTION") |> render_change()
    assert has_element?(view, "#search-dialog a[href='/p/#{project.id}']")
    view |> form("#search-form", q: "missing") |> render_change()
    assert has_element?(view, "#search-dialog", "No tracks match")
    {:ok, reloaded, _} = live(conn, "/p/#{project.id}")
    render_async(reloaded)
    assert has_element?(reloaded, "#section-projects-#{section.id}[hidden]")
    assert has_element?(reloaded, "#section-#{section.id} a[href='/p/#{project.id}']")
    reloaded |> element("#manage-sections") |> render_click()
    reloaded |> form("#move-project-#{project.id}", section: "") |> render_change()
    assert {:ok, {[_], %{}}} = Sections.list(user, nil)
    reloaded |> form("#move-project-#{project.id}", section: section.id) |> render_change()
    {:ok, {[_], placements}} = Sections.list(user, nil)
    assert placements == %{project.id => section.id}
    render_click(reloaded, "delete-section", %{id: section.id})
    render_click(reloaded, "dismiss-switcher")
    assert has_element?(reloaded, "#section-other a[href='/p/#{project.id}']")
    refute has_element?(reloaded, "#section-#{section.id}")
  end

  # RAV-130: creating a section used to leave its name in the field, so the
  # next click made a duplicate, refused as a toast reading "name has already
  # been taken".
  test "creating a section empties its field and a taken name is refused under the field",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
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
    # new section is pointed out in the dialog's list and in the sidebar.
    refute has_element?(view, "#section-name[value]")
    assert_push_event(view, "section-created", %{id: ^id})

    assert has_element?(
             view,
             "#section-editor-#{id}.created #section-name-#{id}[autocomplete=off][value=Ravioli]"
           )

    assert has_element?(view, "#section-#{id}.created .section-toggle", "Ravioli")

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

  test "sections label their projects, say when empty, and every disclosure follows its state",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user, name: "Filed project")
    {:ok, work} = Sections.create(user, nil, %{name: "Work"})
    {:ok, empty} = Sections.create(user, nil, %{name: "Later"})
    {:ok, _} = Sections.move(user, nil, project.id, work.id)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)

    # Manage sections is an icon button whose name and tooltip say what it is for.
    assert has_element?(
             view,
             "#manage-sections[aria-label='Manage sections'][data-tip='Organize projects into sections'] svg"
           )

    refute has_element?(view, "#manage-sections", "Manage sections")

    # Every labelled group indents its projects; each disclosure's chevron sits
    # in the button whose aria-expanded turns it.
    assert has_element?(view, "#section-#{work.id}.labelled")
    toggle = "#section-#{work.id} > .section-toggle"
    assert has_element?(view, "#{toggle}[aria-expanded=true] > svg.disclosure-chevron")
    project_toggle = "#project-row-#{project.id} .project-collapse"

    assert has_element?(
             view,
             "#{project_toggle}[data-collapse='#{project.id}'][aria-expanded=true][aria-controls='project-tracks-#{project.id}'] > svg.disclosure-chevron"
           )

    # The icon draws no direction of its own, so the attribute alone decides it.
    refute render(element(view, "#{project_toggle} svg")) =~ "rotate"

    view |> element(toggle) |> render_click()
    assert has_element?(view, "#{toggle}[aria-expanded=false] > svg.disclosure-chevron")
    assert has_element?(view, "#section-projects-#{work.id}[hidden]")
    # Collapsing one section hides only its own contents.
    refute has_element?(view, "#section-projects-#{empty.id}[hidden]")
    refute has_element?(view, "#section-projects-other[hidden]")
    view |> element(toggle) |> render_click()
    assert has_element?(view, "#{toggle}[aria-expanded=true]")
    refute has_element?(view, "#section-projects-#{work.id}[hidden]")

    # An empty section says so, muted, rather than a chevron over nothing,
    # and stays a place to drag a project to.
    assert has_element?(
             view,
             "#section-#{empty.id}[data-section-drop='#{empty.id}'] #section-empty-#{empty.id}.dim",
             "No projects"
           )

    refute has_element?(view, "#section-#{work.id} .section-empty")
  end

  test "unsectioned projects alone have no label, no indent and no empty line", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    assert has_element?(view, "#section-other a[href='/p/#{project.id}']")
    refute has_element?(view, "#section-other.labelled")
    refute has_element?(view, "#section-other .section-toggle")
    refute has_element?(view, ".section-empty")

    assert has_element?(
             view,
             "#project-row-#{project.id} .project-collapse > .disclosure-chevron"
           )
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
