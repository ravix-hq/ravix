defmodule Ravix.Sprites.TunnelTest do
  use ExUnit.Case, async: true

  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Tunnel
  alias Ravix.Sprites.Tunnel.HTTP
  alias Ravix.SpritesFake, as: Fake

  setup do
    %{cfg: Fake.start_proxy(), app: Fake.start_app()}
  end

  # ── HTTP through a real tunnel ─────────────────────────────────────────

  test "an HTTP request goes through the tunnel and the chunked body streams back", %{
    cfg: cfg,
    app: app
  } do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)

    assert {:ok, 200, headers, body} =
             HTTP.request(tunnel, "GET", "/stream", [{"host", "preview.test"}], nil)

    assert {"transfer-encoding", "chunked"} in headers

    timed = Enum.map(body, fn chunk -> {chunk, System.monotonic_time(:millisecond)} end)
    assert Enum.map_join(timed, &elem(&1, 0)) == Enum.map_join(1..5, &"chunk #{&1}\n")

    # The first chunk was handed over before the server sent the rest, which
    # is what makes it a stream rather than a buffer.
    {_first, first_at} = List.first(timed)
    {_last, last_at} = List.last(timed)
    assert last_at - first_at >= 100

    Tunnel.close(tunnel)
  end

  test "a content-length body ends exactly where it says", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)

    assert {:ok, 200, headers, body} =
             HTTP.request(tunnel, "get", "/fixed", [{"host", "preview.test"}], nil)

    assert {"content-length", "12"} in headers
    assert Enum.join(body) == "hello, fixed"
    Tunnel.close(tunnel)
  end

  test "a 204 and a HEAD have no body to wait for", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    assert {:ok, 204, _headers, body} = HTTP.request(tunnel, "GET", "/nobody", [], nil)
    assert Enum.to_list(body) == []
    Tunnel.close(tunnel)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    assert {:ok, 200, headers, body} = HTTP.request(tunnel, "HEAD", "/fixed", [], nil)
    assert {"content-length", "12"} in headers
    assert Enum.to_list(body) == []
    Tunnel.close(tunnel)
  end

  test "a body of known size is sent with a content-length and echoed back", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    payload = :crypto.strong_rand_bytes(300_000)

    assert {:ok, 200, _headers, body} =
             HTTP.request(tunnel, "POST", "/echo", [{"host", "preview.test"}], payload)

    assert IO.iodata_to_binary(Enum.to_list(body)) == payload
    Tunnel.close(tunnel)
  end

  test "a streamed body without a length is sent chunked, and empty pieces are skipped", %{
    cfg: cfg,
    app: app
  } do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    pieces = ["one ", "", "two ", ["th", "ree"]]

    assert {:ok, 200, _headers, body} =
             HTTP.request(tunnel, "POST", "/echo", [], Stream.map(pieces, & &1))

    assert Enum.join(body) == "one two three"
    Tunnel.close(tunnel)
  end

  test "hop-by-hop headers are the client's business, not the caller's", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)

    caller_headers = [
      {"Host", "preview.test"},
      {"Connection", "keep-alive, x-drop-me"},
      {"X-Drop-Me", "yes"},
      {"Keep-Alive", "timeout=5"},
      {"Transfer-Encoding", "gzip"},
      {"Upgrade", "h2c"},
      {"Accept-Encoding", "identity"},
      {"X-Keep-Me", "yes"}
    ]

    assert {:ok, 200, _headers, body} =
             HTTP.request(tunnel, "GET", "/headers", caller_headers, nil)

    seen = body |> Enum.join() |> Jason.decode!()

    assert seen["host"] == "preview.test"
    assert seen["connection"] == "close"
    assert seen["accept-encoding"] == "identity"
    assert seen["x-keep-me"] == "yes"
    refute Map.has_key?(seen, "x-drop-me")
    refute Map.has_key?(seen, "keep-alive")
    refute Map.has_key?(seen, "transfer-encoding")
    refute Map.has_key?(seen, "upgrade")
    Tunnel.close(tunnel)
  end

  test "a body with neither length nor chunking is read until the server closes", %{cfg: cfg} do
    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nuntil "
          )

        Process.sleep(50)
        :ok = :gen_tcp.send(socket, "close")
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    assert {:ok, 200, headers, body} = HTTP.request(tunnel, "GET", "/", [], nil)
    assert {"content-type", "text/plain"} in headers
    assert Enum.join(body) == "until close"

    # The close that ended the body ended the tunnel too.
    ref = Process.monitor(tunnel)
    assert_receive {:DOWN, ^ref, :process, ^tunnel, _reason}
  end

  test "a body that ends before its length raises from the stream", %{cfg: cfg} do
    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort")
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    assert {:ok, 200, _headers, body} = HTTP.request(tunnel, "GET", "/", [], nil)
    assert_raise Error, ~r/before the body ended/, fn -> Enum.to_list(body) end
  end

  test "a 100 Continue is skipped on the way to the answer", %{cfg: cfg} do
    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"
          )
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    assert {:ok, 201, _headers, body} = HTTP.request(tunnel, "POST", "/", [], "x")
    assert Enum.join(body) == "ok"
    Tunnel.close(tunnel)
  end

  test "an upstream that never answers is a 504 after the headers timeout", %{cfg: cfg} do
    port = Fake.tcp_server(fn socket -> Fake.read_request_head(socket) && Process.sleep(500) end)
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)

    assert {:error, %Error{status: 504}} =
             HTTP.request(tunnel, "GET", "/", [], nil, headers_timeout: 100)

    Tunnel.close(tunnel)
  end

  # ── WebSocket through a real tunnel ────────────────────────────────────

  test "an upgrade goes through the tunnel and leaves it as a raw duplex for frames", %{
    cfg: cfg,
    app: app
  } do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    headers = [
      {"host", "preview.test"},
      {"connection", "Upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-key", key},
      {"sec-websocket-version", "13"}
    ]

    assert {:ok, response_headers, leftover} = HTTP.upgrade(tunnel, "/ws", headers)
    expected = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    assert {"sec-websocket-accept", expected} in response_headers
    assert leftover == ""

    :ok = Tunnel.send_data(tunnel, client_frame("ping me"))
    assert {:text, "echo:ping me"} = read_frame(tunnel, leftover)
    Tunnel.close(tunnel)
  end

  test "an upgrade the upstream refuses comes back with its status", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)

    assert {:error, {:status, 404, _headers}} =
             HTTP.upgrade(tunnel, "/nowhere", [{"sec-websocket-key", "x"}])

    Tunnel.close(tunnel)
  end

  # ── the tunnel itself ──────────────────────────────────────────────────

  test "bytes flow both ways, large payloads are reframed, and a slow owner loses nothing", %{
    cfg: cfg
  } do
    payload = :crypto.strong_rand_bytes(2_000_000)
    test_pid = self()

    port =
      Fake.tcp_server(fn socket ->
        {:ok, received} = recv_exactly(socket, byte_size(payload), <<>>)
        send(test_pid, {:server_got, received})
        :ok = :gen_tcp.send(socket, payload)
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    :ok = Tunnel.send_data(tunnel, payload)
    assert_receive {:server_got, ^payload}, 5_000

    # Let the reply pile up before reading it: the tunnel pauses the socket
    # while the mailbox is deep and resumes as it drains.
    Process.sleep(200)
    assert collect(tunnel, byte_size(payload)) == payload
    assert_receive {:tunnel, ^tunnel, :closed}, 5_000
    assert {:error, :closed} = Tunnel.send_data(tunnel, "late")
  end

  test "close/1 from any process ends the tunnel and tells the owner once", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    ref = Process.monitor(tunnel)
    Task.async(fn -> Tunnel.close(tunnel) end) |> Task.await()
    assert_receive {:DOWN, ^ref, :process, ^tunnel, :normal}
    assert_receive {:tunnel, ^tunnel, :closed}
    refute_received {:tunnel, ^tunnel, :closed}
    assert :ok = Tunnel.close(tunnel)
  end

  test "a close from elsewhere ends a body stream in flight", %{cfg: cfg} do
    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nsome")
        Process.sleep(1_000)
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    assert {:ok, 200, _headers, body} = HTTP.request(tunnel, "GET", "/", [], nil)
    Task.start(fn -> Process.sleep(100) && Tunnel.close(tunnel) end)
    assert_raise Error, ~r/before the body ended/, fn -> Enum.to_list(body) end
  end

  test "an upgrade without a key gets one", %{cfg: cfg, app: app} do
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)
    assert {:ok, response_headers, ""} = HTTP.upgrade(tunnel, "/ws", [{"host", "preview.test"}])
    assert List.keymember?(response_headers, "sec-websocket-accept", 0)
    Tunnel.close(tunnel)
  end

  test "the tunnel stops when its owner does", %{cfg: cfg, app: app} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app, owner: owner)
    ref = Process.monitor(tunnel)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tunnel, :normal}
  end

  test "a port nothing listens on is refused before connecting", %{cfg: cfg} do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:error, %Error{status: 502, message: "Sprites closed the tunnel before connecting."}} =
             Tunnel.open(cfg, "sprite", port)
  end

  test "the wrong token is refused at the upgrade", %{app: app} do
    cfg = Fake.start_proxy(token: "another")

    assert {:error, %Error{status: 502, message: message}} = Tunnel.open(cfg, "sprite", app)
    assert message =~ "refused the tunnel (401)"
  end

  test "a Sprites that is not there at all is a 502", %{app: app} do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:error, %Error{status: 502, message: message}} =
             Tunnel.open(%{token: "t", base_url: "http://127.0.0.1:#{port}"}, "sprite", app)

    assert message =~ "Could not reach Sprites"
  end

  test "an acknowledgement that never comes is a timeout", %{app: app} do
    # A proxy that upgrades and then says nothing.
    port =
      Fake.tcp_server(fn socket ->
        head = Fake.read_request_head(socket)
        [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, head)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        Process.sleep(1_000)
      end)

    cfg = %{token: "t", base_url: "http://127.0.0.1:#{port}"}

    assert {:error, %Error{message: "Sprites tunnel acknowledgement timed out."}} =
             Tunnel.open(cfg, "sprite", app, timeout: 200)
  end

  test "without a token there is no tunnel", %{app: app} do
    assert {:error, :unconfigured} = Tunnel.open(nil, "sprite", app)
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp collect(tunnel, size, acc \\ <<>>)
  defp collect(_tunnel, size, acc) when byte_size(acc) >= size, do: acc

  defp collect(tunnel, size, acc) do
    receive do
      {:tunnel, ^tunnel, {:data, data}} -> collect(tunnel, size, acc <> data)
      {:tunnel, ^tunnel, other} -> flunk("tunnel ended early: #{inspect(other)}")
    after
      5_000 -> flunk("timed out with #{byte_size(acc)} of #{size} bytes")
    end
  end

  defp recv_exactly(_socket, size, acc) when byte_size(acc) >= size, do: {:ok, acc}

  defp recv_exactly(socket, size, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_exactly(socket, size, acc <> data)
      error -> error
    end
  end

  # A masked text frame, as a browser (or the gateway on its behalf) sends one.
  defp client_frame(text) when byte_size(text) < 126 do
    key = :crypto.strong_rand_bytes(4)
    <<1::1, 0::3, 1::4, 1::1, byte_size(text)::7, key::binary, mask(text, key)::binary>>
  end

  defp mask(data, key) do
    data
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(key, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # One unmasked server frame with a short payload, from the raw duplex.
  defp read_frame(tunnel, buffer) do
    case buffer do
      <<1::1, 0::3, 1::4, 0::1, len::7, payload::binary-size(len), _rest::binary>> ->
        {:text, payload}

      _partial ->
        receive do
          {:tunnel, ^tunnel, {:data, data}} -> read_frame(tunnel, buffer <> data)
        after
          5_000 -> flunk("no frame arrived")
        end
    end
  end
end
