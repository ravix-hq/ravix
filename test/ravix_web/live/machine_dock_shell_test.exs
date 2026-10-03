defmodule RavixWeb.Live.MachineDockShellTest do
  # Terminal tabs in the track page's dock, with the real `Ravix.Terminal`
  # underneath and real sockets to the fake Sprites exec WebSocket: only
  # Fountain (which machine) and the transcript reads are stubbed.
  use RavixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.Accounts
  alias Ravix.Fountain.{AwakeReads, FakeTransport}
  alias Ravix.People
  alias Ravix.Repo
  alias Ravix.SpritesFake
  alias Ravix.Terminal
  alias Ravix.Terminal.{Shell, Store}
  alias Ravix.Tracks
  alias Ravix.Tracks.{Files, Track, Transcript}
  alias RavixWeb.Plugs.CurrentUser

  setup :verify_on_exit!

  # How long a shell may take to say it is attached (`:ready`, which the pane
  # hears as `shell:reset`): the handshake deadline `Ravix.Sprites.Pty` gives
  # it. Past that the shell has failed and says so, so waiting on the event
  # to this bound is waiting for it, not guessing at a load; a healthy run
  # returns as soon as it arrives.
  @ready_ms 15_000

  setup do
    owner = insert_user()
    project = insert_project(user: owner)

    track =
      insert_track(
        project: project,
        slug: "kyoto",
        created_by_login: owner.login,
        conversation_id: "c1"
      )

    cfg = SpritesFake.start_proxy()
    stub(Ravix.Config, :sprites, fn -> cfg end)

    SpritesFake.install(fn conn, call ->
      SpritesFake.kill_exec(conn, cfg) || status(conn, call)
    end)

    fountain(project)
    test = self()

    # The dock's Wake is what these count, not the page's wake on open.
    stub(Tracks, :wake_on_open, fn _, _, _ -> {:ok, :skipped} end)

    # `Ravix.Tracks.wake/2` asks Fountain; an awake machine is `awake`.
    AwakeReads.stub()

    stub(Ravix.Fountain, :wake, fn _client, "c1" ->
      send(test, :fountain_wake)
      {:ok, :awake}
    end)

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

    assert_push_event(view, "shell:reset", %{id: ^id}, @ready_ms)
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

    # The resize goes page -> shell -> socket with no answer of its own; the
    # fake's report of the frame is the event, so wait for it by name.
    render_hook(view, "shell-resize", %{id: id, cols: 90, rows: 20})
    assert_receive {SpritesFake, :exec, {:resize, "s1", 90, 20}}, 2_000
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

    assert_push_event(view, "shell:reset", %{id: ^id}, @ready_ms)
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
           "Could not reach the machine."}
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
    assert has_element?(view, pane, "Could not reach the machine.")
    refute render(view) =~ "Sprites"
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
    assert render(parent) =~ "no machine connection configured"
    refute render(parent) =~ "Sprites"
    refute has_element?(view, "[data-shell-tab]")
  end

  describe "on a machine that is asleep (RAV-81)" do
    # The machine sleeps until Fountain wakes it: the dock's passive status
    # read says it is not running, and `Ravix.Fountain.wake/2` brings it up,
    # as Fountain does. `wakes?: false` is a machine Fountain refuses to wake.
    defp asleep(ctx, wakes? \\ true, gate \\ nil) do
      {:ok, machine} = Agent.start_link(fn -> %{awake: false, wakes: wakes?, gate: gate} end)
      test = self()

      SpritesFake.install(fn conn, call ->
        SpritesFake.kill_exec(conn, ctx.cfg) || machine_call(conn, call, machine)
      end)

      AwakeReads.stub()

      stub(Ravix.Fountain, :wake, fn _client, "c1" ->
        send(test, :fountain_wake)
        fountain_wake(machine)
      end)

      machine
    end

    defp fountain_wake(machine) do
      # A gated wake waits for the test to let it answer, so the test can
      # see the tab while the machine is waking.
      if gate = Agent.get(machine, & &1.gate) do
        send(gate, {:waking, self()})

        receive do
          :go -> :ok
        after
          5_000 -> :ok
        end
      end

      if Agent.get_and_update(machine, &{&1.wakes, %{&1 | awake: &1.awake or &1.wakes}}),
        do: {:ok, :waking},
        else: {:error, %Ravix.Fountain.Error{status: 503, code: "sandbox_unavailable"}}
    end

    defp machine_call(conn, _call, machine) do
      status = if Agent.get(machine, & &1.awake), do: "running", else: "warm"
      Plug.Conn.send_resp(conn, 200, ~s({"status":"#{status}"}))
    end

    test "+ wakes it, says so in the tab, and attaches once it is up", ctx do
      asleep(ctx, true, self())
      %{view: view} = open(ctx, ctx.owner)

      id = new_terminal(view)
      assert_receive {:waking, probe}, 2_000
      waking = "#shell-pane-#{id} #shell-asleep-#{id}"
      assert has_element?(view, "#{waking}.busy [role=status]", "Waking the machine…")
      refute has_element?(view, "#shell-pane-#{id} .shell-status")

      # The pane measures itself while the machine wakes: held, not attached.
      view
      |> element("#shell-#{id}")
      |> render_hook("shell-attach", %{id: id, cols: 120, rows: 33})

      refute_received {SpritesFake, :exec, {:spawn, _}}

      # Awake: attached at the size the pane asked for, and connected.
      send(probe, :go)
      render_async(view, 5_000)
      assert_push_event(view, "shell:reset", %{id: ^id}, @ready_ms)
      assert_receive {SpritesFake, :exec, {:spawn, query}}
      assert {query["cols"], query["rows"]} == {"120", "33"}
      assert await_output(view, id, "$ ")
      refute has_element?(view, "#shell-asleep-#{id}")
      refute has_element?(view, "#shell-pane-#{id} .shell-status")
      refute render(view) =~ "did not answer"
    end

    test "one that fell asleep after the page opened is woken too, by the track's own state",
         ctx do
      SpritesFake.install(fn conn, call ->
        if call.method == "POST",
          do: SpritesFake.exec_response(conn, ""),
          else: status(conn, call)
      end)

      %{view: view} = open(ctx, ctx.owner)

      # The dock's status read (at mount) found it running; the track hears
      # since that its dedicated machine is suspended.
      track_as(:owner,
        setup_state: "ready",
        status: :ready,
        sandbox_layout: :dedicated,
        sandbox_suspended_at: DateTime.utc_now()
      )

      Ravix.Hub.publish(ctx.project.id, :machine, track_id: ctx.track.id)
      assert_eventually(fn -> has_element?(view, "#track-machine-state", "Asleep") end)
      SpritesFake.calls()

      id = new_terminal(view)

      view
      |> element("#shell-#{id}")
      |> render_hook("shell-attach", %{id: id, cols: 90, rows: 25})

      render_async(view, 5_000)
      assert_received :fountain_wake
      assert_receive {SpritesFake, :exec, {:spawn, %{"cols" => "90", "rows" => "25"}}}, 2_000
    end

    test "a pane that asks before the wake has answered is attached when it does", ctx do
      asleep(ctx)
      %{view: view} = open(ctx, ctx.owner)
      id = new_terminal(view)
      render_async(view, 5_000)
      assert has_element?(view, "#shell-pane-#{id} .shell-status", "Connecting")

      attach(view, id, 90, 20)
      assert_receive {SpritesFake, :exec, {:spawn, %{"cols" => "90", "rows" => "20"}}}
    end

    test "one that stays asleep says so in the tab, and Wake tries again", ctx do
      machine = asleep(ctx, false)
      %{view: view} = open(ctx, ctx.owner)
      id = new_terminal(view)

      view
      |> element("#shell-#{id}")
      |> render_hook("shell-attach", %{id: id, cols: 80, rows: 24})

      render_async(view, 5_000)

      empty = "#shell-asleep-#{id}"
      assert has_element?(view, "#{empty} [role=status]", "Machine is asleep")
      assert has_element?(view, "#{empty} .mark")
      refute has_element?(view, "#{empty}.busy")
      refute_received {SpritesFake, :exec, {:spawn, _}}

      test = self()
      Agent.update(machine, &%{&1 | wakes: true, gate: test})
      view |> element("#{empty} button", "Wake") |> render_click()
      assert_receive {:waking, probe}, 2_000
      assert has_element?(view, "#{empty}.busy", "Waking the machine…")
      send(probe, :go)
      render_async(view, 5_000)
      # The wake's answer attaches the tab, and the shell connects in its own
      # process: `render_async` settles the first, the shell's `:ready` (the
      # pane's reset) the second. The fake reports the spawn before it
      # answers the upgrade, so it is in the mailbox by then.
      assert_push_event(view, "shell:reset", %{id: ^id}, @ready_ms)
      assert_received {SpritesFake, :exec, {:spawn, %{"cols" => "80"}}}
      assert await_output(view, id, "$ ")
      refute has_element?(view, empty)
    end

    test "a wake Fountain refuses says why in the tab, in a prompt's words, until Wake again",
         ctx do
      asleep(ctx, false)

      refusal = %Ravix.Fountain.Error{
        status: 402,
        code: "insufficient_credits",
        message: "insufficient_credits"
      }

      expect(Tracks, :wake, fn _, _ -> {:error, refusal} end)
      %{view: view} = open(ctx, ctx.owner)
      id = new_terminal(view)
      render_async(view, 5_000)

      empty = "#shell-asleep-#{id}"
      assert has_element?(view, "#{empty} [role=status]", "Machine is asleep")
      assert has_element?(view, "#{empty} .dimmer", "out of credits")
      assert has_element?(view, "#{empty} button", "Wake")
      refute render(view) =~ "insufficient_credits"

      # A second wake clears the reason while it runs and says its own.
      test = self()

      expect(Tracks, :wake, fn _, _ ->
        send(test, {:waking, self()})

        receive do
          :go -> {:error, %{refusal | status: 410, code: "conversation_terminated"}}
        after
          5_000 -> :ok
        end
      end)

      view |> element("#{empty} button", "Wake") |> render_click()
      assert_receive {:waking, wake}, 2_000
      refute has_element?(view, "#{empty} .dimmer")
      send(wake, :go)
      render_async(view, 5_000)
      assert has_element?(view, "#{empty} .dimmer", "has ended")
    end

    test "an existing tab asks to attach while it sleeps: woken first, never a timeout", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      asleep(ctx, true, self())
      %{view: view} = open(ctx, ctx.owner)

      view
      |> element("#shell-#{tab.id}")
      |> render_hook("shell-attach", %{id: tab.id, cols: 100, rows: 30, select: true})

      assert_receive {:waking, probe}, 2_000
      assert has_element?(view, "#shell-asleep-#{tab.id}", "Waking the machine…")
      send(probe, :go)
      render_async(view, 5_000)
      # The wake's answer attaches the tab, and the shell connects in its own
      # process: `render_async` settles the first, the shell's `:ready` (the
      # pane's reset) the second. The fake reports the spawn before it
      # answers the upgrade, so it is in the mailbox by then.
      tab_id = tab.id
      assert_push_event(view, "shell:reset", %{id: ^tab_id}, @ready_ms)
      assert_received {SpritesFake, :exec, {:spawn, _}}
      assert await_output(view, tab.id, "$ ")
    end
  end

  test "a machine that did not answer says so without naming the provider, and Retry retries",
       ctx do
    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)

    # Nothing listens on port 1: the machine does not answer the terminal.
    stub(Ravix.Config, :sprites, fn -> %{ctx.cfg | base_url: "http://127.0.0.1:1"} end)
    view |> element("#shell-#{id}") |> render_hook("shell-attach", %{id: id, cols: 100, rows: 30})
    render(view)
    render(view)
    pane = "#shell-pane-#{id} .shell-status"
    assert_eventually(fn -> has_element?(view, pane, "The machine didn't answer.") end)
    stub(Ravix.Config, :sprites, fn -> ctx.cfg end)

    # A timeout is said the same way, in the app's words.
    timeout = %Ravix.Sprites.Error{
      status: 502,
      message: "Sprites did not answer the terminal request in time."
    }

    tell(view, id, {:failed, timeout})
    assert has_element?(view, pane, "The machine didn't answer.")
    refute has_element?(view, "#{pane} button", "Close tab")
    refute render(view) =~ "Sprites"

    # Retry wakes the machine (Fountain answers awake, since it is up) and
    # attaches again, at the size the pane last asked for.
    test = self()

    AwakeReads.stub()

    stub(Ravix.Fountain, :wake, fn _client, "c1" ->
      send(test, {:waking, self()})

      receive do
        :go -> {:ok, :awake}
      after
        5_000 -> {:ok, :awake}
      end
    end)

    view |> element("#{pane} button", "Retry") |> render_click()
    assert_receive {:waking, probe}, 2_000
    assert has_element?(view, "#shell-asleep-#{id}", "Waking the machine…")
    send(probe, :go)
    render_async(view, 5_000)
    # Attached once the wake answers; connected once the shell is ready.
    assert_push_event(view, "shell:reset", %{id: ^id}, @ready_ms)
    assert_received {SpritesFake, :exec, {:spawn, %{"cols" => "100", "rows" => "30"}}}
  end

  test "Wake and Retry answer only this page's own tabs, in a held state", ctx do
    other = insert_user()
    insert_track_member(ctx.track, other)
    {:ok, theirs} = Terminal.open_tab(other, ctx.track.id)
    %{view: view} = open(ctx, ctx.owner)
    id = new_terminal(view)
    attach(view, id)
    SpritesFake.calls()

    # Somebody else's tab, one that does not exist, and one of this page's
    # that is connected: none of them wakes anything.
    for target <- [theirs.id, "not-a-tab", id] do
      view |> element("#shell-#{id}") |> render_hook("shell-wake", %{id: target})
    end

    render_async(view)
    refute_received :fountain_wake
    refute has_element?(view, "#shell-asleep-#{id}")
  end

  test "a signed-out page's Wake is refused before it reaches the machine", ctx do
    # The first wake reaches Fountain, which refuses it (503).
    asleep(ctx, false)
    %{view: view, hash: hash} = open(ctx, ctx.owner)
    id = new_terminal(view)
    render_async(view, 5_000)
    assert has_element?(view, "#shell-asleep-#{id}", "Machine is asleep")
    assert has_element?(view, "#shell-asleep-#{id} .dimmer", "not available right now")
    assert_received :fountain_wake

    Accounts.end_session(hash)

    # The page is sent to sign in; it is nested, so it goes by exiting.
    Process.flag(:trap_exit, true)

    try do
      view |> element("#shell-asleep-#{id} button", "Wake") |> render_click()
    catch
      :exit, _reason -> :gone
    end

    assert_receive {:EXIT, _pid, {:shutdown, {:redirect, %{to: "/login"}}}}, 2_000

    refute_received :fountain_wake
  end

  test "+ is a menu: New terminal with its shortcut, and Run script; tabs carry icons", ctx do
    %{view: view} = open(ctx, ctx.owner)

    assert has_element?(
             view,
             "#dock-add > #dock-add-trigger[popovertarget=dock-add-menu][aria-haspopup=menu]"
           )

    assert has_element?(view, "#dock-add[phx-hook=ChipMenu] > #dock-add-menu[popover][role=menu]")
    refute has_element?(view, "#dock-add-trigger[phx-click]")

    assert has_element?(
             view,
             "#dock-shell-new[role=menuitem][data-chip-close]",
             "New terminal"
           )

    assert has_element?(view, "#dock-shell-new kbd", "⌃`")
    assert has_element?(view, "#dock-run-script[role=menuitem]", "Run script")

    for label <- ["Commands", "Machine stats"],
        do: assert(has_element?(view, ".dock-tabs .dock-tab:has(svg)", label))

    # Nothing opens until the menu's item is chosen.
    refute has_element?(view, "[data-shell-tab]")
    tab = new_terminal(view)
    assert has_element?(view, ~s([data-shell-tab="#{tab}"] .dock-tab svg))

    assert has_element?(
             view,
             ~s([data-shell-tab="#{tab}"] .dock-shell-close[aria-label^="Close"])
           )

    view |> element("#dock-run-script") |> render_click()
    assert has_element?(view, "button[phx-value-name=preview].selected")
  end

  test "a Read member sees their tabs but has no + to open one, and is refused one", ctx do
    reader = insert_user()
    insert_track_member(ctx.track, reader, role: :read)
    {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
    track_as(:read)
    %{view: view} = open(ctx, reader)

    refute has_element?(view, "#dock-shell-new")
    # The + menu still offers what a reader may do: the run script's tab.
    assert has_element?(view, "#dock-add-menu[popover] #dock-run-script", "Run script")
    view |> element("#track-terminal") |> render_hook("shell-new", %{})
    refute has_element?(view, "[data-shell-tab]")

    # Nor may they wake the machine through somebody else's tab id.
    view |> element("#track-terminal") |> render_hook("shell-wake", %{id: tab.id})
    render_async(view)
    refute_received :fountain_wake
    refute_received {SpritesFake, :exec, {:spawn, _}}
    assert {:ok, []} = Terminal.tabs(reader, ctx.track.id)
  end

  # The track page as a member at `level` sees it;
  # `seen` is what the page is told of the track beyond its row.
  defp track_as(level, seen \\ []) do
    stub(Tracks, :get, fn _, id, _opts ->
      {:ok,
       %{
         track:
           Repo.get!(Track, id)
           |> Tracks.present(role: :member, level: level)
           |> Map.merge(Map.new(seen)),
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
