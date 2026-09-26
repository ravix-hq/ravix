defmodule RavixWeb.ConnectionsLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ravix.ToolingFixture
  alias Ravix.Repo
  alias Ravix.Tooling.Grant

  test "same-name grants show dates and collapsed permissions inside the workspace", %{conn: conn} do
    user = insert_user()
    {first, _, _} = principal(user)
    {second, _, _} = principal(user)
    {foreign, _, _} = principal(insert_user())
    first_date = ~U[2026-01-01 09:00:00.000000Z]
    second_date = ~U[2026-02-01 10:30:00.000000Z]
    used_date = ~U[2026-03-01 11:45:00.000000Z]

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Grant, first.grant.id),
        inserted_at: first_date,
        last_used_at: nil
      )
    )

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Grant, second.grant.id),
        inserted_at: second_date,
        last_used_at: used_date
      )
    )

    {:ok, view, _} = live(log_in_user(conn, user), "/settings/connections")
    assert page_title(view) == "Connected applications · Ravix"
    assert has_element?(view, "#yard[aria-label='Projects']")
    refute has_element?(view, ".landing, .invite, .inbox-empty")
    assert has_element?(view, "#connection-#{first.grant.id} h2", "Desktop test")
    assert has_element?(view, "#connection-#{second.grant.id} h2", "Desktop test")

    assert has_element?(
             view,
             "#connection-#{first.grant.id} time[datetime='2026-01-01T09:00:00.000000Z']"
           )

    assert has_element?(view, "#connection-#{first.grant.id}", "Not recorded yet")

    assert has_element?(
             view,
             "#connection-#{second.grant.id} time[datetime='2026-03-01T11:45:00.000000Z']"
           )

    assert has_element?(
             view,
             "#connection-#{second.grant.id} time[datetime='2026-02-01T10:30:00.000000Z']"
           )

    assert has_element?(
             view,
             "#connection-#{first.grant.id} details:not([open]) summary",
             "Permissions"
           )

    refute has_element?(view, "#connection-#{foreign.grant.id}")
    refute has_element?(view, "#connections-panel details[open]")
  end

  test "empty connections and navigation stay in the workspace", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/home")
    render_patch(view, "/settings/connections")
    assert has_element?(view, "#connections-panel", "No applications connected.")
    assert page_title(view) == "Connected applications · Ravix"
    refute has_element?(view, ".connection-card")
  end

  test "revoking the session leaves the connections page", %{conn: conn} do
    user = insert_user()
    {token, session} = insert_session(user)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(conn, %{session_token: token}), "/settings/connections")

    Ravix.Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login")
  end
end
