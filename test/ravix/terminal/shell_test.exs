defmodule Ravix.Terminal.ShellTest do
  # Interactive terminals end to end below the page: `Ravix.Terminal`'s
  # entry points, the `Shell` each attachment runs as, and real sockets to
  # the fake Sprites exec WebSocket.
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Fountain.FakeTransport
  alias Ravix.SpritesFake
  alias Ravix.Terminal
  alias Ravix.Terminal.Shell
  alias Ravix.Terminal.Store
  alias Ravix.Terminal.Tab

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, slug: "kyoto")
    {_token, session} = insert_session(owner)

    cfg = SpritesFake.start_proxy()
    stub(Ravix.Config, :sprites, fn -> cfg end)
    SpritesFake.install(fn conn, _call -> SpritesFake.kill_exec(conn, cfg) end)
    fountain(project, "sprite-7")

    {:ok, owner: owner, project: project, track: track, hash: session.token_hash, cfg: cfg}
  end

  defp fountain(project, sprite) do
    sandbox = %{id: "sb-1", sprite_name: sprite}

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
          {%{method: "GET", path: "/api/sandboxes/sb-1"}, {200, [], %{data: sandbox}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
  end

  # Output for `tab` until it contains `text`.
  defp await_output(tab_id, text, acc \\ "") do
    if String.contains?(acc, text) do
      acc
    else
      receive do
        {:terminal, ^tab_id, {:data, bytes}} -> await_output(tab_id, text, acc <> bytes)
      after
        2_000 -> flunk("never saw #{inspect(text)}; had #{inspect(acc)}")
      end
    end
  end

  defp attached(ctx, tab, size \\ %{cols: 100, rows: 30}) do
    {:ok, shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id, size)
    assert_receive {:terminal, tab_id, :ready} when tab_id == tab.id, 2_000
    shell
  end

  describe "tabs" do
    test "are numbered from the lowest free number, per person", ctx do
      assert {:ok, %Tab{number: 1} = one} = Terminal.open_tab(ctx.owner, ctx.track.id)
      assert {:ok, %Tab{number: 2}} = Terminal.open_tab(ctx.owner, ctx.track.id)
      assert :ok = Terminal.close_tab(ctx.owner, ctx.track.id, one.id)

      assert {:ok, %Tab{number: 1, sprite: "sprite-7"}} =
               Terminal.open_tab(ctx.owner, ctx.track.id)

      assert {:ok, tabs} = Terminal.tabs(ctx.owner, ctx.track.id)
      assert Enum.map(tabs, &Tab.label/1) == ["Terminal 1", "Terminal 2"]
    end

    test "are refused past the limit, and without a machine connection", ctx do
      for _ <- 1..Terminal.max_tabs(), do: {:ok, _} = Terminal.open_tab(ctx.owner, ctx.track.id)

      assert {:error, {:conflict, "terminal_limit", _}} =
               Terminal.open_tab(ctx.owner, ctx.track.id)

      stub(Ravix.Config, :sprites, fn -> nil end)

      assert {:error, {:unavailable, "no_exec", _}} =
               Terminal.open_tab(ctx.owner, ctx.track.id)
    end

    test "belong to their person: nobody else lists, attaches to or closes them", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      member = insert_user()
      insert_track_member(ctx.track, member)
      {_token, member_session} = insert_session(member)
      stranger = insert_user()

      assert {:ok, []} = Terminal.tabs(member, ctx.track.id)

      assert {:error, :not_found} =
               Terminal.attach(member, member_session.token_hash, ctx.track.id, tab.id)

      assert {:error, :not_found} = Terminal.close_tab(member, ctx.track.id, tab.id)
      assert {:error, :not_found} = Terminal.tabs(stranger, ctx.track.id)
      assert {:error, :not_found} = Terminal.open_tab(stranger, ctx.track.id)

      # Another person's session, even for the right person's tab, is not this one.
      assert {:error, :not_found} =
               Terminal.attach(ctx.owner, member_session.token_hash, ctx.track.id, tab.id)

      assert {:error, :not_found} = Terminal.attach(ctx.owner, nil, ctx.track.id, tab.id)
      assert Store.get(ctx.track.id, ctx.owner.id, tab.id)
    end
  end

  describe "an attached terminal" do
    test "starts a TTY shell in the worktree, types, resizes and records its session", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      shell = attached(ctx, tab, %{cols: 132, rows: 43})

      assert_receive {SpritesFake, :exec, {:spawn, query}}
      assert query["dir"] == "/home/sprite/work/kyoto"
      assert query["cols"] == "132" and query["rows"] == "43"
      # RAV-88: a prompt of its own for this session, naming the directory
      # and not the machine's user or host, after the login files bash reads.
      assert query["path"] == "bash"
      assert query["cmd"] =~ "--rcfile"
      assert query["cmd"] =~ ". ~/.bash_profile"
      assert query["cmd"] =~ ~S"PS1='\W \$ '"
      assert await_output(tab.id, "$ ")

      Terminal.input(tab.id, "git status\r")
      assert await_output(tab.id, "ran: git status")

      # The size it was opened at is not sent again: that would only redraw
      # the prompt.
      Terminal.resize(tab.id, 132, 43)
      refute_receive {SpritesFake, :exec, {:resize, _, _, _}}, 100

      Terminal.resize(tab.id, 90, 20)
      assert_receive {SpritesFake, :exec, {:resize, "s1", 90, 20}}

      # A size no terminal has is not passed on.
      Terminal.resize(tab.id, 0, 99_999)
      refute_receive {SpritesFake, :exec, {:resize, _, 0, _}}, 100

      # Attaching again is the same attachment, and only this page reaches it.
      assert {:ok, ^shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id)
      assert Shell.whereis(self(), tab.id) == shell

      Task.async(fn -> Terminal.input(tab.id, "rm -rf /\r") end) |> Task.await()
      refute_receive {SpritesFake, :exec, {:input, _, "rm -rf /\r"}}, 100

      assert %Tab{session_id: "s1"} = Store.get(ctx.track.id, ctx.owner.id, tab.id)
    end

    test "survives its page going and is re-attached with its scrollback", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      test = self()

      # The first page: attaches, types, and goes away.
      page =
        Task.async(fn ->
          {:ok, shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id)
          await_output(tab.id, "$ ")
          Terminal.input(tab.id, "iex -S mix\r")
          await_output(tab.id, "ran: iex -S mix")
          send(test, {:shell, shell})
        end)

      Task.await(page)
      assert_receive {:shell, shell}
      # The page has already gone, so the shell may have too by the time it is
      # monitored (`:noproc`); either way it must stop, and without a crash.
      ref = Process.monitor(shell)

      assert_receive {:DOWN, ^ref, :process, ^shell, reason} when reason in [:normal, :noproc],
                     2_000

      assert %{"s1" => %{alive: true}} = SpritesFake.exec_sessions(ctx.cfg)
      assert %Tab{session_id: "s1"} = Store.get(ctx.track.id, ctx.owner.id, tab.id)

      # The next page, which is this process.
      attached(ctx, tab)
      assert_receive {SpritesFake, :exec, {:attach, "s1"}}
      assert await_output(tab.id, "ran: iex -S mix") =~ "$ iex -S mix"
      # Drawn at this page's size, not the one it was left at.
      assert_receive {SpritesFake, :exec, {:resize, "s1", 100, 30}}
    end

    test "keeps the token, the session and the output out of its crash report", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      shell = attached(ctx, tab)
      await_output(tab.id, "$ ")

      {:status, ^shell, _module, items} = :sys.get_status(shell)
      report = inspect(items)
      refute report =~ ctx.cfg.token
      refute report =~ ctx.hash
      refute report =~ "session_hash"
    end

    test "whose socket drops says so and keeps its shell for the next attach", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      shell = attached(ctx, tab)
      await_output(tab.id, "$ ")
      tab_id = tab.id
      eventually(fn -> assert Store.get(ctx.track.id, ctx.owner.id, tab_id).session_id end)
      ref = Process.monitor(shell)

      SpritesFake.drop_exec(ctx.cfg, "s1")

      assert_receive {:terminal, ^tab_id, :disconnected}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^shell, :normal}
      assert %Tab{session_id: "s1"} = Store.get(ctx.track.id, ctx.owner.id, tab.id)

      # Reconnect: the same shell, with what it printed.
      attached(ctx, tab)
      assert_receive {SpritesFake, :exec, {:attach, "s1"}}
      assert await_output(tab.id, "$ ")
    end

    test "that its page is not keeping up with stalls rather than buffering", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      shell = attached(ctx, tab)
      await_output(tab.id, "$ ")
      tab_id = tab.id

      # A page three hundred messages behind: the shell stops reading the
      # socket, so what is typed now is not drawn until the page catches up.
      for n <- 1..300, do: send(self(), {:backlog, n})
      Terminal.input(tab.id, "yes\r")
      assert_receive {SpritesFake, :exec, {:input, "s1", "yes\r"}}
      Terminal.input(tab.id, "\r")
      eventually(fn -> assert :sys.get_state(shell).paused? end)

      for n <- 1..300, do: assert_received({:backlog, ^n})
      assert await_output(tab_id, "ran: yes")
    end

    test "that exits is forgotten", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      attached(ctx, tab)
      await_output(tab.id, "$ ")

      Terminal.input(tab.id, "exit\r")
      tab_id = tab.id
      assert_receive {:terminal, ^tab_id, {:exited, 0}}, 2_000
      refute Store.get(ctx.track.id, ctx.owner.id, tab.id)
    end

    test "that is closed is ended on the machine", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      _shell = attached(ctx, tab)
      await_output(tab.id, "$ ")
      tab_id = tab.id
      eventually(fn -> assert Store.get(ctx.track.id, ctx.owner.id, tab_id).session_id end)

      assert :ok = Terminal.close_tab(ctx.owner, ctx.track.id, tab.id)
      assert_receive {:terminal, ^tab_id, {:exited, 129}}, 2_000
      assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
      refute Store.get(ctx.track.id, ctx.owner.id, tab.id)
    end

    test "whose shell has gone while nobody was attached says so and is forgotten", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      Store.put_session(tab.id, ctx.owner.id, "long-gone")

      {:ok, _shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id)
      tab_id = tab.id
      assert_receive {:terminal, ^tab_id, {:ended, :lost}}, 2_000
      refute Store.get(ctx.track.id, ctx.owner.id, tab.id)
    end

    test "whose machine does not answer keeps its tab, so attaching again is a retry", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      # Nothing listens on port 1: the machine did not answer at all.
      stub(Ravix.Config, :sprites, fn -> %{ctx.cfg | base_url: "http://127.0.0.1:1"} end)

      {:ok, _shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id)
      tab_id = tab.id
      assert_receive {:terminal, ^tab_id, {:failed, %Ravix.Sprites.Error{status: 502}}}, 2_000
      assert %Tab{session_id: nil} = Store.get(ctx.track.id, ctx.owner.id, tab.id)

      stub(Ravix.Config, :sprites, fn -> ctx.cfg end)
      attached(ctx, tab)
      assert_receive {SpritesFake, :exec, {:spawn, _query}}
      assert await_output(tab.id, "$ ")
    end

    test "that cannot reach the machine says why", ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      stub(Ravix.Config, :sprites, fn -> %{ctx.cfg | token: "revoked-token"} end)

      {:ok, _shell} = Terminal.attach(ctx.owner, ctx.hash, ctx.track.id, tab.id)
      tab_id = tab.id

      assert_receive {:terminal, ^tab_id, {:ended, %Ravix.Sprites.Error{status: 401}}}, 2_000
    end
  end

  describe "revocation ends the terminal at once" do
    setup ctx do
      {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
      shell = attached(ctx, tab)
      Terminal.detach("not-a-tab")
      await_output(tab.id, "$ ")
      tab_id = tab.id
      eventually(fn -> assert Store.get(ctx.track.id, ctx.owner.id, tab_id).session_id end)
      %{tab: tab, shell: shell}
    end

    test "when the session is signed out", ctx do
      ref = Process.monitor(ctx.shell)
      Accounts.end_session(ctx.hash)

      tab_id = ctx.tab.id
      assert_receive {:terminal, ^tab_id, {:ended, :revoked}}, 2_000
      assert_receive {:DOWN, ^ref, :process, _, :normal}
      assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
      refute Store.get(ctx.track.id, ctx.owner.id, ctx.tab.id)
    end

    test "when the track is closed and the hub says so", ctx do
      Repo.update_all(
        from(t in Ravix.Tracks.Track, where: t.id == ^ctx.track.id),
        set: [closed_at: DateTime.utc_now()]
      )

      Ravix.Hub.publish(ctx.project.id, :tracks, track_id: ctx.track.id)

      tab_id = ctx.tab.id
      assert_receive {:terminal, ^tab_id, {:ended, :revoked}}, 2_000
      assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
    end

    test "but not when an event about another track arrives", ctx do
      Ravix.Hub.publish(ctx.project.id, :people, track_id: "somewhere-else")
      tab_id = ctx.tab.id
      refute_receive {:terminal, ^tab_id, {:ended, _}}, 200
      assert Process.alive?(ctx.shell)
    end
  end

  test "a revocation nobody announced is still found by the backstop", ctx do
    member = insert_user()
    insert_track_member(ctx.track, member)
    {_token, session} = insert_session(member)
    {:ok, tab} = Terminal.open_tab(member, ctx.track.id)
    {:ok, shell} = Terminal.attach(member, session.token_hash, ctx.track.id, tab.id)
    tab_id = tab.id
    assert_receive {:terminal, ^tab_id, :ready}, 2_000

    # The seat goes straight from the database, with no hub event: a
    # partition ate the notice. The fifteen-second re-check is what notices;
    # its message is delivered here rather than waited for.
    Repo.delete_all(from(m in Ravix.Tracks.TrackMember, where: m.user_id == ^member.id))
    send(shell, :recheck)

    assert_receive {:terminal, ^tab_id, {:ended, :revoked}}, 2_000
  end

  test "the backstop leaves a terminal alone while access stands", ctx do
    {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
    shell = attached(ctx, tab)
    send(shell, :recheck)
    send(shell, :not_for_the_shell)
    tab_id = tab.id
    refute_receive {:terminal, ^tab_id, {:ended, _}}, 100
    assert Process.alive?(shell)
  end

  test "a removed member loses their terminal at once", ctx do
    member = insert_user()
    insert_track_member(ctx.track, member)
    {_token, session} = insert_session(member)
    assert {:ok, _} = Access.track_access(member, ctx.track.id)

    {:ok, tab} = Terminal.open_tab(member, ctx.track.id)
    {:ok, _shell} = Terminal.attach(member, session.token_hash, ctx.track.id, tab.id)
    tab_id = tab.id
    assert_receive {:terminal, ^tab_id, :ready}, 2_000
    await_output(tab.id, "$ ")
    eventually(fn -> assert Store.get(ctx.track.id, member.id, tab_id).session_id end)

    assert {:ok, _people} = Ravix.People.remove(ctx.owner, ctx.track.id, member.login)

    assert_receive {:terminal, ^tab_id, {:ended, :revoked}}, 2_000
    assert %{"s1" => %{alive: false}} = SpritesFake.exec_sessions(ctx.cfg)
    refute Store.get(ctx.track.id, member.id, tab.id)
  end

  test "a session that runs out ends the terminal without any other message", ctx do
    {_token, session} =
      insert_session(ctx.owner, expires_at: DateTime.add(DateTime.utc_now(), 400, :millisecond))

    {:ok, tab} = Terminal.open_tab(ctx.owner, ctx.track.id)
    {:ok, _shell} = Terminal.attach(ctx.owner, session.token_hash, ctx.track.id, tab.id)
    tab_id = tab.id
    assert_receive {:terminal, ^tab_id, :ready}, 2_000

    assert_receive {:terminal, ^tab_id, {:ended, :revoked}}, 3_000
    refute Store.get(ctx.track.id, ctx.owner.id, tab.id)
  end

  # The session id arrives on the socket a moment after `:ready`.
  defp eventually(fun, tries \\ 50) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if tries == 0, do: reraise(error, __STACKTRACE__)

      receive do
      after
        20 -> eventually(fun, tries - 1)
      end
  end
end
