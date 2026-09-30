defmodule Ravix.Sprites.PtyTest do
  # Real sockets against the fake Sprites exec WebSocket.
  use ExUnit.Case, async: true

  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Pty
  alias Ravix.SpritesFake, as: Fake

  @spawn {:spawn,
          %{
            argv: ["bash", "-l"],
            dir: "/home/sprite/work/kyoto",
            env: [{"TERM", "xterm-256color"}],
            cols: 120,
            rows: 40
          }}

  setup do
    cfg = Fake.start_proxy()

    # The REST half of Sprites (the kill) goes through `Req.Test`, as every
    # other Sprites call in the suite does; it ends the fake's session.
    Fake.install(fn conn, _call -> Fake.kill_exec(conn, cfg) end)
    %{cfg: cfg}
  end

  # Everything the socket says until `pred` has been seen, arming it for each
  # packet the way `Ravix.Terminal.Shell` does. Messages that are not the
  # socket's are put back for the test to assert on.
  defp read_until(pty, pred, acc \\ [], other \\ []) do
    if Enum.any?(acc, pred) do
      Enum.each(Enum.reverse(other), &send(self(), &1))
      {pty, acc}
    else
      Pty.arm(pty)

      receive do
        message ->
          case Pty.handle(pty, message) do
            {:ok, pty, events} -> read_until(pty, pred, acc ++ events, other)
            :unknown -> read_until(pty, pred, acc, [message | other])
            {:error, reason} -> flunk("socket failed: #{inspect(reason)}")
          end
      after
        2_000 -> flunk("never saw it; had #{inspect(acc)}")
      end
    end
  end

  defp output(events), do: for({:data, bytes} <- events, into: "", do: bytes)

  test "a new shell is a TTY exec in the worktree, detachable, and says its session id", %{
    cfg: cfg
  } do
    assert {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    assert_receive {Fake, :exec, {:spawn, query}}
    assert query["tty"] == "true"
    assert query["stdin"] == "true"
    assert query["detachable"] == "true"
    assert query["dir"] == "/home/sprite/work/kyoto"
    assert query["cols"] == "120" and query["rows"] == "40"
    assert query["max_run_after_disconnect"] == "30m"
    assert query["env"] == "TERM=xterm-256color"

    {_pty, events} = read_until(pty, &match?({:data, "$ "}, &1), events)
    assert {:session, "s1"} in events

    # Sprites pinged on the way in; the client answered, and said nothing of it.
    assert_receive {Fake, :exec, {:pong, "s1"}}
    refute Enum.any?(events, &match?({:ping, _}, &1))
  end

  test "a socket that closes without an exit is closed, not ended", %{cfg: cfg} do
    {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    {pty, _} = read_until(pty, &match?({:data, "$ "}, &1), events)

    Fake.drop_exec(cfg, "s1")
    {_pty, events} = read_until(pty, &(&1 == :closed))
    refute Enum.any?(events, &match?({:exit, _}, &1))
    assert %{"s1" => %{alive: true}} = Fake.exec_sessions(cfg)
  end

  test "a message that is not the socket's is not the terminal's", %{cfg: cfg} do
    {:ok, pty, _events} = Pty.open(cfg, "sprite-7", @spawn)
    assert Pty.handle(pty, {:something, :else}) == :unknown
    Pty.detach(pty)
  end

  test "typing, resizing and exiting", %{cfg: cfg} do
    {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    {pty, _} = read_until(pty, &match?({:data, "$ "}, &1), events)

    assert {:ok, pty} = Pty.input(pty, "ls\r")
    {pty, events} = read_until(pty, &match?({:data, _}, &1))
    {pty, events} = read_until(pty, &(output([&1]) =~ "$ "), events)
    assert output(events) =~ "ran: ls"

    assert {:ok, pty} = Pty.resize(pty, 100, 30)
    assert_receive {Fake, :exec, {:resize, "s1", 100, 30}}

    {:ok, pty} = Pty.input(pty, "exit\r")
    {_pty, events} = read_until(pty, &match?({:exit, _}, &1))
    assert {:exit, 0} in events
  end

  test "a large paste goes over in several frames and arrives whole", %{cfg: cfg} do
    {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    {pty, _} = read_until(pty, &match?({:data, "$ "}, &1), events)
    paste = String.duplicate("x", 150_000)

    assert {:ok, _pty} = Pty.input(pty, paste)

    received =
      Stream.repeatedly(fn ->
        assert_receive {Fake, :exec, {:input, "s1", chunk}}
        chunk
      end)
      |> Enum.reduce_while("", fn chunk, acc ->
        acc = acc <> chunk
        if byte_size(acc) < byte_size(paste), do: {:cont, acc}, else: {:halt, acc}
      end)

    assert received == paste
  end

  test "detaching leaves the shell running, and attaching replays its output", %{cfg: cfg} do
    {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    {pty, _} = read_until(pty, &match?({:data, "$ "}, &1), events)
    {:ok, pty} = Pty.input(pty, "make\r")
    {pty, _} = read_until(pty, &(output([&1]) =~ "ran: make"))
    :ok = Pty.detach(pty)

    assert %{"s1" => %{alive: true}} = Fake.exec_sessions(cfg)

    assert {:ok, pty, events} = Pty.open(cfg, "sprite-7", {:attach, "s1"})
    assert_receive {Fake, :exec, {:attach, "s1"}}
    {_pty, events} = read_until(pty, &(output([&1]) =~ "ran: make"), events)
    assert {:session, "s1"} in events
    assert output(events) =~ "$ make\r\r\nran: make"
  end

  test "attaching to a shell Sprites no longer has is a 404", %{cfg: cfg} do
    assert {:error, %Error{status: 404}} = Pty.open(cfg, "sprite-7", {:attach, "gone"})
  end

  test "a wrong token is refused, and no token is unconfigured", %{cfg: cfg} do
    assert {:error, %Error{status: 401, message: message}} =
             Pty.open(%{cfg | token: "wrong"}, "sprite-7", @spawn)

    assert message =~ "refused the terminal (401)"
    assert {:error, {:unconfigured, :sprites}} = Pty.open(nil, "sprite-7", @spawn)
  end

  test "kill ends an attached shell with a hang-up, and a missing one is already ended", %{
    cfg: cfg
  } do
    {:ok, pty, events} = Pty.open(cfg, "sprite-7", @spawn)
    {pty, _} = read_until(pty, &match?({:data, "$ "}, &1), events)

    assert :ok = Pty.kill(cfg, "sprite-7", "s1")

    assert [%{method: "POST", path: "/v1/sprites/sprite-7/exec/s1/kill", query: query}] =
             Fake.calls()

    assert URI.decode_query(query)["signal"] == "SIGHUP"
    {_pty, events} = read_until(pty, &match?({:exit, _}, &1))
    assert {:exit, 129} in events
    assert %{"s1" => %{alive: false}} = Fake.exec_sessions(cfg)

    assert :ok = Pty.kill(cfg, "sprite-7", "s1")
    assert {:error, {:unconfigured, :sprites}} = Pty.kill(nil, "sprite-7", "s1")
  end

  test "kill reports a machine it cannot reach, and a refusal", %{cfg: cfg} do
    Fake.install(fn conn, _call -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{status: 502, message: "Could not reach" <> _}} =
             Pty.kill(cfg, "sprite-7", "s1")

    Fake.install(fn conn, _call -> Plug.Conn.send_resp(conn, 500, "no") end)

    assert {:error, %Error{status: 502, message: "Sprites said 500" <> _}} =
             Pty.kill(cfg, "sprite-7", "s1")
  end

  test "a machine that cannot be reached at all" do
    cfg = %Ravix.Config.Sprites{token: "t", base_url: "http://127.0.0.1:1"}

    assert {:error, %Error{status: 502, message: "Could not reach Sprites" <> _}} =
             Pty.open(cfg, "sprite-7", @spawn)
  end
end
