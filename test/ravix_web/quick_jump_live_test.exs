defmodule RavixWeb.QuickJumpLiveTest do
  @moduledoc """
  Quick jump's markup (RAV-99): the shortcut named for the viewer's platform,
  tracks listed by their display name, a count per project group and an empty
  state that repeats the query. The keys themselves are the `QuickJump` hook's
  (assets/test/quick_jump.test.js) and the layout is a real browser's
  (browser/quick-jump.spec.js).
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.Client

  setup :verify_on_exit!

  setup do
    user = insert_user()

    project =
      insert_project(user: user, name: "ravix 2", repo_full_name: nil, installation_id: nil)

    stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "test-key") end)
    %{user: user, project: project}
  end

  test "the trigger names ⌘K on a Mac and Ctrl K elsewhere", ctx do
    for {params, label, keys} <- [
          {%{"platform" => "mac"}, "⌘K", "Meta+K"},
          {%{"platform" => "other"}, "Ctrl K", "Control+K"},
          {%{}, "Ctrl K", "Control+K"}
        ] do
      conn = ctx.conn |> log_in_user(ctx.user) |> put_connect_params(params)
      {:ok, view, _} = live(conn, "/inbox")

      assert has_element?(
               view,
               "#quick-jump-trigger[title='Search projects, tracks and plans (#{label})'][aria-keyshortcuts='#{keys}']"
             )
    end
  end

  test "results show display names in a counted group, or say nothing matched", ctx do
    long = "ravix/rav-83-workspaces-as-the-unit-of-sharing-across-projects"

    slug =
      insert_track(project: ctx.project, created_by: ctx.user.id, title: long)

    plain = insert_track(project: ctx.project, created_by: ctx.user.id, title: "plain-work")
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), "/inbox")
    # The workspace's first reads, which a full parallel run can hold past
    # `render_async/1`'s 100ms default.
    render_async(view, 1_000)
    render_click(view, "dialog", %{name: "search"})

    # The query field is the hook's to focus, with the keys typed on the way.
    assert has_element?(view, "#search-query[phx-hook=QuickJumpQuery]")
    group = "#search-group-#{ctx.project.id}"
    assert has_element?(view, "#{group} h3 .search-label", "ravix 2")
    assert has_element?(view, "#{group} h3 .search-count[aria-label='2 results']", "2")

    # The same name the sidebar draws, less the namespace; the tooltip adds
    # the raw branch.
    assert has_element?(
             view,
             "#search-track-link-#{slug.id}[title^='#{String.replace_prefix(long, "ravix/", "")}'][title$='#{slug.branch}'] .search-label",
             "rav-83-workspaces-as-the-unit-of-sharing-across-projects"
           )

    refute has_element?(view, "#search-track-link-#{slug.id} .search-label", "ravix/")
    assert has_element?(view, "#search-track-link-#{plain.id} .search-label", "plain-work")

    view |> form("#search-form", q: "plain") |> render_change()
    assert has_element?(view, "#{group} h3 .search-count[aria-label='1 result']", "1")
    refute has_element?(view, "#search-track-link-#{slug.id}")

    view |> form("#search-form", q: "zzz") |> render_change()

    assert has_element?(
             view,
             "#search-dialog .search-empty[role=status]",
             "No tracks match 'zzz'"
           )

    refute has_element?(view, "#search-dialog section")
  end

  test "with nothing to jump to and no query, it says so", ctx do
    {:ok, view, _} = live(log_in_user(ctx.conn, insert_user()), "/inbox")
    render_async(view)
    render_click(view, "dialog", %{name: "search"})
    assert has_element?(view, "#search-dialog .search-empty[role=status]", "No tracks yet")
  end
end
