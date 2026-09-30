defmodule RavixWeb.Live.MachineDockShellTest do
  # Terminal tabs in the track page's dock, with the real `Ravix.Terminal`
  # underneath and real sockets to the fake Sprites exec WebSocket: only
  # Fountain (which machine) and the transcript reads are stubbed.
  use RavixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Accounts
  alias Ravix.Fountain.FakeTransport
  alias Ravix.People
  alias Ravix.Repo
  alias Ravix.SpritesFake
  alias Ravix.Terminal
  alias Ravix.Terminal.{Shell, Store}
  alias Ravix.Tracks
  alias Ravix.Tracks.{Files, Track, Transcript}
  alias RavixWeb.Plugs.CurrentUser

  setup :verify_on_exit!

  setup do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, slug: "kyoto", created_by_login: owner.login)

    cfg = SpritesFake.start_proxy()
    stub(Ravix.Config, :sprites, fn -> cfg end)

    SpritesFake.install(fn conn, call ->
      SpritesFake.kill_exec(conn, cfg) || status(conn, call)
    end)

    fountain(project)

    stub(Tracks, :get, fn _, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: %Ravix.Tracks.Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: "t", files: nil},
           has_setup_script: false
         },
         threads: [],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

    stub(Tracks, :files, fn _, _, path ->
      {:ok, %Files.Listing{path: path || track.workdir, truncated: false, entries: []}}
    end)

    %{owner: owner, project: project, track: track, cfg: cfg}
  end

  # The machine's passive status read, which the dock makes on mount.
  defp status(conn, _call), do: Plug.Conn.send_resp(conn, 200, ~s({"status":"running"}))

  defp fountain(project) do
    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [],
            %{
              data: [
                %{
                  id: "c1",
                  sandbox_id: "sb-1",
                  status: "idle",
                  inserted_at: "2026-09-09T00:00:00Z"
                }
              ]
            }}},
          {%{method: "GET", path: "/api/sandboxes/sb-1"},
           {200, [], %{data: %{id: "sb-1", sprite_name: "sprite-7"}}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
  end

  # Signed in with a session this test can end.
  defp open(ctx, user) do
    {token, session} = insert_session(user)

    conn =
      build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(CurrentUser.session_key(), token)

    {:ok, parent, _} = live(conn, "/p/#{ctx.project.id}/t/#{ctx.track.id}")
    view = find_live_child(parent, "track-host")
    render_async(view, 5_000)
    render_async(view, 5_000)
    %{view: view, parent: parent, hash: session.token_hash}
  end

  defp new_terminal(view) do
    view |> element("#dock-shell-new") |> render_click()
    [tab | _] = view |> render() |> ids() |> Enum.reverse()
    tab
  end

  defp ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-shell-tab]")
    |> Enum.map(&(LazyHTML.attribute(&1, "data-shell-tab") |> hd()))
  end

  # What the pane's hook does once it has measured itself.
  defp attach(view, id, cols \\ 100, rows \\ 30) do
    view
    |> element("#shell-#{id}")
    |> render_hook("shell-attach", %{id: id, cols: cols, rows: rows})

    assert_push_event(view, "shell:reset", %{id: ^id}, 2_000)
  end

  defp await_output(view, id, text, acc \\ "") do
    if String.contains?(acc, text) do
      acc
    else
      assert_push_event(view, "shell:output", %{id: ^id, data: data}, 2_000)
      await_output(view, id, text, acc <> Base.decode64!(data))
    end
  end

  test "+ opens a terminal tab that is a real shell: open, type, resize", ctx do
    %{view: view} = open(ctx, ctx.owner)
    refute has_element?(view, "[data-shell-tab]")

    id = new_terminal(view)
    assert has_element?(view, "[data-shell-tab='#{id}'] button.selected", "Terminal 1")
    assert has_element?(view, "#machine-dock:not([hidden]) #shell-pane-#{id}:not([hidden])")
    assert has_element?(view, "#shell-#{id}[phx-hook=Shell][phx-update=ignore]")
    assert has_element?(view, "#shell-pane-#{id} .shell-status", "Connecting")

    attach(view, id, 132, 43)
    assert_receive {SpritesFake, :exec, {:spawn, query}}
    assert query["tty"] == "true" and query["dir"] == "/home/sprite/work/kyoto"
    assert {query["cols"], query["rows"]} == {"132", "43"}
    assert await_output(view, id, "$ ")
    refute has_element?(view, "#shell-pane-#{id} .shell-status")

    render_hook(view, "shell-input", %{id: id, data: "psql\r"})
    assert await_output(view, id, "ran: psql")

    render_hook(view, "shell-resize", %{id: id, cols: 90, rows: 20})
    assert_receive {SpritesFake, :exec, {:resize, "s1", 90, 20}}
  end

  test "several tabs, each its own shell; selecting one shows only its pane", ctx do
    %{view: view} = open(ctx, ctx.owner)
    one = new_terminal(view)
    two = new_terminal(view)

    assert has_element?(view, "[data-shell-tab='#{two}'] button", "Terminal 2")
    assert has_element?(view, "#shell-pane-#{one}[hidden]")
    assert has_element?(view, "#shell-pane-#{two}:not([hidden])")

    attach(view, one)
    attach(view, two)
    await_output(view, one, "$ ")
    await_output(view, two, "$ ")
    render_hook(view, "shell-input", %{id: two, data: "top\r"})
    assert await_output(view, two, "ran: top")

    view |> element("[data-shell-tab='#{one}'] button[phx-click=shell]") |> render_click()
    assert has_element?(view, "#shell-pane-#{one}:not([hidden])")
    assert has_element?(view, "#shell-pane-#{two}[hidden]")

    # The other panels are still there.
    view |> element("button[phx-click=dock][phx-value-name=terminal]") |> render_click()
    assert has_element?(view, "#track-terminal:not([hidden])")
  end

  test "closing a tab ends its shell on the machine and forgets it", ctx do
    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)
    attach(view, id)
    await_output(view, id, "$ ")
    assert_eventually(fn -> Store.get(ctx.track.id, ctx.owner.id, id).session_id == "s1" end)

    view |> element("button[aria-label='Close Terminal 1']") |> render_click()

    refute has_element?(view, "[data-shell-tab]")
    refute has_element?(view, "#shell-pane-#{id}")
    assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
    refute Store.get(ctx.track.id, ctx.owner.id, id)
  end

  test "a reconnect finds its tabs and re-attaches, with the scrollback replayed", ctx do
    first = open(ctx, ctx.owner)
    id = new_terminal(first.view)
    attach(first.view, id)
    await_output(first.view, id, "$ ")
    render_hook(first.view, "shell-input", %{id: id, data: "iex -S mix\r"})
    await_output(first.view, id, "ran: iex -S mix")

    # The socket drops: the page process goes, and its attachment with it.
    # (The test is linked to the page it opened; it traps the exit to see it go.)
    shell = Shell.whereis(first.view.pid, id)
    ref = Process.monitor(shell)
    Process.flag(:trap_exit, true)
    GenServer.stop(first.parent.pid, {:shutdown, :closed})
    assert_receive {:DOWN, ^ref, :process, ^shell, :normal}, 2_000
    assert %{"s1" => %{alive: true}} = SpritesFake.exec_sessions(ctx.cfg)

    # The new page, on whichever instance. Its dock starts closed; the pane
    # that was in front says so as it re-attaches.
    %{view: view} = open(ctx, ctx.owner)
    assert has_element?(view, "[data-shell-tab='#{id}']", "Terminal 1")
    assert has_element?(view, "#machine-dock[hidden]")

    view
    |> element("#shell-#{id}")
    |> render_hook("shell-attach", %{id: id, cols: 100, rows: 30, select: true})

    assert_push_event(view, "shell:reset", %{id: ^id}, 2_000)
    assert has_element?(view, "#machine-dock:not([hidden]) #shell-pane-#{id}:not([hidden])")
    assert_receive {SpritesFake, :exec, {:attach, "s1"}}
    assert await_output(view, id, "ran: iex -S mix") =~ "$ iex -S mix"
  end

  test "a tab whose shell ended while away says so and can be closed", ctx do
    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)
    Store.put_session(id, ctx.owner.id, "long-gone")

    view |> element("#shell-#{id}") |> render_hook("shell-attach", %{id: id, cols: 80, rows: 24})
    assert_eventually(fn -> render(view) =~ "ended while nobody was attached" end)

    view |> element("#shell-pane-#{id} button", "Close tab") |> render_click()
    refute has_element?(view, "[data-shell-tab]")
  end

  test "each way a terminal can stop is said in words, with the way back", ctx do
    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)
    attach(view, id)
    pane = "#shell-pane-#{id} .shell-status"

    # What `Ravix.Terminal.Shell` sends the page, in each case.
    tell(view, id, :disconnected)
    assert has_element?(view, pane, "The connection to this terminal dropped")
    assert has_element?(view, "#{pane} button", "Reconnect")

    tell(view, id, :ready)
    refute has_element?(view, pane)

    for {event, words} <- [
          {{:exited, 0}, "The shell exited (0)."},
          {{:ended, :revoked}, "This terminal ended because your access did."},
          {{:ended, %Ravix.Sprites.Error{status: 502, message: "Could not reach Sprites."}},
           "Could not reach Sprites."}
        ] do
      tell(view, id, event)
      assert has_element?(view, pane, words)
      assert has_element?(view, "#{pane} button", "Close tab")
      refute has_element?(view, "#{pane} button", "Reconnect")
    end

    # An ended tab is not re-attached by a pane that asks.
    view |> element("#shell-#{id}") |> render_hook("shell-attach", %{id: id, cols: 80, rows: 24})
    refute_receive {SpritesFake, :exec, {:attach, _}}, 100

    # And an event for a tab this page does not have changes nothing.
    tell(view, "not-a-tab", :disconnected)
    tell(view, id, :something_new)
    assert has_element?(view, pane, "Could not reach Sprites.")
  end

  test "signing out ends the terminal at once, with no message from the page", ctx do
    %{view: view, hash: hash} = open(ctx, ctx.owner)
    id = new_terminal(view)
    attach(view, id)
    await_output(view, id, "$ ")
    assert_eventually(fn -> Store.get(ctx.track.id, ctx.owner.id, id).session_id == "s1" end)
    shell = Shell.whereis(view.pid, id)
    ref = Process.monitor(shell)

    Accounts.end_session(hash)

    assert_receive {:DOWN, ^ref, :process, ^shell, :normal}, 2_000
    assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
    refute Store.get(ctx.track.id, ctx.owner.id, id)
  end

  test "a removed member loses the terminal at once, and cannot type into it", ctx do
    member = insert_user()
    insert_track_member(ctx.track, member)
    %{view: view} = open(ctx, member)
    id = new_terminal(view)
    attach(view, id)
    await_output(view, id, "$ ")
    assert_eventually(fn -> Store.get(ctx.track.id, member.id, id).session_id == "s1" end)
    shell = Shell.whereis(view.pid, id)
    ref = Process.monitor(shell)

    {:ok, _} = People.remove(ctx.owner, ctx.track.id, member.login)

    assert_receive {:DOWN, ^ref, :process, ^shell, :normal}, 2_000
    assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
    refute Store.get(ctx.track.id, member.id, id)
    refute_receive {SpritesFake, :exec, {:input, _, _}}, 50
  end

  test "somebody else's tab cannot be attached, closed or typed into from this page", ctx do
    other = insert_user()
    insert_track_member(ctx.track, other)
    {:ok, theirs} = Terminal.open_tab(other, ctx.track.id)

    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)
    view |> element("#shell-#{id}") |> render_hook("shell-attach", %{id: theirs.id})
    render_hook(view, "shell-input", %{id: theirs.id, data: "whoami\r"})
    view |> element("#shell-#{id}") |> render_hook("shell-close", %{id: theirs.id})

    refute_receive {SpritesFake, :exec, {:spawn, _}}, 100
    assert Store.get(ctx.track.id, other.id, theirs.id)
  end

  test "no machine connection: + says why rather than opening a tab", ctx do
    stub(Ravix.Config, :sprites, fn -> nil end)
    %{view: view, parent: parent} = open(ctx, ctx.owner)

    view |> element("#dock-shell-new") |> render_click()
    render_async(view)
    assert render(parent) =~ "no Sprites token"
    refute has_element?(view, "[data-shell-tab]")
  end

  # A message from a shell, as the page receives it. The page hands it to the
  # dock with `send_update/3`, which is a message of its own: the first render
  # is queued behind that, the second is not.
  defp tell(view, id, event) do
    send(view.pid, {:terminal, id, event})
    render(view)
    render(view)
  end

  defp assert_eventually(fun, tries \\ 100) do
    if fun.() do
      true
    else
      if tries == 0, do: flunk("condition never held")

      receive do
      after
        20 -> assert_eventually(fun, tries - 1)
      end
    end
  end
end
