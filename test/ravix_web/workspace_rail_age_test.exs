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

  test "each row shows its owner's avatar or initial and a live-updatable age", ctx do
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

    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    tab = &"#project-track-tab-#{&1.id}"

    # The avatar has an accessible name; without one, the initials stand in.
    assert has_element?(
             view,
             "#{tab.(fresh)} .track-creator[role=img][aria-label='Created by @ada-lovelace'] img[src='https://avatars.example/ada.png'][alt='']"
           )

    assert has_element?(
             view,
             "#{tab.(prompted)} .track-creator[role=img][aria-label='Created by @grace'] span[aria-hidden=true]",
             "GR"
           )

    refute has_element?(view, "#{tab.(prompted)} .track-creator img")

    # The age is a hooked <time>: machine-readable, absolute in the tooltip.
    assert has_element?(view, "#{tab.(fresh)} time#track-age-#{fresh.id}.track-age", "now")

    iso = DateTime.to_iso8601(last)

    assert has_element?(
             view,
             "#{tab.(prompted)} time#track-age-#{prompted.id}[phx-hook=RelativeTime][datetime='#{iso}']",
             "22h"
           )

    assert has_element?(
             view,
             "#track-age-#{prompted.id}[title='Last active #{RavixWeb.LocalTime.full(last, nil)}']"
           )

    # Private is a lock with a tooltip, and a word only a reader hears; the
    # row's name says it too (RAV-96).
    assert has_element?(view, "#{tab.(quiet)} .track-private[data-tip^='Private'] svg")
    assert has_element?(view, "#{tab.(quiet)} .track-private .sr-only", "Private")
    assert has_element?(view, "#{tab.(quiet)}[data-label*=', private']")
    refute has_element?(view, "#{tab.(prompted)}[data-label*=', private']")
    assert has_element?(view, "#{tab.(quiet)} #track-age-#{quiet.id}", "2d")

    # The link's name carries the age in words; the hook keeps it current
    # from the stable part in data-label.
    assert has_element?(
             view,
             "#{tab.(prompted)}[data-label^='Prompted, created by @grace'][aria-label$=', active 22 hours ago']"
           )

    assert has_element?(view, "#{tab.(fresh)}[aria-label$=', active just now']")
    assert has_element?(view, "#{tab.(quiet)}[aria-label$=', active 2 days ago']")
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
    view |> element("#show-closed-#{ctx.project.id}") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#closed-track-#{closed.id} .track-creator", "GR")

    assert has_element?(
             view,
             "#closed-track-#{closed.id} time#closed-track-age-#{closed.id}[phx-hook=RelativeTime]",
             "3h"
           )
  end

  # RAV-96: an avatar on every row says nothing when one person made every
  # track the rail shows, so the rail leaves them out; a second creator, or
  # Mine narrowing the rail back to one, decides it again.
  test "the rail drops its avatars while every track shown has one creator", %{conn: conn} do
    viewer = insert_user(login: "solo")
    other = insert_user(login: "second")
    project = insert_project(user: viewer, name: "Owners")

    mine =
      insert_track(
        project: project,
        title: "Mine",
        created_by: viewer.id,
        created_by_login: "solo"
      )

    {:ok, view, _} = live(log_in_user(conn, viewer), "/p/#{project.id}")
    render_async(view, 5_000)

    assert has_element?(view, "#project-tree[data-one-creator]")
    # Still drawn, and still named, for the row's own accessible name.
    assert has_element?(view, "#project-track-tab-#{mine.id}[data-label*='created by @solo']")

    insert_track(
      project: project,
      title: "Theirs",
      created_by: other.id,
      created_by_login: "second"
    )

    {:ok, view, _} = live(log_in_user(conn, viewer), "/p/#{project.id}")
    render_async(view, 5_000)
    refute has_element?(view, "#project-tree[data-one-creator]")

    view |> element("#rail-scope-mine") |> render_click()
    assert has_element?(view, "#project-tree[data-one-creator]")
  end
end
