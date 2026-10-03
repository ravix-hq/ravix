defmodule RavixWeb.WorkspaceRailAgeTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup do
    viewer = insert_user(login: "ada-lovelace", avatar_url: "https://avatars.example/ada.png")
    other = insert_user(login: "grace", avatar_url: nil)
    project = insert_project(user: viewer, name: "Ages")
    %{viewer: viewer, other: other, project: project}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp open(conn, user, path) do
    {:ok, view, _} = live(log_in_user(conn, user), path)
    render_async(view, 5_000)
    view
  end

  test "each row shows who opened it, whether it is private and how long since it moved", ctx do
    fresh =
      insert_track(
        project: ctx.project,
        title: "Fresh",
        created_by: ctx.viewer.id,
        created_by_login: ctx.viewer.login
      )

    # Created days ago; a prompt 22 hours ago is its last activity.
    prompted =
      insert_track(
        project: ctx.project,
        title: "Prompted",
        created_at: ago(5 * 86_400),
        created_by: ctx.other.id,
        created_by_login: ctx.other.login
      )

    last = ago(22 * 3_600 + 300)
    insert_prompt(track: prompted, created_at: ago(3 * 86_400))
    insert_prompt(track: prompted, created_at: last)

    quiet =
      insert_track(
        project: ctx.project,
        title: "Quiet",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_at: ago(2 * 86_400 + 60),
        created_by: ctx.viewer.id,
        created_by_login: ctx.viewer.login
      )

    # The project's own list: private is a lock with a tooltip, and a word
    # only a reader hears; ages in words, from the last activity; and who
    # opened each track. (Home no longer lists tracks with their owners.)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    view |> element("#project-tracks-list") |> render_click()
    list_row = &"#tracks-row-#{&1.id}"

    assert has_element?(view, "#{list_row.(quiet)} .track-private[data-tip^='Private'] svg")

    assert has_element?(
             view,
             "#{list_row.(quiet)} .track-private[role=img][aria-label^='Private']"
           )

    refute has_element?(view, "#{list_row.(prompted)} .track-private")
    assert has_element?(view, "#{list_row.(prompted)} .tracks-row-age", "22h ago")
    assert has_element?(view, "#{list_row.(quiet)} .tracks-row-age", "2d ago")
    assert has_element?(view, "#{list_row.(fresh)} .tracks-row-age", "just now")
    assert has_element?(view, "#{list_row.(prompted)} .tracks-row-meta", "by @grace")
    assert has_element?(view, "#{list_row.(fresh)} .tracks-row-meta", "by @ada-lovelace")
    assert has_element?(view, "#{list_row.(quiet)} .tracks-row-meta", "opened 2d ago")
  end

  test "closed rows show how long since they last did anything", ctx do
    closed =
      insert_track(
        project: ctx.project,
        title: "Done",
        created_at: ago(40 * 86_400),
        closed_at: ago(3 * 3_600 + 60),
        created_by: ctx.other.id,
        created_by_login: ctx.other.login
      )

    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    view |> element("#project-tracks-closed") |> render_click()
    render_async(view, 5_000)
    view |> element("#project-tracks-list") |> render_click()

    assert has_element?(view, "#tracks-row-#{closed.id}.closed .tracks-row-meta", "by @grace")
    # Closing is its last activity, not its opening 40 days ago.
    assert has_element?(view, "#tracks-row-#{closed.id} .tracks-row-age", "3h ago")
  end
end
