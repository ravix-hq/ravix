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

  # There is no Everyone / Mine filter any more: every track this person may
  # see is listed, and each row says whose it is.
  test "every visible track is listed, each saying whose it is", ctx do
    view = open(ctx.conn, ctx.viewer, "/home")
    mine_row = "#home-active-#{ctx.mine.id}"
    their_row = "#home-active-#{ctx.theirs.id}"

    refute has_element?(view, "#rail-scope-mine")
    assert has_element?(view, "#{mine_row} .track-owner", "You")

    assert has_element?(
             view,
             "#{mine_row} .track-sharing.sharing-yours[aria-label='Yours, open to the project']"
           )

    assert has_element?(view, "#{their_row} .track-owner", "@grace")

    assert has_element?(
             view,
             "#{their_row} .track-sharing.sharing-shared[aria-label='Shared with you by @grace']"
           )

    assert has_element?(view, "#home-project-#{ctx.project.id}", "2 open tracks")

    # Search still narrows to your own with `mine:`.
    render_click(view, "dialog", %{name: "search"})
    view |> form("#search-form", q: "track") |> render_change()
    assert has_element?(view, "#search-track-link-#{ctx.theirs.id}")
    view |> form("#search-form", q: "mine: track") |> render_change()
    assert has_element?(view, "#search-track-link-#{ctx.mine.id}")
    refute has_element?(view, "#search-track-link-#{ctx.theirs.id}")
  end

  test "a Mine saved before the filter went no longer hides anybody's tracks", ctx do
    {:ok, _} = Accounts.put_rail_scope(ctx.viewer, :mine)
    view = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")

    assert has_element?(view, "#tracks-graph-row-#{ctx.mine.id} .track-owner", "You")
    assert has_element?(view, "#tracks-graph-row-#{ctx.theirs.id} .track-owner", "@grace")

    view |> element("#project-tracks-list") |> render_click()
    assert has_element?(view, "#tracks-row-#{ctx.mine.id} .tracks-row-owner", "You")
    assert has_element?(view, "#tracks-row-#{ctx.theirs.id} .tracks-row-owner", "@grace")
    assert has_element?(view, "#tracks-row-#{ctx.theirs.id} .tracks-row-meta", "by @grace")
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
    refute has_element?(view, "#tracks-graph-row-#{closed.id}")
    assert has_element?(view, "#project-tracks-closed[aria-pressed=false]", "Show closed")

    view |> element("#project-tracks-closed") |> render_click()
    render_async(view, 5_000)
    assert Sections.closed_shown(ctx.viewer) == [ctx.project.id]
    assert has_element?(view, "#project-tracks-closed[aria-pressed=true]", "Hide closed")
    # Muted, and not a page to open: a span, not a link.
    assert has_element?(
             view,
             "#tracks-graph-row-#{closed.id}.closed span.tracks-title",
             "Closed track"
           )

    refute has_element?(view, "#tracks-graph-row-#{closed.id} a.tracks-title")
    assert has_element?(view, "#reopen-track-#{closed.id}")
    refute has_element?(view, "#tracks-graph-row-#{foreign_private.id}")
    refute render(view) =~ "Grace private"
    # Uncounted: the open count is still the two open tracks.
    assert has_element?(view, ".project-tracks-count strong", "2 open")
    assert has_element?(view, ".project-tracks-count", "1 closed")
    assert has_element?(view, "#crumb-tracks .count", "2")

    view |> element("#project-tracks-list") |> render_click()
    assert has_element?(view, "#tracks-row-#{closed.id}.closed .tracks-row-meta", "@grace")
    assert has_element?(view, "#tracks-row-#{closed.id} .tracks-row-state", "Closed")
    refute has_element?(view, "#tracks-row-#{foreign_private.id}")

    # A closed track is not a page to open.
    render_patch(view, "/p/#{ctx.project.id}/t/#{closed.id}")
    assert render(view) =~ "Track not found in this project."

    # Persisted per viewer; another person keeps their own setting.
    reloaded = open(ctx.conn, ctx.viewer, "/p/#{ctx.project.id}")
    assert has_element?(reloaded, "#tracks-graph-row-#{closed.id}")
    assert Sections.closed_shown(ctx.other) == []

    reloaded |> element("#project-tracks-closed") |> render_click()
    refute has_element?(reloaded, "#tracks-graph-row-#{closed.id}")
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
    view |> element("#project-tracks-list") |> render_click()
    {older, newest} = Enum.split(closed, 5)

    for track <- newest, do: assert(has_element?(view, "#tracks-row-#{track.id}.closed"))
    for track <- older, do: refute(has_element?(view, "#tracks-row-#{track.id}"))

    # Most recently closed first, after the open tracks.
    open_ids = [ctx.mine.id, ctx.theirs.id]

    [first | _] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#tracks-list > li.tracks-row")
      |> LazyHTML.attribute("id")
      |> Enum.map(&String.replace_prefix(&1, "tracks-row-", ""))
      |> Enum.reject(&(&1 in open_ids))

    assert first == List.last(closed).id

    view |> element("#closed-older-#{ctx.project.id}", "Show older") |> render_click()
    render_async(view, 5_000)
    for track <- closed, do: assert(has_element?(view, "#tracks-row-#{track.id}"))
    refute has_element?(view, "#closed-older-#{ctx.project.id}")

    # Counts and badges only count open tracks.
    assert has_element?(view, "#tracks-row-#{ctx.mine.id}:not(.closed)")
    assert has_element?(view, ".project-tracks-count strong", "2 open")
    render_patch(view, "/home")
    assert has_element?(view, "#home-project-#{ctx.project.id}", "2 open tracks")
    refute has_element?(view, "#home-project-#{ctx.project.id} .badge")
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
    assert has_element?(view, "#tracks-graph-row-#{ctx.theirs.id}")
    refute has_element?(view, "#project-tracks-closed")
    refute has_element?(view, "#crumb-settings")

    for id <- [ctx.project.id, foreign.id] do
      assert render_click(view, "show-closed", %{project: id, show: "true"}) =~
               "No such thing here."
    end

    refute has_element?(view, "#tracks-graph-row-#{shared.id}")
    assert render_click(view, "reopen-track", %{track: shared.id}) =~ "Track not available."
    assert Sections.closed_shown(guest) == []

    # A choice made while a project member lapses with that access.
    Repo.insert_all(Ravix.Projects.ClosedView, [%{user_id: guest.id, project_id: ctx.project.id}])
    reloaded = open(ctx.conn, guest, "/p/#{ctx.project.id}")
    assert has_element?(reloaded, "#tracks-graph-row-#{ctx.theirs.id}")
    refute has_element?(reloaded, "#tracks-graph-row-#{shared.id}")
    refute has_element?(reloaded, "#project-tracks-closed")
  end

  test "Reopen is offered only where the project has a repository", ctx do
    scratch = insert_project(user: ctx.viewer, repo_full_name: nil)
    closed = insert_track(project: scratch, closed_at: DateTime.utc_now())
    {:ok, _} = Sections.show_closed(ctx.viewer, scratch.id, true)
    view = open(ctx.conn, ctx.viewer, "/p/#{scratch.id}")
    assert has_element?(view, "#tracks-graph-row-#{closed.id}.closed")
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
