defmodule RavixWeb.SchedulesLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.{Schedules, Tracks}

  setup :verify_on_exit!

  test "navigation, create, edit, pause, resume and delete", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    stub(Tracks, :list, fn _, _, _opts -> {:ok, []} end)
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
        time: "10:15"
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

  test "explains schedules and runs new ones in the browser's zone", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    conn = conn |> log_in_user(user) |> put_connect_params(%{"timezone" => "Asia/Kolkata"})
    {:ok, view, _} = live(conn, "/schedules")
    render_async(view)
    assert has_element?(view, "#schedules-panel header", "a prompt that runs on a timer")
    assert has_element?(view, "#schedules-panel header", "every weekday at 9:00")
    assert has_element?(view, "#schedule_timezone[value='Asia/Kolkata']")

    view
    |> form("#schedule-form",
      schedule: %{name: "Triage", project_id: project.id, prompt: "Triage issues", time: "09:00"}
    )
    |> render_submit()

    [row] = Schedules.list(user)
    assert row.timezone == "Asia/Kolkata"
    assert {row.next_run_at.hour, row.next_run_at.minute} == {3, 30}
    assert has_element?(view, "#schedule-#{row.id}", "Daily at 09:00 (Asia/Kolkata)")
    assert has_element?(view, "#schedule-#{row.id}", "at 09:00 IST")

    # Another viewer's browser changes how the next run is shown, not the zone.
    other = conn |> recycle() |> log_in_user(user)
    other = put_connect_params(other, %{"timezone" => "America/New_York"})
    {:ok, ny, _} = live(other, "/schedules")
    render_async(ny)
    assert has_element?(ny, "#schedule-#{row.id}", "Daily at 09:00 (Asia/Kolkata)")
    assert has_element?(ny, "#schedule-#{row.id}", ~r/at 2[23]:30 E[SD]T/)

    ny |> element("#schedule-#{row.id} button", "Edit") |> render_click()
    assert has_element?(ny, "#schedule_timezone[value='Asia/Kolkata']")
    ny |> form("#schedule-form", schedule: %{prompt: "Triage more"}) |> render_submit()
    assert {:ok, %{timezone: "Asia/Kolkata", prompt: "Triage more"}} = Schedules.get(user, row.id)

    ny |> element("#schedule-#{row.id} button", "Edit") |> render_click()
    ny |> form("#schedule-form", schedule: %{timezone: "Not/AZone"}) |> render_submit()
    assert {:ok, %{timezone: "Etc/UTC"}} = Schedules.get(user, row.id)
    assert has_element?(ny, "#schedule-#{row.id}", "Daily at 09:00 (Etc/UTC)")
  end

  test "an unknown browser zone prefills UTC", %{conn: conn} do
    user = insert_user()
    conn = conn |> log_in_user(user) |> put_connect_params(%{"timezone" => "Mars/Olympus"})
    {:ok, view, _} = live(conn, "/schedules")
    assert has_element?(view, "#schedule_timezone[value='Etc/UTC']")
  end

  test "Day follows Repeat and preserves the weekly choice through changes and editing", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/schedules")
    render_async(view)
    refute has_element?(view, "#schedule_weekday")

    view
    |> form("#schedule-form",
      schedule: %{
        name: "Review",
        project_id: project.id,
        prompt: "Check tests",
        frequency: "weekly"
      }
    )
    |> render_change()

    assert has_element?(view, "#schedule_weekday option[value='1'][selected]")
    view |> form("#schedule-form", schedule: %{weekday: "5"}) |> render_change()

    for frequency <- ["hourly", "daily"] do
      view |> form("#schedule-form", schedule: %{frequency: frequency}) |> render_change()
      refute has_element?(view, "#schedule_weekday")
      assert has_element?(view, "#schedule_name[value='Review']")
      assert has_element?(view, "#schedule_prompt", "Check tests")
    end

    view |> form("#schedule-form", schedule: %{frequency: "weekly"}) |> render_change()
    assert has_element?(view, "#schedule_weekday option[value='5'][selected]")
    view |> form("#schedule-form") |> render_submit()
    [row] = Schedules.list(user)
    assert row.frequency == :weekly
    assert row.weekday == 5
    refute has_element?(view, "#schedule_weekday")

    view |> element("#schedule-#{row.id} button", "Edit") |> render_click()
    assert has_element?(view, "#schedule_weekday option[value='5'][selected]")
    view |> form("#schedule-form", schedule: %{frequency: "daily"}) |> render_change()
    refute has_element?(view, "#schedule_weekday")
    view |> form("#schedule-form") |> render_submit()
    assert {:ok, %{frequency: :daily}} = Schedules.get(user, row.id)
    view |> element("#schedule-#{row.id} button", "Edit") |> render_click()
    refute has_element?(view, "#schedule_weekday")
    view |> form("#schedule-form", schedule: %{frequency: "weekly"}) |> render_change()
    view |> element("#schedule-form button", "Cancel") |> render_click()
    refute has_element?(view, "#schedule_weekday")
  end

  test "refresh explicitly retrieves changes made outside this page", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/schedules")
    # Let the rail land first: applying it re-renders the panel, which would
    # otherwise pick up the schedule created below without a Refresh.
    render_async(view)
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
    stub(Tracks, :list, fn _, _, _opts -> {:ok, []} end)
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
                 time: "09:00"
               }
             )
             |> render_submit()

    assert Schedules.list(user) == []
  end
end
