defmodule RavixWeb.SettingsAccessTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "members and unrelated users cannot open settings", %{conn: conn} do
    owner = insert_user()
    project = insert_project(user: owner)
    member = insert_user()
    insert_project_member(project, member)

    {:ok, view, _} = live(log_in_user(conn, member), "/p/#{project.id}")
    render_click(view, "dialog", %{name: "settings"})
    refute has_element?(view, "#settings-form")

    {:ok, stranger, _} = live(log_in_user(conn, insert_user()), "/p/#{project.id}")
    render_async(stranger)
    assert_patch(stranger, "/")
    assert has_element?(stranger, "#flash-error", "no longer available")
  end
end
