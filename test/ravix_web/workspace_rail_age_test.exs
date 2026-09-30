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
             "#track-age-#{prompted.id}[title='Last active #{Calendar.strftime(last, "%b %-d, %Y %H:%M UTC")}']"
           )

    assert has_element?(view, "#{tab.(quiet)} .track-private", "Private")
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
end
