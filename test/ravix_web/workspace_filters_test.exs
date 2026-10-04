defmodule RavixWeb.WorkspaceFiltersTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Accounts, Repo}
  alias Ravix.GitHubFake, as: GH
  alias Ravix.Projects.Sections

  setup :verify_on_exit!

  setup do
    viewer = insert_user(login: "ada-lovelace", avatar_url: "https://avatars.example/ada.png")
    other = insert_user(login: "grace", avatar_url: nil)
    project = insert_project(user: viewer, name: "Filters")

    mine =
      insert_track(
        project: project,
        title: "Mine track",
        created_by: viewer.id,
        created_by_login: viewer.login
      )

    theirs =
      insert_track(
        project: project,
        title: "Their track",
        created_by: other.id,
        created_by_login: other.login
      )

    %{viewer: viewer, other: other, project: project, mine: mine, theirs: theirs}
  end

  defp open(conn, user, path) do
    {:ok, view, _} = live(log_in_user(conn, user), path)
    render_async(view, 5_000)
    view
  end

  test "Mine hides others' tracks, Everyone shows them, and the choice persists", ctx do
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    mine_tab = "#project-track-tab-#{ctx.mine.id}"
    their_tab = "#project-track-tab-#{ctx.theirs.id}"

    assert has_element?(view, "#rail-scope-everyone[aria-checked=true]")
    assert has_element?(view, their_tab)

    # Creator avatars: an image with an accessible name, or initials without one.
    assert has_element?(
             view,
             "#{mine_tab} .track-creator[role=img][aria-label='Created by @ada-lovelace'][title='Created by @ada-lovelace'] img[src='https://avatars.example/ada.png']"
           )

    assert has_element?(view, "#{their_tab} .track-creator[aria-label='Created by @grace']", "GR")
    assert has_element?(view, "#{mine_tab}[aria-label*='created by @ada-lovelace']")

    view |> element("#rail-scope-mine") |> render_click()
    assert has_element?(view, "#rail-scope-mine[aria-checked=true]")
    assert has_element?(view, mine_tab)
    refute has_element?(view, their_tab)
    assert Accounts.Store.get_user(ctx.viewer.id).rail_scope == :mine

    # Persisted server-side: a new page load keeps Mine.
    reloaded = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    refute has_element?(reloaded, their_tab)

    # Counts and badges still cover every open track.
    render_click(reloaded, "dialog", %{name: "search"})
    reloaded |> form("#search-form", q: "track") |> render_change()
    assert has_element?(reloaded, "#search-track-link-#{ctx.theirs.id}")
    reloaded |> form("#search-form", q: "mine: track") |> render_change()
    assert has_element?(reloaded, "#search-track-link-#{ctx.mine.id}")
    refute has_element?(reloaded, "#search-track-link-#{ctx.theirs.id}")
    render_click(reloaded, "dismiss-switcher")

    reloaded |> element("#rail-scope-everyone") |> render_click()
    assert has_element?(reloaded, their_tab)
    assert Accounts.Store.get_user(ctx.viewer.id).rail_scope == :everyone
  end

  test "Mine keeps the selected track and says when nothing is the viewer's", ctx do
    {:ok, _} = Accounts.put_rail_scope(ctx.viewer, :mine)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}/t/#{ctx.theirs.id}")
    assert has_element?(view, "#project-track-tab-#{ctx.theirs.id}")

    Repo.delete!(ctx.mine)
    render_patch(view, "/p/#{ctx.project.id}")
    render_async(view, 5_000)

    assert has_element?(
             view,
             "#project-tree-tracks, .project-tree-tracks",
             "No open tracks of yours"
           )

    assert render_click(view, "rail-scope", %{scope: "nobody"}) =~ "Choose Mine or Everyone."
  end

  test "Show closed lists visible closed tracks, muted and uncounted, and never another person's private one",
       ctx do
    closed_at = DateTime.utc_now()

    closed =
      insert_track(
        project: ctx.project,
        title: "Closed track",
        closed_at: closed_at,
        created_by: ctx.other.id,
        created_by_login: ctx.other.login
      )

    foreign_private =
      insert_track(
        project: ctx.project,
        title: "Grace private",
        visibility: :private,
        sandbox_layout: :dedicated,
        closed_at: closed_at,
        created_by: ctx.other.id,
        created_by_login: ctx.other.login
      )

    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    refute has_element?(view, "#closed-tracks-#{ctx.project.id}")

    assert has_element?(
             view,
             "#show-closed-#{ctx.project.id}[role=menuitemcheckbox][aria-checked=false]"
           )

    view |> element("#show-closed-#{ctx.project.id}") |> render_click()
    render_async(view, 5_000)
    assert Sections.closed_shown(ctx.viewer) == [ctx.project.id]
    assert has_element?(view, "#show-closed-#{ctx.project.id}[aria-checked=true]")
    assert has_element?(view, "#closed-track-#{closed.id}.closed-track", "Closed track")
    assert has_element?(view, "#closed-track-#{closed.id} .track-creator", "GR")
    assert has_element?(view, "#reopen-track-#{closed.id}")
    refute has_element?(view, "#closed-track-#{foreign_private.id}")
    refute render(view) =~ "Grace private"
    refute has_element?(view, "#project-track-tab-#{closed.id}")

    # A closed track is not a page to open.
    render_patch(view, "/p/#{ctx.project.id}/t/#{closed.id}")
    assert render(view) =~ "Track not found in this project."

    # Persisted per viewer; another person keeps their own setting.
    reloaded = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    assert has_element?(reloaded, "#closed-track-#{closed.id}")
    assert Sections.closed_shown(ctx.other) == []

    reloaded |> element("#show-closed-#{ctx.project.id}") |> render_click()
    refute has_element?(reloaded, "#closed-tracks-#{ctx.project.id}")
    assert Sections.closed_shown(ctx.viewer) == []
  end

  test "Show closed lists the 20 most recently closed and pages older ones", ctx do
    base = ~U[2026-09-01 00:00:00.000000Z]

    closed =
      for n <- 1..25 do
        insert_track(
          project: ctx.project,
          title: "Old #{n}",
          closed_at: DateTime.add(base, n, :hour)
        )
      end

    {:ok, _} = Sections.show_closed(ctx.viewer, ctx.project.id, true)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    list = "#closed-tracks-#{ctx.project.id}"
    {older, newest} = Enum.split(closed, 5)

    for track <- newest, do: assert(has_element?(view, "#closed-track-#{track.id}"))
    for track <- older, do: refute(has_element?(view, "#closed-track-#{track.id}"))
    # Most recently closed first.
    [first | _] = String.split(render(element(view, list)), ~s(id="closed-track-)) |> tl()
    assert first =~ List.last(closed).id

    view |> element("#closed-older-#{ctx.project.id}", "Show older") |> render_click()
    render_async(view, 5_000)
    for track <- closed, do: assert(has_element?(view, "#closed-track-#{track.id}"))
    refute has_element?(view, "#closed-older-#{ctx.project.id}")
    # Counts and badges only count open tracks.
    assert has_element?(view, "#project-track-tab-#{ctx.mine.id}")
    refute has_element?(view, "#project-link-#{ctx.project.id} .badge")
  end

  test "Show closed and Reopen belong to project access; track-only members and forged projects are refused",
       ctx do
    shared = insert_track(project: ctx.project, title: "Shared", closed_at: DateTime.utc_now())
    guest = insert_user()
    insert_track_member(shared, guest)
    # Only an open track puts the project in a track-only member's rail.
    insert_track_member(ctx.theirs, guest)
    foreign = insert_project()

    view = open(ctx.conn, guest, "/p/#{ctx.project.id}")
    assert has_element?(view, "#project-track-tab-#{ctx.theirs.id}")
    refute has_element?(view, "#project-menu-trigger-#{ctx.project.id}")

    for id <- [ctx.project.id, foreign.id] do
      assert render_click(view, "show-closed", %{project: id, show: "true"}) =~
               "No such thing here."
    end

    refute has_element?(view, "#closed-track-#{shared.id}")
    assert render_click(view, "reopen-track", %{track: shared.id}) =~ "Track not available."
    assert Sections.closed_shown(guest) == []

    # A choice made while a project member lapses with that access.
    Repo.insert_all(Ravix.Projects.ClosedView, [%{user_id: guest.id, project_id: ctx.project.id}])
    reloaded = open(ctx.conn, guest, "/p/#{ctx.project.id}")
    refute has_element?(reloaded, "#closed-tracks-#{ctx.project.id}")
  end

  test "Reopen is offered only where the project has a repository", ctx do
    scratch = insert_project(user: ctx.viewer, repo_full_name: nil)
    closed = insert_track(project: scratch, closed_at: DateTime.utc_now())
    {:ok, _} = Sections.show_closed(ctx.viewer, scratch.id, true)
    view = open(ctx.conn, ctx.viewer, "/p/#{scratch.id}")
    assert has_element?(view, "#closed-track-#{closed.id}")
    refute has_element?(view, "#reopen-track-#{closed.id}")
    assert render_click(view, "reopen-track", %{track: closed.id}) =~ "Track not available."
  end

  test "Reopen starts a new track from the closed track's branch", ctx do
    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)

    closed =
      insert_track(
        project: ctx.project,
        title: "ravix/old-work",
        branch: "ravix/old-work",
        closed_at: DateTime.utc_now()
      )

    GH.install([
      GH.token_route(app),
      {"GET", "/repos/#{ctx.project.repo_full_name}/branches",
       fn conn ->
         Req.Test.json(conn, [
           %{name: "main", commit: %{sha: "a"}},
           %{name: "ravix/old-work", commit: %{sha: "b"}}
         ])
       end}
    ])

    {:ok, _} = Sections.show_closed(ctx.viewer, ctx.project.id, true)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    view |> element("#reopen-track-#{closed.id}") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#new-track-dialog #reopen-hint", "ravix/old-work")
    refute has_element?(view, "#reopen-hint", "isn't on GitHub")
    assert has_element?(view, "#track-ref option[value='ravix/old-work'][selected]")
    assert has_element?(view, "#track-advanced:not([hidden])")
  end

  test "Reopen says so when the branch was never pushed", ctx do
    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)

    closed =
      insert_track(project: ctx.project, branch: "ravix/local", closed_at: DateTime.utc_now())

    GH.install([
      GH.token_route(app),
      {"GET", "/repos/#{ctx.project.repo_full_name}/branches",
       fn conn -> Req.Test.json(conn, [%{name: "main", commit: %{sha: "a"}}]) end}
    ])

    {:ok, _} = Sections.show_closed(ctx.viewer, ctx.project.id, true)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    view |> element("#reopen-track-#{closed.id}") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#reopen-hint", "isn't on GitHub")
  end
end
