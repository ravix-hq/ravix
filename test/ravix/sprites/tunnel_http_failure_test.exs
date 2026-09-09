defmodule Ravix.Sprites.TunnelHTTPFailureTest do
  use ExUnit.Case, async: true
  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Tunnel
  alias Ravix.Sprites.Tunnel.HTTP
  alias Ravix.SpritesFake, as: Fake

  setup do
    %{cfg: Fake.start_proxy()}
  end

  for {label, response} <- [
        {"non-HTTP response", "not http\r\n\r\n"},
        {"malformed header", "HTTP/1.1 200 OK\r\nno colon here\r\n\r\n"},
        {"connection closed before headers", ""}
      ] do
    @response response
    test "#{label} is a public 502", %{cfg: cfg} do
      tunnel = respond(cfg, @response)
      assert {:error, %Error{status: 502}} = HTTP.request(tunnel, "GET", "/", [], nil)
      Tunnel.close(tunnel)
    end
  end

  for {label, body} <- [
        {"non-hex chunk size", "xyz\r\n"},
        {"negative chunk size", "-1\r\n"},
        {"missing chunk terminator", "1\r\naXX"},
        {"oversized chunk header", String.duplicate("f", 140_000)}
      ] do
    @body body
    test "#{label} fails while streaming", %{cfg: cfg} do
      # Hold the body until the caller has parsed its headers.
      parent = self()

      port =
        Fake.tcp_server(fn socket ->
          Fake.read_request_head(socket)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
          send(parent, {:upstream, self()})

          receive do
            :body -> :gen_tcp.send(socket, @body)
          after
            2_000 -> flunk("body not requested")
          end
        end)

      {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
      assert {:ok, 200, _, stream} = HTTP.request(tunnel, "GET", "/", [], nil)
      assert_receive {:upstream, upstream}
      send(upstream, :body)
      assert_raise Error, ~r/malformed chunked/, fn -> Enum.to_list(stream) end
      Tunnel.close(tunnel)
    end
  end

  test "stalled body becomes a 504 and the tunnel remains closable", %{cfg: cfg} do
    parent = self()

    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n")
        send(parent, {:upstream, self()})

        receive do
          :finish -> :ok
        after
          2_000 -> :ok
        end
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    assert {:ok, 200, _, stream} = HTTP.request(tunnel, "GET", "/", [], nil, body_timeout: 20)
    assert_receive {:upstream, upstream}
    error = assert_raise Error, fn -> Enum.to_list(stream) end
    assert error.status == 504
    Tunnel.close(tunnel)
    send(upstream, :finish)
  end

  test "chunk extensions and trailers do not enter the response body", %{cfg: cfg} do
    tunnel =
      respond(
        cfg,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;key=value\r\nabc\r\n0\r\nX-Trailer: yes\r\n\r\n"
      )

    assert {:ok, 200, _, stream} =
             HTTP.request(tunnel, "GET", "/", [], nil, headers_timeout: :infinity)

    assert Enum.join(stream) == "abc"
    Tunnel.close(tunnel)
  end

  test "a zero content-length completes without waiting for the server to close", %{cfg: cfg} do
    tunnel = respond(cfg, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    assert {:ok, 200, _, stream} = HTTP.request(tunnel, "GET", "/", [], nil)
    assert Enum.to_list(stream) == []
    Tunnel.close(tunnel)
  end

  test "a stream with known length is sent without chunk framing", %{cfg: cfg} do
    app = Fake.start_app()
    {:ok, tunnel} = Tunnel.open(cfg, "sprite", app)

    assert {:ok, 200, _, stream} =
             HTTP.request(
               tunnel,
               "POST",
               "/echo",
               [{"content-length", "6"}],
               Stream.map(["abc", "def"], & &1)
             )

    assert Enum.join(stream) == "abcdef"
    Tunnel.close(tunnel)
  end

  defp respond(cfg, response) do
    port =
      Fake.tcp_server(fn socket ->
        Fake.read_request_head(socket)
        :gen_tcp.send(socket, response)
      end)

    {:ok, tunnel} = Tunnel.open(cfg, "sprite", port)
    tunnel
  end
end
