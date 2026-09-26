defmodule RavixWeb.SchedulesLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Schedules, Tracks}

  setup :verify_on_exit!

  test "navigation, create, edit, pause, resume and delete", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    stub(Tracks, :list, fn _, _ -> {:ok, []} end)
    {:ok, view, html} = live(log_in_user(conn, user), "/schedules")
    # The rail (and with it the project options) arrives after mount (#221).
    render_async(view)
    assert html =~ "No schedules yet"
    assert has_element?(view, ".yard-nav a.on[href='/schedules']", "Schedules")

    view
    |> form("#schedule-form",
      schedule: %{
        name: "Daily check",
        project_id: project.id,
        prompt: "Check tests",
        frequency: "daily",
        time: "10:15",
        weekday: "1"
      }
    )
    |> render_submit()

    [row] = Schedules.list(user)
    assert has_element?(view, "#schedule-#{row.id}", "Daily check")
    view |> element("#schedule-#{row.id} button", "Edit") |> render_click()
    view |> form("#schedule-form", schedule: %{prompt: "Review failing tests"}) |> render_submit()
    assert {:ok, %{prompt: "Review failing tests"}} = Schedules.get(user, row.id)
    view |> element("#schedule-#{row.id} button", "Pause") |> render_click()
    assert {:ok, %{enabled: false}} = Schedules.get(user, row.id)
    view |> element("#schedule-#{row.id} button", "Resume") |> render_click()
    assert {:ok, %{enabled: true}} = Schedules.get(user, row.id)
    view |> element("#schedule-#{row.id} button", "Delete") |> render_click()
    assert Schedules.list(user) == []
  end

  test "refresh explicitly retrieves changes made outside this page", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/schedules")
    assert has_element?(view, "#schedules-refresh-note", "latest run status")

    {:ok, schedule} =
      Schedules.create(user, project.id, %{
        "name" => "Created elsewhere",
        "prompt" => "Check tests",
        "frequency" => "daily",
        "time" => "09:00"
      })

    refute has_element?(view, "#schedule-#{schedule.id}")
    view |> element("#schedules-panel button", "Refresh") |> render_click()
    assert has_element?(view, "#schedule-#{schedule.id}", "Created elsewhere")
  end

  test "expired session cannot create schedules", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    stub(Tracks, :list, fn _, _ -> {:ok, []} end)
    {token, session} = insert_session(user)
    conn = Plug.Test.init_test_session(conn, %{session_token: token})
    {:ok, view, _} = live(conn, "/schedules")
    # The rail (and with it the project options) arrives after mount (#221).
    render_async(view)
    Ravix.Repo.delete!(session)
    # Component event guards verify the session directly.
    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> form("#schedule-form",
               schedule: %{
                 name: "Check",
                 project_id: project.id,
                 prompt: "Check",
                 frequency: "daily",
                 time: "09:00",
                 weekday: "1"
               }
             )
             |> render_submit()

    assert Schedules.list(user) == []
  end
end
