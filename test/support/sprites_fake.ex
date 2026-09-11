defmodule Ravix.SpritesFake do
  @moduledoc """
  Sprites, stood in for twice: the HTTP API by `Req.Test`, and the `/proxy`
  tunnel by a real WebSocket server that connects to a real local port,
  which is what `mock/previews.ts` does for the Bun stack.

  ## The API

  `Ravix.Sprites` merges `Application.get_env(:ravix, :req_options)` into
  every request, and `config/test.exs` points that at the `Req.Test` stub
  every Req client in the suite shares (`Ravix.ReqFake`; stubs are per
  process, so async tests never see each other's Sprites). `install/1`
  stubs it for the calling test and hands each request to the test's
  handler as `(conn, call)`, where `call` already has the argv of an exec,
  the decoded JSON body of a service operation and the bearer token. Every
  call is also sent to the test process as `{Ravix.SpritesFake, call}` so a
  test can read them back in order with `calls/0`.

  ## The tunnel

  `start_proxy/1` starts the fake Sprites on a loopback port: it checks the
  bearer token, upgrades `/v1/sprites/:name/proxy`, expects the
  `{"host","port"}` text frame, connects to that port on 127.0.0.1, answers
  `{"status":"connected"}` and relays binary frames to TCP bytes and back.
  Anything else, including a port nothing listens on, closes the socket, as
  the mock does. `start_app/0` starts the thing inside the sprite: a small
  Plug app with chunked, fixed-length and echo routes and a WebSocket echo,
  and `tcp_server/1` is a raw socket for what Bandit will not send.
  """

  import Plug.Conn

  @stub Ravix.ReqFake
  @token "sprites_mock"

  @type call :: %{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          argv: [String.t()],
          body: term(),
          authorization: String.t() | nil
        }

  # ── the HTTP API ─────────────────────────────────────────────────────

  @doc "A config pointed at the fake API."
  @spec config() :: Ravix.Sprites.config()
  def config,
    do: %Ravix.Config.Sprites{token: "provider-token", base_url: "http://sprites.test"}

  @doc "Route this test's Sprites API requests to `handler`, which answers with the conn."
  @spec install((Plug.Conn.t(), call() -> Plug.Conn.t())) :: :ok
  def install(handler) when is_function(handler, 2) do
    owner = self()

    Req.Test.stub(@stub, fn conn ->
      {conn, body} = read(conn)

      call = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        argv: argv(conn.query_string),
        body: body,
        authorization: conn |> get_req_header("authorization") |> List.first()
      }

      send(owner, {__MODULE__, call})
      handler.(conn, call)
    end)
  end

  @doc "Every call this test's Sprites has seen, oldest first (drains the mailbox)."
  @spec calls() :: [call()]
  def calls, do: drain([])

  defp drain(acc) do
    receive do
      {__MODULE__, call} -> drain([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "An exec response: stdout and stderr frames and the exit frame, as Sprites sends them."
  @spec exec_response(Plug.Conn.t(), String.t(), String.t(), non_neg_integer()) :: Plug.Conn.t()
  def exec_response(conn, stdout, stderr \\ "", code \\ 0) do
    body =
      IO.iodata_to_binary([
        if(stdout == "", do: [], else: frame(1, stdout)),
        if(stderr == "", do: [], else: frame(2, stderr)),
        <<3, code>>
      ])

    send_resp(conn, 200, body)
  end

  @doc "One output frame: the id byte and the payload."
  @spec frame(1 | 2, binary()) :: binary()
  def frame(id, payload), do: <<id>> <> payload

  defp read(conn) do
    {:ok, raw, conn} = read_body(conn)

    body =
      case Jason.decode(raw) do
        {:ok, json} -> json
        _ -> if(raw == "", do: nil, else: raw)
      end

    {conn, body}
  end

  defp argv(query) do
    for {"cmd", value} <- URI.query_decoder(query), do: value
  end

  # ── the tunnel ───────────────────────────────────────────────────────

  @doc "The token the fake proxy accepts."
  @spec token() :: String.t()
  def token, do: @token

  @doc "Start the fake Sprites proxy on a loopback port and return a config pointed at it."
  @spec start_proxy(keyword()) :: Ravix.Sprites.config()
  def start_proxy(opts \\ []) do
    port = start_bandit({__MODULE__.Proxy, token: Keyword.get(opts, :token, @token)})
    %Ravix.Config.Sprites{token: @token, base_url: "http://127.0.0.1:#{port}"}
  end

  @doc "Start the app inside the sprite on a loopback port and return that port."
  @spec start_app() :: :inet.port_number()
  def start_app, do: start_bandit({__MODULE__.App, []})

  defp start_bandit({plug, plug_opts}) do
    id = {plug, System.unique_integer([:positive])}

    spec =
      Supervisor.child_spec(
        {Bandit, plug: {plug, plug_opts}, port: 0, ip: :loopback, startup_log: false},
        id: id
      )

    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  A raw TCP server on a loopback port for one connection. `handler` gets the
  accepted socket (binary, passive) and the port is returned.
  """
  @spec tcp_server((:gen_tcp.socket() -> any())) :: :inet.port_number()
  def tcp_server(handler) when is_function(handler, 1) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      handler.(socket)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end

  @doc "Read from a raw socket until the request head ends, returning everything read."
  @spec read_request_head(:gen_tcp.socket(), binary()) :: binary()
  def read_request_head(socket, acc \\ <<>>) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      read_request_head(socket, acc <> data)
    end
  end

  defmodule Proxy do
    @moduledoc "The fake `/v1/sprites/:name/proxy`: bearer token, then a WebSocket to `ProxySocket`."
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      expected = "Bearer " <> Keyword.fetch!(opts, :token)

      case {get_req_header(conn, "authorization"), conn.path_info} do
        {[^expected], ["v1", "sprites", _sprite, "proxy"]} ->
          WebSockAdapter.upgrade(conn, Ravix.SpritesFake.ProxySocket, %{}, timeout: 60_000)

        {[^expected], _path} ->
          send_resp(conn, 404, "missing")

        _other ->
          send_resp(conn, 401, "unauthorized")
      end
    end
  end

  defmodule ProxySocket do
    @moduledoc "The relay: one JSON text frame in, `connected` out, then bytes both ways."
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, Map.put(state, :tcp, nil)}

    @impl true
    def handle_in({text, [opcode: :text]}, %{tcp: nil} = state) do
      with {:ok, %{"host" => "127.0.0.1", "port" => port}} when is_integer(port) <-
             Jason.decode(text),
           {:ok, tcp} <-
             :gen_tcp.connect(
               {127, 0, 0, 1},
               port,
               [:binary, active: :once, nodelay: true],
               1_000
             ) do
        {:push, {:text, ~s({"status":"connected"})}, %{state | tcp: tcp}}
      else
        _refused -> {:stop, :normal, state}
      end
    end

    def handle_in({data, [opcode: :binary]}, %{tcp: tcp} = state) when tcp != nil do
      case :gen_tcp.send(tcp, data) do
        :ok -> {:ok, state}
        {:error, _reason} -> {:stop, :normal, state}
      end
    end

    def handle_in(_other, state), do: {:stop, :normal, state}

    @impl true
    def handle_info({:tcp, tcp, data}, %{tcp: tcp} = state) do
      :ok = :inet.setopts(tcp, active: :once)
      {:push, {:binary, data}, state}
    end

    def handle_info({:tcp_closed, tcp}, %{tcp: tcp} = state), do: {:stop, :normal, state}
    def handle_info({:tcp_error, tcp, _reason}, %{tcp: tcp} = state), do: {:stop, :normal, state}
    def handle_info(_other, state), do: {:ok, state}

    @impl true
    def terminate(_reason, %{tcp: tcp}) do
      if tcp, do: :gen_tcp.close(tcp)
      :ok
    end
  end

  defmodule App do
    @moduledoc "What runs inside the sprite: enough HTTP to exercise the client."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/stream" do
      conn = send_chunked(conn, 200)

      Enum.reduce(1..5, conn, fn i, conn ->
        {:ok, conn} = chunk(conn, "chunk #{i}\n")
        if i == 1, do: Process.sleep(150)
        conn
      end)
    end

    match "/fixed", via: [:get, :head] do
      send_resp(conn, 200, "hello, fixed")
    end

    get "/nobody" do
      send_resp(conn, 204, "")
    end

    get "/headers" do
      headers = conn.req_headers |> Enum.sort() |> Map.new()
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(headers))
    end

    post "/echo" do
      {:ok, body, conn} = read_all(conn, [])
      send_resp(conn, 200, body)
    end

    get "/ws" do
      WebSockAdapter.upgrade(conn, Ravix.SpritesFake.EchoSocket, [], timeout: 60_000)
    end

    match _ do
      send_resp(conn, 404, "no such route")
    end

    defp read_all(conn, acc) do
      case read_body(conn, length: 1_000_000) do
        {:ok, body, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([body | acc])), conn}
        {:more, body, conn} -> read_all(conn, [body | acc])
      end
    end
  end

  defmodule EchoSocket do
    @moduledoc "A WebSocket that answers every message with `echo:` and the message."
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({data, [opcode: opcode]}, state), do: {:push, {opcode, "echo:" <> data}, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
