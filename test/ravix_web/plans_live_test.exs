defmodule RavixWeb.PlansLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Accounts, Plans, Repo}
  alias Ravix.Fountain.Client

  setup :verify_on_exit!

  setup do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: nil, installation_id: nil)
    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)

    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://fountain.test", "test-key")
    end)

    %{user: user, project: project}
  end

  test "create, edit, reorder, note, archive and restore a plan", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    view |> element("#plans-panel button", "New plan") |> render_click()
    html = render(view)
    [_, id] = Regex.run(~r/id="edit-title-([^"]+)"/, html)

    attrs = %{
      "title" => "Deliver",
      "summary" => "**Rationale** <script>bad()</script>",
      "items" => %{
        id => %{"title" => "First", "brief" => "Build API", "acceptance" => "Pass checks"}
      }
    }

    view |> form("#plan-editor", %{"plan" => attrs}) |> render_change()
    view |> element("#plan-editor button", "Add item") |> render_click()
    ids = Regex.scan(~r/id="edit-title-([^"]+)"/, render(view)) |> Enum.map(&List.last/1)
    second = List.last(ids)
    attrs = put_in(attrs, ["items", second], %{"title" => "Second", "brief" => "Build UI"})
    view |> form("#plan-editor", %{"plan" => attrs}) |> render_submit()
    {:ok, [plan]} = Plans.list(user, project.id)
    assert_patch(view, "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)
    assert has_element?(view, "#plans-panel h3", "Deliver")
    assert has_element?(view, "#plans-panel strong", "Rationale")
    refute has_element?(view, "#plans-panel script")
    view |> element("#plans-panel button", "Edit plan") |> render_click()

    view
    |> element("button[phx-value-id='#{second}'][phx-value-direction='up']")
    |> render_click()

    view |> form("#plan-editor") |> render_submit()
    render_async(view, 5_000)
    assert {:ok, %{items: [%{title: "Second"}, %{title: "First"}]}} = Plans.get(user, plan.id)
    view |> form("#note-#{id}", %{"body" => "Review carefully"}) |> render_submit()
    render_async(view, 5_000)
    assert has_element?(view, "#item-#{id}", "Review carefully")
    assert has_element?(view, "#item-#{id} .plan-note form#note-#{id}")
    refute has_element?(view, "form form")
    view |> element("#plans-panel button", "Archive plan") |> render_click()
    render_async(view, 5_000)
    refute has_element?(view, "button[form=plan-assign]")
    view |> element("#plans-panel button", "Restore plan") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "button[form=plan-assign]", "Assign selected items")
  end

  test "new plan navigation clears the old plan and cancel immediately restores the list", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, plan} = Plans.create(user, project.id, %{"title" => "Existing", "items" => []})
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)
    view |> element("#plans-panel button", "New plan") |> render_click()
    assert_patch(view, "/p/#{project.id}?new=plan")
    assert has_element?(view, "#plan-editor h3", "New plan")
    refute has_element?(view, "#plan-editor", "Assigned items")
    refute has_element?(view, "#plan-editor select")
    refute has_element?(view, "#plan-editor button", "Move up")
    refute has_element?(view, "#plan-editor button", "Move down")
    refute has_element?(view, "#plan-editor button", "Remove item")

    view |> element("#plan-editor button", "Cancel") |> render_click()
    assert_patch(view, "/p/#{project.id}")
    assert has_element?(view, ".plans-list a", "Existing")
    refute has_element?(view, "#plan-editor")

    # A hard load of the creation URL is also a blank draft.
    {:ok, fresh, _} = live(conn, "/p/#{project.id}?new=plan")
    assert has_element?(fresh, "#plan-editor h3", "New plan")
    fresh |> element("#plan-editor button", "Cancel") |> render_click()
    assert has_element?(fresh, ".plans-list a", "Existing")

    view |> element(".plans-list a", "Existing") |> render_click()
    render_async(view, 5_000)
    view |> element("#plans-panel button", "Edit plan") |> render_click()
    assert has_element?(view, "#plan-editor h3", "Edit plan")
    view |> element("#plan-editor button", "Cancel") |> render_click()
    assert has_element?(view, "#plans-panel h3", "Existing")
  end

  test "item controls follow position and removal clears obsolete dependencies", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?new=plan")
    [_, first] = Regex.run(~r/id="edit-title-([^"]+)"/, render(view))
    view |> element("#plan-editor button", "Add item") |> render_click()
    ids = Regex.scan(~r/id="edit-title-([^"]+)"/, render(view)) |> Enum.map(&List.last/1)
    second = List.last(ids)
    refute has_element?(view, "button[phx-value-id='#{first}'][phx-value-direction=up]")
    assert has_element?(view, "button[phx-value-id='#{first}'][phx-value-direction=down]")
    assert has_element?(view, "button[phx-value-id='#{second}'][phx-value-direction=up]")
    refute has_element?(view, "button[phx-value-id='#{second}'][phx-value-direction=down]")
    assert has_element?(view, "#edit-deps-#{first} option", "Untitled item")

    view
    |> form("#plan-editor", %{
      "plan" => %{
        "title" => "New work",
        "items" => %{
          first => %{"title" => "Keep", "dependencies" => [second]},
          second => %{"title" => "Remove"}
        }
      }
    })
    |> render_change()

    view |> element("button[phx-click=remove-item][phx-value-id='#{second}']") |> render_click()
    refute has_element?(view, "#plan-editor select")
    view |> form("#plan-editor") |> render_submit()
    render_async(view, 5_000)
    assert {:ok, [plan]} = Plans.list(user, project.id)
    assert {:ok, %{items: [%{title: "Keep", dependencies: []}]}} = Plans.get(user, plan.id)
  end

  test "a refused assignment does not spend the page's next request ID", %{
    conn: conn,
    user: user,
    project: project
  } do
    track = insert_track(project: project, conversation_id: "existing")

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Ordered",
        "items" => [
          %{"id" => "a", "title" => "A"},
          %{"id" => "b", "title" => "B", "dependencies" => ["a"]}
        ]
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)

    # The page disables blocked items; a crafted event still arrives.
    assert has_element?(view, "#blocked-b", "Blocked by: A")
    assert has_element?(view, "#item-b input[type=checkbox][disabled]")

    view
    |> element("#plan-assign")
    |> render_submit(%{"selected" => ["b"], "targets" => %{"b" => track.id}})

    assert render_async(view, 5_000) =~ "Complete dependencies"

    view
    |> form("#plan-assign", %{"selected" => ["a"], "targets" => %{"a" => track.id}})
    |> render_submit()

    render_async(view, 5_000)
    assert {:ok, %{items: [%{id: "a", track_id: id}, _]}} = Plans.get(user, plan.id)
    assert id == track.id
  end

  test "explicit multi-select assigns existing tracks and renders derived state", %{
    conn: conn,
    user: user,
    project: project
  } do
    track = insert_track(project: project, conversation_id: "existing")

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Assign work",
        "items" => [%{"id" => "a", "title" => "A"}, %{"id" => "b", "title" => "B"}]
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)
    assert has_element?(view, "#plan-assign", "owner's subscription")

    assert has_element?(view, ".plan-assign-actions [role=status]", "0 selected")
    assert has_element?(view, ".plan-assign-actions button[disabled]")

    view
    |> form("#plan-assign", %{"selected" => ["a"], "targets" => %{"a" => track.id}})
    |> render_change()

    assert has_element?(view, ".plan-assign-actions [role=status]", "1 selected")
    assert has_element?(view, "#item-a input[checked]")
    assert has_element?(view, "#target-a option[selected][value='#{track.id}']")
    refute has_element?(view, ".plan-assign-actions button[disabled]")

    view
    |> element("#plan-assign")
    |> render_change(%{"selected" => [], "targets" => %{"a" => track.id}})

    assert has_element?(view, ".plan-assign-actions [role=status]", "0 selected")
    refute has_element?(view, "#item-a input[checked]")

    view
    |> form("#plan-assign", %{
      "selected" => ["a", "b"],
      "targets" => %{"a" => track.id, "b" => track.id}
    })
    |> render_submit()

    render_async(view, 5_000)
    assert {:ok, %{items: items}} = Plans.get(user, plan.id)
    assert Enum.all?(items, &(&1.track_id == track.id))
    assert has_element?(view, "#item-a .chip", "in progress")
    assert Repo.aggregate(Ravix.Tooling.Task, :count) == 2
    assert has_element?(view, ".plan-assign-actions [role=status]", "0 selected")
    view |> element("#plans-panel button", "Edit plan") |> render_click()
    assert has_element?(view, "#plan-editor", "Assigned items must remain unchanged")
  end

  test "the plan shows its dependency graph, linking each node to its item", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Graph",
        "items" => [
          %{"id" => "a", "title" => "Decide"},
          %{"id" => "b", "title" => "Build", "dependencies" => ["a"]},
          %{"id" => "c", "title" => "Ship <b>it</b>", "dependencies" => ["a", "b"]}
        ]
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)

    assert has_element?(view, ".plan-graph-unassigned a[href='#item-a']", "Decide")
    assert has_element?(view, ".plan-graph-blocked a[href='#item-b']", "blocked")
    assert has_element?(view, ".plan-graph-blocked a[href='#item-c']", "Ship <b>it</b>")
    refute has_element?(view, ".plan-graph b")

    assert view |> element(".plan-graph svg") |> render() |> String.split("<path") |> length() ==
             4

    assert has_element?(view, "#item-c")
  end

  test "guests never mount the plans panel, and revoked sessions cannot assign", %{
    conn: conn,
    user: user,
    project: project
  } do
    guest = insert_user()
    track = insert_track(project: project)
    insert_track_member(track, guest)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Private plan",
        "items" => [%{"id" => "a", "title" => "A"}]
      })

    {:ok, guest_view, _} = live(log_in_user(conn, guest), "/p/#{project.id}?plan=#{plan.id}")
    refute render(guest_view) =~ "Private plan"
    refute has_element?(guest_view, "#plans-panel")
    {token, session} = insert_session(user)
    signed = Plug.Test.init_test_session(conn, %{"session_token" => token})
    {:ok, view, _} = live(signed, "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)
    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> form("#plan-assign", %{"selected" => ["a"]}) |> render_submit()

    assert Repo.get!(Ravix.Plans.Item, "a").track_id == nil
  end

  test "membership removal and stale edits refuse connected events", %{
    conn: conn,
    user: user,
    project: project
  } do
    member = insert_user()
    membership = insert_project_member(project, member)
    {:ok, plan} = Plans.create(user, project.id, %{"title" => "Original", "items" => []})
    {:ok, view, _} = live(log_in_user(conn, member), "/p/#{project.id}?plan=#{plan.id}")
    render_async(view, 5_000)
    view |> element("#plans-panel button", "Edit plan") |> render_click()
    Plans.update(user, plan.id, 1, %{"title" => "Changed"})
    view |> form("#plan-editor", %{"plan" => %{"title" => "Stale"}}) |> render_submit()
    assert has_element?(view, "[role=alert]", "Reload")
    Repo.delete!(membership)
    view |> form("#plan-editor", %{"plan" => %{"title" => "Forbidden"}}) |> render_submit()
    refute has_element?(view, "#plan-editor")
    assert {:ok, %{plan: %{title: "Changed"}}} = Plans.get(user, plan.id)
    refute Accounts.session_user("missing")
  end
end
