defmodule RavixWeb.RoutinesPanelTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Ravix.{Crypto, Repo, Routines}
  alias Ravix.Routines.Routine

  test "create, edit, rotate, pause/resume, history and delete persist through the schedules page",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/schedules")
    render_async(view)

    view
    |> form("#routine-form",
      routine: %{name: "Report triage", project_id: project.id, prompt: "Triage the report"}
    )
    |> render_submit()

    [row] = Routines.list(user)
    assert row.project_id == project.id
    credential = view |> element("#routine-credential code") |> render() |> credential()
    assert Crypto.sha256(credential) == row.credential_hash
    view |> element("#routine-#{row.id} [phx-click=edit]") |> render_click()
    view |> form("#routine-form", routine: %{prompt: "Review and triage"}) |> render_submit()
    assert {:ok, %{prompt: "Review and triage"}} = Routines.get(user, row.id)
    view |> element("#routine-#{row.id} [phx-click=toggle]") |> render_click()
    assert {:ok, %{enabled: false}} = Routines.get(user, row.id)
    view |> element("#routine-#{row.id} [phx-click=toggle]") |> render_click()
    assert {:ok, %{enabled: true}} = Routines.get(user, row.id)
    view |> element("#routine-#{row.id} [phx-click=rotate]") |> render_click()
    rotated = view |> element("#routine-credential code") |> render() |> credential()
    refute rotated == credential
    assert {:ok, %{credential_hash: hash}} = Routines.get(user, row.id)
    assert hash == Crypto.sha256(rotated)
    view |> element("#routine-credential [phx-click=dismiss]") |> render_click()
    refute has_element?(view, "#routine-credential")
    view |> element("#routine-#{row.id} [phx-click=history]") |> render_click()
    assert {:ok, []} = Routines.history(user, row.id)
    view |> element("#routine-#{row.id} [phx-click=delete]") |> render_click()
    assert Routines.list(user) == []
  end

  test "invalid edit retains saved data; refreshing loads new rows", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/schedules")
    render_async(view)
    {:ok, row, _} = Routines.create(user, project.id, %{name: "Triage", prompt: "Saved"})
    view |> element("#routines-panel > .row [phx-click=refresh]") |> render_click()
    view |> element("#routine-#{row.id} [phx-click=edit]") |> render_click()
    view |> form("#routine-form", routine: %{prompt: ""}) |> render_submit()
    assert {:ok, %{prompt: "Saved"}} = Routines.get(user, row.id)
    view |> element("#routine-form [phx-click=cancel]") |> render_click()
    assert {:ok, %{prompt: "Saved"}} = Routines.get(user, row.id)
  end

  test "expired session cannot create a routine", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    {token, session} = insert_session(user)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(conn, %{session_token: token}), "/schedules")

    render_async(view)
    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view
             |> form("#routine-form",
               routine: %{name: "Triage", project_id: project.id, prompt: "Triage"}
             )
             |> render_submit()

    assert Routines.list(user) == []
  end

  test "revoked membership refuses connected management and hides any shown credential", %{
    conn: conn
  } do
    owner = insert_user()
    project = insert_project(user: owner)
    member = insert_user()
    membership = insert_project_member(project, member)
    {:ok, row, _} = Routines.create(member, project.id, %{name: "Triage", prompt: "Saved"})
    {:ok, view, _} = live(log_in_user(conn, member), "/schedules")
    render_async(view)
    view |> element("#routine-#{row.id} [phx-click=rotate]") |> render_click()
    hash = Repo.get!(Routine, row.id).credential_hash
    Repo.delete!(membership)
    view |> element("#routine-#{row.id} [phx-click=rotate]") |> render_click()
    assert Repo.get!(Routine, row.id).credential_hash == hash
    refute has_element?(view, "#routine-credential")
    refute has_element?(view, "#routine-#{row.id}")
  end

  test "another user's routine id and inaccessible project cannot be managed", %{conn: conn} do
    owner = insert_user()
    project = insert_project(user: owner)
    {:ok, row, _} = Routines.create(owner, project.id, %{name: "Triage", prompt: "Saved"})
    stranger = insert_user()
    {:ok, view, _} = live(log_in_user(conn, stranger), "/schedules")
    render_async(view)

    for event <- ["edit", "toggle", "rotate", "history", "delete"] do
      view |> with_target("#routines-panel") |> render_click(event, %{id: row.id})
      assert Repo.get!(Routine, row.id).enabled
    end

    assert Routines.list(stranger) == []
  end

  defp credential(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
end
