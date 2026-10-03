defmodule RavixWeb.SearchLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  import Ecto.Query
  alias Ravix.{Accounts, Crypto, Hub, Repo}
  alias Ravix.Accounts.Access
  alias Ravix.Search.Index
  alias Ravix.TranscriptFixture, as: TF

  setup :verify_on_exit!

  setup do
    owner = insert_user()
    project = insert_project(user: owner)

    track =
      insert_track(
        project: project,
        title: "<img src=x onerror=alert(1)> searchable work",
        conversation_id: "conv-#{project.id}"
      )

    events = [
      TF.stage(1, "started")
      |> Map.put("blocks", [%{"kind" => "prompt", "body" => "human searchable"}]),
      TF.output(2, TF.text("searchable answer <script>alert(1)</script>")),
      TF.stage(3, "completed")
    ]

    Index.record(track.conversation_id, events, "claude")
    %{owner: owner, project: project, track: track}
  end

  test "route requires a live authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/search")
  end

  test "search form, filters, escaping and thread links work with real persistence", ctx do
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/search")
    render_async(view)

    view
    |> form("#workspace-search-form",
      search: %{q: "searchable", project: ctx.project.id, track: ctx.track.id}
    )
    |> render_submit()

    assert_patch(view)
    html = render_async(view)
    assert html =~ "&lt;img"
    refute html =~ "<img src=x"

    assert has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )

    view |> form("#workspace-search-form", search: %{q: "missinganswer"}) |> render_submit()
    assert_patch(view)
    render_async(view)

    refute has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )
  end

  test "pagination reaches the next distinct persisted results", ctx do
    for _ <- 1..22, do: insert_track(project: ctx.project, title: "pagesearch")
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/search?q=pagesearch")
    render_async(view)
    before = view |> element(".search-results") |> render()
    view |> element("a[href='/search?page=2&q=pagesearch']") |> render_click()
    assert_patch(view)
    after_page = render_async(view)
    refute after_page =~ before
    assert has_element?(view, "a[href='/search?page=1&q=pagesearch']")
  end

  test "revoked session stops a connected search and URL patch", ctx do
    {token, session} = insert_session(ctx.owner)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {:ok, view, _} = live(conn, "/search?q=searchable")
    render_async(view)
    Accounts.end_session(session.token_hash)
    assert_redirect(view, "/login")

    {token, session} = insert_session(ctx.owner)
    conn = Plug.Test.init_test_session(build_conn(), session_token: token)
    {:ok, view, _} = live(conn, "/search?q=searchable")
    render_async(view)
    Repo.delete!(session)
    assert {:error, {:redirect, %{to: "/login"}}} = render_patch(view, "/search?q=answer")
  end

  test "session expiry is checked on connected form events", ctx do
    conn = log_in_user(ctx.conn, ctx.owner)
    {:ok, view, _} = live(conn, "/search?q=searchable")
    render_async(view)
    hash = Crypto.sha256(get_session(conn, :session_token))

    Repo.update_all(from(s in Accounts.Session, where: s.token_hash == ^hash),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    # A held session answer expires on the periodic guard backstop.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      guard = %{socket.assigns.session_guard | stale?: true}
      %{state | socket: Phoenix.Component.assign(socket, :session_guard, guard)}
    end)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> form("#workspace-search-form", search: %{q: "answer"}) |> render_submit()
  end

  test "membership notices clear results and filters of a removed track-only guest", ctx do
    guest = insert_user()
    seat = insert_track_member(ctx.track, guest)
    {:ok, view, _} = live(log_in_user(ctx.conn, guest), "/search?q=searchable")
    render_async(view)

    assert has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )

    Repo.delete!(seat)
    Hub.publish(ctx.project.id, :people, track_id: ctx.track.id)
    render(view)
    render_async(view)

    refute has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )

    send(view.pid, :refresh_access)
    render(view)
    render_async(view)
    refute has_element?(view, "option[value='#{ctx.track.id}']")
  end

  test "async completion rechecks membership removed while database search was in flight", ctx do
    guest = insert_user()
    seat = insert_track_member(ctx.track, guest)
    {:ok, view, _} = live(log_in_user(ctx.conn, guest), "/search")
    render_async(view)
    parent = self()
    stub(Access, :project_ids, fn user -> Mimic.call_original(Access, :project_ids, [user]) end)

    expect(Access, :project_ids, fn user ->
      send(parent, {:search_started, self()})

      receive do
        :complete_search -> Mimic.call_original(Access, :project_ids, [user])
      end
    end)

    render_patch(view, "/search?q=searchable")
    assert_receive {:search_started, task}
    Repo.delete!(seat)
    send(task, :complete_search)
    render_async(view)
    refute has_element?(view, "option[value='#{ctx.track.id}']")

    refute has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )
  end

  test "database failure is recoverable and no provider/error detail reaches the page", ctx do
    stub(Access, :project_ids, fn user -> Mimic.call_original(Access, :project_ids, [user]) end)
    expect(Access, :project_ids, fn _ -> raise Postgrex.Error, message: "private-db-detail" end)
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.owner), "/search?q=searchable")
    html = render_async(view)
    assert has_element?(view, "[role=alert]")
    refute html =~ "private-db-detail"
    view |> form("#workspace-search-form", search: %{q: "searchable"}) |> render_submit()
    assert_patch(view)
    render_async(view)
    refute has_element?(view, "[role=alert]")

    assert has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )
  end

  test "invalid query errors do not expose work and another user's URL ids yield no snippets",
       ctx do
    conn = log_in_user(ctx.conn, insert_user())

    {:ok, view, _} =
      live(conn, "/search?q=searchable&project=#{ctx.project.id}&track=#{ctx.track.id}")

    render_async(view)

    refute has_element?(
             view,
             "a[href='/p/#{ctx.project.id}/t/#{ctx.track.id}?thread=#{ctx.track.id}']"
           )

    render_patch(view, "/search?q=searchable&page=0")
    render_async(view)
    assert has_element?(view, "[role=alert]")
  end
end
