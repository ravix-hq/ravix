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

    {:ok, view, _} = live(log_in_user(conn, user), "/settings/connected-apps")
    assert page_title(view) == "Connected apps · You · Ravix"
    assert has_element?(view, ".settings-crumbs [aria-current=page]", "Connected apps")
    assert has_element?(view, "#settings-nav-connected-apps[aria-current=page]")
    assert has_element?(view, "#yard[aria-label='Projects']")
    refute has_element?(view, ".landing, .invite, .inbox-empty")
    assert has_element?(view, "#connection-#{first.grant.id} h2", "Desktop test")
    assert has_element?(view, "#connection-#{second.grant.id} h2", "Desktop test")

    # Two clients of one name are told apart by when each connected, in the
    # heading, in the viewer's time (the `LocalTime` hook), and how long ago
    # each was last used (the `RelativeTime` hook).
    assert has_element?(
             view,
             "#connection-#{first.grant.id} h2 time#connection-#{first.grant.id}-connected[phx-hook=LocalTime][datetime='2026-01-01T09:00:00.000000Z']",
             "Jan 1, 9:00 AM"
           )

    assert has_element?(view, "#connection-#{first.grant.id}-meta", "not used yet")
    refute has_element?(view, "#connection-#{first.grant.id}-used")

    assert has_element?(
             view,
             "#connection-#{second.grant.id}-connected[datetime='2026-02-01T10:30:00.000000Z']",
             "Feb 1, 10:30 AM"
           )

    assert has_element?(
             view,
             "#connection-#{second.grant.id}-used[phx-hook=RelativeTime][data-style=ago][datetime='2026-03-01T11:45:00.000000Z']",
             "ago"
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
    render_patch(view, "/settings/connected-apps")
    assert has_element?(view, "#connections-panel", "No applications connected.")
    assert page_title(view) == "Connected apps · You · Ravix"
    refute has_element?(view, ".connection-card")
  end

  test "the old address lands on Connected apps, keeping its query", %{conn: conn} do
    conn = log_in_user(conn, insert_user())
    assert redirected_to(get(conn, "/settings/connections")) == "/settings/connected-apps"
    assert redirected_to(get(conn, "/settings/connections?x=1")) == "/settings/connected-apps?x=1"
  end

  test "Settings' nav opens Connected apps", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn, insert_user()), "/settings/profile")
    view |> element("#settings-nav-connected-apps") |> render_click()
    assert_patch(view, "/settings/connected-apps")
    assert has_element?(view, "#connections-panel")
  end

  test "a connection says its client and dates, and nothing about where it came from",
       %{conn: conn} do
    user = insert_user()
    {principal, _, _} = principal(user)
    {:ok, view, _} = live(log_in_user(conn, user), "/settings/connected-apps")
    card = view |> element("#connection-#{principal.grant.id}") |> render()
    assert card =~ "Desktop test"
    assert card =~ "connected"
    assert card =~ "Disconnect"
    refute card =~ ~r/IP address|User agent|127\.0\.0\.1/i
  end

  test "revoking the session leaves the connections page", %{conn: conn} do
    user = insert_user()
    {token, session} = insert_session(user)

    {:ok, view, _} =
      live(Plug.Test.init_test_session(conn, %{session_token: token}), "/settings/connected-apps")

    Ravix.Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login", 1_000)
  end
end
