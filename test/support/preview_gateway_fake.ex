defmodule Ravix.PreviewGatewayFake do
  @moduledoc """
  Everything around the preview gateway, stood in for tests.

  The TypeScript test stood up an `upstream` (the app in the sprite), a
  `provider` (the Sprites `/proxy` WebSocket) and a real database. Here:

    * `Store` is the database: rows, grants, sessions, tracks, membership.
    * `Backend` implements `RavixWeb.PreviewGateway.Backend` over it.
    * `Tunnel` (and `Tunnel.HTTP`) speak the `Ravix.Sprites.Tunnel` contract
      but dial the upstream directly over TCP, counting opens per sprite so
      a test can assert that nothing was tunneled before authorization.
    * `Upstream` is the app: the routes from both TypeScript tests, plus a
      WebSocket echo that negotiates `vite-hmr`.
    * `Front` is the endpoint in miniature: the gateway plug, then "app".
    * `Client` makes raw HTTP and WebSocket requests with Mint, naming the
      preview host itself the way a browser would.

  One front and one store serve a whole test module; every fixture gets its
  own hostnames, sprite, users and upstream, so tests run concurrently.
  """

  alias Ravix.Crypto
  alias Ravix.PreviewGatewayFake.Store

  @doc "Start the store and the front once per module; returns the front's port."
  @spec start_front!() :: pos_integer()
  def start_front! do
    ExUnit.Callbacks.start_supervised!(__MODULE__.Store)

    front =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Bandit, plug: __MODULE__.Front, port: 0, ip: {127, 0, 0, 1}},
          id: :preview_gateway_front
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(front)
    __MODULE__.Store.set_port(port)
    Application.put_env(:ravix, :preview_backend, __MODULE__.Backend)
    Application.put_env(:ravix, :tunnel_module, __MODULE__.Tunnel)
    port
  end

  @doc """
  The TypeScript fixture: an owner and a guest, a project with two tracks,
  the guest a member of the first, a Ravix session for the guest and a
  preview session grant on it, a ready preview row pointing at a fresh
  upstream. Returns what tests name.
  """
  @spec fixture(pos_integer()) :: map()
  def fixture(port) do
    s = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) |> String.downcase()

    upstream =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {__MODULE__.Upstream, self()}, port: 0, ip: {127, 0, 0, 1}},
          id: {:preview_gateway_upstream, s}
        )
      )

    {:ok, {_, app_port}} = ThousandIsland.listener_info(upstream)

    owner = %{id: "ana-#{s}"}
    guest = %{id: "bo-#{s}"}
    project = "p-#{s}"
    t1 = "t1-#{s}"
    t2 = "t2-#{s}"
    Store.put_project(project, owner.id)
    Store.put_track(%{id: t1, project_id: project, closed_at: nil})
    Store.put_track(%{id: t2, project_id: project, closed_at: nil})
    Store.add_member(t1, guest.id)
    app_session = "app-session-#{s}"
    Store.put_session(Crypto.sha256(app_session), guest)

    Store.put_grant(%{
      hash: Crypto.sha256("preview-session-#{s}"),
      track_id: t1,
      session_hash: Crypto.sha256(app_session),
      expires: now() + 60_000,
      kind: :session
    })

    row = %{
      track_id: t1,
      hostname: "t-#{s}",
      sprite: "sprite-#{s}",
      port: app_port,
      desired: :running,
      state: :ready,
      generation: 0,
      cleanup: false
    }

    Store.put_row(row)

    other = %{
      track_id: t2,
      hostname: "t-#{s}-2",
      sprite: nil,
      port: nil,
      desired: :stopped,
      state: :stopped,
      generation: 0,
      cleanup: false
    }

    Store.put_row(other)
    host = "#{row.hostname}.preview.localhost:#{port}"

    %{
      port: port,
      app_port: app_port,
      row: row,
      other: other,
      owner: owner,
      guest: guest,
      project: project,
      t1: t1,
      t2: t2,
      app_session: app_session,
      host: host,
      origin: "http://#{host}",
      other_host: "#{other.hostname}.preview.localhost:#{port}",
      cookie:
        "ravix_preview_local=preview-session-#{s}; " <>
          "#{RavixWeb.Endpoint.session_cookie_name()}=NEVER; app=okay",
      tunnels: fn -> Store.tunnels(row.sprite) end
    }
  end

  @doc "Milliseconds since the epoch, as grants are stamped."
  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)

  # ── the database ─────────────────────────────────────────────────────

  defmodule Store do
    @moduledoc false
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            port: nil,
            rows: %{},
            grants: %{},
            sessions: %{},
            tracks: %{},
            projects: %{},
            members: MapSet.new(),
            tunnels: %{},
            calls: []
          }
        end,
        name: __MODULE__
      )
    end

    def set_port(port), do: Agent.update(__MODULE__, &%{&1 | port: port})
    def port, do: Agent.get(__MODULE__, & &1.port)

    def put_row(row), do: Agent.update(__MODULE__, &put_in(&1, [:rows, row.track_id], row))
    def row(track_id), do: Agent.get(__MODULE__, &Map.get(&1.rows, track_id))

    def update_row(track_id, fun),
      do: Agent.update(__MODULE__, &update_in(&1, [:rows, track_id], fun))

    def row_by_host(hostname),
      do:
        Agent.get(
          __MODULE__,
          &Enum.find_value(&1.rows, fn {_, r} -> r.hostname == hostname && r end)
        )

    def put_grant(grant),
      do:
        Agent.update(
          __MODULE__,
          &put_in(&1, [:grants, {grant.hash, grant.track_id, grant.kind}], grant)
        )

    def get_grant(hash, track_id, kind, consume?) do
      now = Ravix.PreviewGatewayFake.now()

      Agent.get_and_update(__MODULE__, fn state ->
        key = {hash, track_id, kind}

        case Map.get(state.grants, key) do
          %{expires: expires} = grant when expires > now ->
            {grant, if(consume?, do: update_in(state.grants, &Map.delete(&1, key)), else: state)}

          _ ->
            {nil, state}
        end
      end)
    end

    def put_session(hash, user),
      do: Agent.update(__MODULE__, &put_in(&1, [:sessions, hash], user))

    def end_session(hash),
      do: Agent.update(__MODULE__, &update_in(&1.sessions, fn s -> Map.delete(s, hash) end))

    def session_user(hash), do: Agent.get(__MODULE__, &Map.get(&1.sessions, hash))

    def put_track(track), do: Agent.update(__MODULE__, &put_in(&1, [:tracks, track.id], track))
    def track(id), do: Agent.get(__MODULE__, &Map.get(&1.tracks, id))
    def update_track(id, fun), do: Agent.update(__MODULE__, &update_in(&1, [:tracks, id], fun))

    def put_project(id, owner_id),
      do:
        Agent.update(
          __MODULE__,
          &put_in(&1, [:projects, id], %{id: id, owner_id: owner_id, archived_at: nil})
        )

    def project(id), do: Agent.get(__MODULE__, &Map.get(&1.projects, id))

    def add_member(track_id, user_id),
      do: Agent.update(__MODULE__, &%{&1 | members: MapSet.put(&1.members, {track_id, user_id})})

    def member?(track_id, user_id),
      do: Agent.get(__MODULE__, &MapSet.member?(&1.members, {track_id, user_id}))

    # As `db.removeMember`: membership goes, and so do that person's preview grants on the track.
    def remove_member(track_id, user_id) do
      Agent.update(__MODULE__, fn state ->
        hashes = for {hash, %{id: ^user_id}} <- state.sessions, do: hash

        grants =
          state.grants
          |> Enum.reject(fn {_, g} -> g.track_id == track_id and g.session_hash in hashes end)
          |> Map.new()

        %{state | members: MapSet.delete(state.members, {track_id, user_id}), grants: grants}
      end)
    end

    def tunnel_opened(sprite),
      do: Agent.update(__MODULE__, &update_in(&1, [:tunnels, sprite], fn n -> (n || 0) + 1 end))

    def tunnels(sprite), do: Agent.get(__MODULE__, &Map.get(&1.tunnels, sprite, 0))

    def record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})

    def calls(track_id),
      do: Agent.get(__MODULE__, &for({name, ^track_id} <- Enum.reverse(&1.calls), do: name))
  end

  # ── the backend ──────────────────────────────────────────────────────

  defmodule Backend do
    @moduledoc false
    @behaviour RavixWeb.PreviewGateway.Backend

    alias Ravix.PreviewGatewayFake.Store

    @impl true
    def resolve_host(name) do
      case Store.row_by_host(name) do
        nil -> :error
        row -> {:ok, row}
      end
    end

    @impl true
    def assert_open(track_id) do
      track = Store.track(track_id)
      project = track && Store.project(track.project_id)
      row = Store.row(track_id)

      if track && is_nil(track.closed_at) && project && is_nil(project.archived_at) &&
           !(row && row.cleanup),
         do: :ok,
         else: {:error, :closed_track}
    end

    @impl true
    def preview(track_id), do: Store.row(track_id)

    @impl true
    def get_grant(hash, track_id, kind, consume?),
      do: Store.get_grant(hash, track_id, kind, consume?)

    @impl true
    def session_user(hash), do: Store.session_user(hash)

    @impl true
    def track_access(user, track_id) do
      track = Store.track(track_id)
      project = track && Store.project(track.project_id)

      cond do
        is_nil(project) or project.archived_at -> {:error, :not_found}
        project.owner_id == user.id -> {:ok, track}
        track.closed_at -> {:error, :not_found}
        Store.member?(track_id, user.id) -> {:ok, track}
        true -> {:error, :not_found}
      end
    end

    @impl true
    def allowed?(row, grant) do
      with %{} <- Store.get_grant(grant.hash, row.track_id, grant.kind, false),
           %{} = user <- Store.session_user(grant.session_hash),
           {:ok, %{closed_at: nil}} <- track_access(user, row.track_id) do
        current = Store.row(row.track_id)
        !(current && current.cleanup)
      else
        _ -> false
      end
    end

    @impl true
    def track(track_id), do: Store.track(track_id)

    @impl true
    def grant_session(grant) do
      Store.put_grant(grant)
      :ok
    end

    @impl true
    def info(track_id) do
      row = Store.row(track_id)
      %{state: row.state, error: nil, logs: "", url: nil}
    end

    @impl true
    def touch(track_id) do
      Store.record({:touch, track_id})
      :ok
    end

    @impl true
    def start_service(track_id) do
      Store.record({:start_service, track_id})
      :ok
    end

    @impl true
    def destination(track_id) do
      Store.record({:destination, track_id})
      {:ok, Store.row(track_id)}
    end

    @impl true
    def public_url, do: "http://localhost:5183"

    @impl true
    def previews_config,
      do: %{domain: "preview.localhost", protocol: :http, public_port: ":#{Store.port()}"}

    @impl true
    def sprites_config, do: %{token: "secret-provider-token", base_url: "http://127.0.0.1:1"}
  end

  # ── the tunnel ───────────────────────────────────────────────────────

  defmodule ErrorTunnelClosed do
    @moduledoc false
    defexception message: "the tunnel closed"
  end

  defmodule Tunnel do
    @moduledoc false
    # The Sprites tunnel contract over a plain TCP connection to the upstream.
    # A process owns the socket; during an HTTP exchange the caller holds the
    # Mint connection and reads passively, afterwards (for a WebSocket) the
    # process turns the socket active and forwards bytes to its owner.
    use GenServer

    alias Ravix.PreviewGatewayFake.Store

    @token "secret-provider-token"

    def open(config, sprite, port, _opts) do
      Store.tunnel_opened(sprite)

      if config.token == @token,
        do: GenServer.start(__MODULE__, {self(), port}),
        else: {:error, :unauthorized}
    end

    def send_data(pid, data) do
      GenServer.call(pid, {:send, data})
    catch
      :exit, _ -> {:error, :closed}
    end

    def close(pid) do
      GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end

    def take(pid), do: GenServer.call(pid, :take)
    def raw(pid, conn, ref), do: GenServer.call(pid, {:raw, conn, ref})

    @impl true
    def init({owner, port}) do
      case Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1]) do
        {:ok, conn} ->
          Process.monitor(owner)

          {:ok,
           %{
             owner: owner,
             conn: conn,
             socket: Mint.HTTP.get_socket(conn),
             ref: nil,
             mode: :http,
             notified: false
           }}

        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl true
    def handle_call(:take, _from, %{mode: :http, conn: conn} = state) when not is_nil(conn),
      do: {:reply, {:ok, conn}, %{state | conn: nil}}

    def handle_call(:take, _from, state), do: {:reply, {:error, :taken}, state}

    def handle_call({:raw, conn, ref}, _from, state) do
      :ok = :inet.setopts(state.socket, active: :once)
      {:reply, :ok, %{state | conn: conn, ref: ref, mode: :raw}}
    end

    def handle_call({:send, data}, _from, %{mode: :raw} = state) do
      case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
        {:ok, conn} -> {:reply, :ok, %{state | conn: conn}}
        {:error, conn, reason} -> {:reply, {:error, reason}, %{state | conn: conn}}
      end
    end

    def handle_call({:send, _}, _from, state), do: {:reply, {:error, :not_raw}, state}

    @impl true
    def handle_info({:tcp, socket, _} = message, %{socket: socket, mode: :raw} = state) do
      case Mint.WebSocket.stream(state.conn, message) do
        {:ok, conn, responses} ->
          for {:data, _, data} <- responses,
              do: send(state.owner, {:tunnel, self(), {:data, data}})

          {:noreply, %{state | conn: conn}}

        {:error, conn, reason, _} ->
          send(state.owner, {:tunnel, self(), {:error, reason}})
          {:stop, :normal, %{state | conn: conn, notified: true}}
      end
    end

    def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
      send(state.owner, {:tunnel, self(), :closed})
      {:stop, :normal, %{state | notified: true}}
    end

    def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
      send(state.owner, {:tunnel, self(), {:error, reason}})
      {:stop, :normal, %{state | notified: true}}
    end

    def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state),
      do: {:stop, :normal, state}

    def handle_info(_, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      :gen_tcp.close(state.socket)
      unless state.notified, do: send(state.owner, {:tunnel, self(), :closed})
      :ok
    end
  end

  defmodule Tunnel.HTTP do
    @moduledoc false
    alias Ravix.PreviewGatewayFake.{ErrorTunnelClosed, Tunnel}

    @timeout 30_000

    def request(pid, method, path, headers, body, _opts \\ []) do
      with {:ok, conn} <- Tunnel.take(pid),
           {:ok, conn, ref} <- start(conn, method, path, headers, body),
           {:ok, conn} <- send_body(conn, ref, body),
           {:ok, conn, status, response_headers, early} <- head(conn, ref, nil, nil, []) do
        {:ok, status, response_headers, body_stream(conn, ref, early)}
      else
        {:error, reason} -> {:error, reason}
        {:error, _conn, reason} -> {:error, reason}
        {:error, _conn, reason, _responses} -> {:error, reason}
      end
    end

    def upgrade(pid, path, headers) do
      with {:ok, conn} <- Tunnel.take(pid),
           {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
           {:ok, conn, 101, response_headers, early} <- head(conn, ref, nil, nil, []),
           {:ok, conn, _websocket} <-
             Mint.WebSocket.new(conn, ref, 101, response_headers, mode: :active) do
        :ok = Tunnel.raw(pid, conn, ref)
        {:ok, response_headers, for({:data, _, data} <- early, into: <<>>, do: data)}
      else
        {:ok, _conn, status, headers, _early} -> {:error, {:status, status, headers}}
        {:error, reason} -> {:error, reason}
        {:error, _conn, reason} -> {:error, reason}
        {:error, _conn, reason, _responses} -> {:error, reason}
      end
    end

    defp start(conn, method, path, headers, body) when is_nil(body) or is_binary(body),
      do: Mint.HTTP.request(conn, method, path, headers, body)

    defp start(conn, method, path, headers, _stream),
      do: Mint.HTTP.request(conn, method, path, headers, :stream)

    defp send_body(conn, _ref, body) when is_nil(body) or is_binary(body), do: {:ok, conn}

    defp send_body(conn, ref, stream) do
      result =
        Enum.reduce_while(stream, {:ok, conn}, fn chunk, {:ok, conn} ->
          case Mint.HTTP.stream_request_body(conn, ref, chunk) do
            {:ok, conn} -> {:cont, {:ok, conn}}
            error -> {:halt, error}
          end
        end)

      with {:ok, conn} <- result, do: Mint.HTTP.stream_request_body(conn, ref, :eof)
    end

    # Read until the response headers are in; keep any body that came with them.
    defp head(conn, _ref, status, headers, early) when status != nil and headers != nil,
      do: {:ok, conn, status, headers, Enum.reverse(early)}

    defp head(conn, ref, status, headers, early) do
      case Mint.HTTP.recv(conn, 0, @timeout) do
        {:ok, conn, responses} ->
          {status, headers, early} =
            Enum.reduce(responses, {status, headers, early}, &sort_response(&1, &2, ref))

          head(conn, ref, status, headers, early)

        error ->
          error
      end
    end

    defp sort_response({:status, ref, status}, {_, headers, early}, ref),
      do: {status, headers, early}

    defp sort_response({:headers, ref, headers}, {status, _, early}, ref),
      do: {status, headers, early}

    defp sort_response(other, {status, headers, early}, _ref),
      do: {status, headers, [other | early]}

    defp body_stream(conn, ref, early) do
      Stream.resource(
        fn -> {conn, early} end,
        fn
          {conn, [{:data, ^ref, data} | rest]} ->
            {[data], {conn, rest}}

          {conn, [{:done, ^ref} | _]} ->
            {:halt, {conn, []}}

          {_conn, [{:error, ^ref, _} | _]} ->
            raise ErrorTunnelClosed

          {conn, [_ | rest]} ->
            {[], {conn, rest}}

          {conn, []} ->
            case Mint.HTTP.recv(conn, 0, @timeout) do
              {:ok, conn, responses} ->
                {[], {conn, responses}}

              {:error, _conn, _reason, responses} ->
                {[], {conn, responses ++ [{:error, ref, :closed}]}}
            end
        end,
        fn _ -> :ok end
      )
    end
  end

  # ── the app in the sprite ────────────────────────────────────────────

  defmodule Upstream do
    @moduledoc false
    # Every route from the two TypeScript fixtures. The test process is told
    # what headers each request arrived with.
    import Plug.Conn

    @html "<!DOCTYPE html><html><head><title>App</title></head><body>track app</body></html>"

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      send(
        test_pid,
        {:upstream, conn.method, conn.request_path, conn.query_string, conn.req_headers}
      )

      if websocket?(conn), do: socket(conn), else: route(conn, conn.request_path)
    end

    defp websocket?(conn),
      do: conn |> get_req_header("upgrade") |> List.first("") |> String.downcase() == "websocket"

    defp socket(conn) do
      if conn.request_path == "/refuse" do
        send_resp(conn, 403, "no sockets here")
      else
        offered =
          conn
          |> get_req_header("sec-websocket-protocol")
          |> Enum.flat_map(&String.split(&1, ","))

        protocol = if "vite-hmr" in Enum.map(offered, &String.trim/1), do: "vite-hmr"

        conn =
          if protocol, do: put_resp_header(conn, "sec-websocket-protocol", protocol), else: conn

        host = conn |> get_req_header("host") |> List.first("")

        WebSockAdapter.upgrade(
          conn,
          Ravix.PreviewGatewayFake.Echo,
          %{path: conn.request_path, host: host},
          compress: false
        )
      end
    end

    defp route(conn, "/stream") do
      conn = conn |> put_resp_header("content-type", "text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, "first\n")
      later(conn, 400)
    end

    defp route(conn, "/flood") do
      conn =
        conn |> put_resp_header("content-type", "application/octet-stream") |> send_chunked(200)

      block = :binary.copy("x", 65_536)

      Enum.reduce_while(1..128, conn, fn _, conn ->
        case chunk(conn, block) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end

    defp route(conn, "/upload") do
      conn =
        conn |> put_resp_header("content-type", "application/octet-stream") |> send_chunked(200)

      echo(conn)
    end

    defp route(conn, "/redirect") do
      conn
      |> put_resp_header("location", "/__ravix/start")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(302, "")
    end

    defp route(conn, "/redirect-local") do
      conn
      |> put_resp_header("location", "http://localhost:3000/next?x=1#frag")
      |> send_resp(302, "")
    end

    defp route(conn, "/cookies") do
      conn
      |> prepend_resp_headers([
        {"set-cookie", "a=1; Path=/"},
        {"set-cookie", "b=2; Path=/; HttpOnly"}
      ])
      |> send_resp(204, "")
    end

    defp route(conn, "/gzip") do
      conn
      |> put_resp_header("content-type", "text/plain")
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip("inflated"))
    end

    defp route(conn, "/gzip-html") do
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip(@html))
    end

    defp route(conn, "/hello") do
      host = conn |> get_req_header("host") |> List.first("")

      conn
      |> put_resp_header("content-type", "text/plain")
      |> put_resp_header("x-echo-host", host)
      |> send_resp(200, "hello #{host}")
    end

    defp route(conn, "/headless") do
      conn
      |> put_resp_header("content-type", "text/html")
      |> send_resp(200, "<p>no head here</p>")
    end

    defp route(conn, "/hop") do
      conn
      |> put_resp_header("content-type", "text/plain")
      |> put_resp_header("x-drop-me", "1")
      |> put_resp_header("connection", "close, x-drop-me")
      |> put_resp_header("clear-site-data", "\"*\"")
      |> put_resp_header("alt-svc", "h3=\":443\"")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", "\"abc\"")
      |> send_resp(200, "hop")
    end

    defp route(conn, _) do
      conn
      |> put_resp_header("content-type", "text/html")
      |> prepend_resp_headers([
        {"set-cookie", "app=1; Domain=preview.localhost; Path=/"},
        {"set-cookie", "__Host-ravix_preview=evil; Path=/; Secure"}
      ])
      |> send_resp(200, @html)
    end

    defp later(conn, 0), do: conn

    defp later(conn, n) do
      Process.sleep(25)

      case chunk(conn, "later\n") do
        {:ok, conn} -> later(conn, n - 1)
        {:error, _} -> conn
      end
    end

    defp echo(conn) do
      case read_body(conn, length: 65_536, read_length: 65_536) do
        {:ok, data, conn} -> conn |> emit(data) |> elem(1)
        {:more, data, conn} -> conn |> emit(data) |> elem(1) |> echo()
      end
    end

    defp emit(conn, ""), do: {:ok, conn}
    defp emit(conn, data), do: chunk(conn, data)
  end

  defmodule Echo do
    @moduledoc false
    # `/hmr` echoes frames as they are; `/chat` greets and marks its echoes.
    @behaviour WebSock

    @impl true
    def init(%{path: "/chat"} = state), do: {:push, {:text, "welcome #{state.host}"}, state}
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({data, opcode: :text}, %{path: "/chat"} = state),
      do: {:push, {:text, "echo #{data}"}, state}

    def handle_in({data, opcode: :binary}, %{path: "/chat"} = state),
      do: {:push, {:binary, <<0xFF, data::binary>>}, state}

    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}

    @impl true
    def handle_info(_, state), do: {:ok, state}
  end

  # ── the endpoint in miniature ────────────────────────────────────────

  defmodule Front do
    @moduledoc false
    use Plug.Builder

    plug RavixWeb.PreviewGateway
    plug :app

    def app(conn, _opts), do: send_resp(conn, 200, "app")
  end

  # ── the browser ──────────────────────────────────────────────────────

  defmodule Client do
    @moduledoc false
    # Mint against loopback, naming the preview host itself.

    @timeout 10_000

    @doc "A whole response: `%{status, headers, body}`."
    def request(port, method, path, headers, body \\ nil) do
      {:ok, conn} =
        Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])

      {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, body)
      result = collect(conn, ref, %{status: nil, headers: [], body: []})
      Mint.HTTP.close(conn)
      result
    end

    defp collect(conn, ref, acc) do
      case Mint.HTTP.recv(conn, 0, @timeout) do
        {:ok, conn, responses} ->
          case fold(responses, ref, acc) do
            {:done, acc} -> finish(acc)
            {:more, acc} -> collect(conn, ref, acc)
          end

        {:error, _conn, reason, responses} ->
          {_, acc} = fold(responses, ref, acc)
          Map.put(finish(acc), :error, reason)
      end
    end

    defp fold([], _ref, acc), do: {:more, acc}

    defp fold([{:status, ref, status} | rest], ref, acc),
      do: fold(rest, ref, %{acc | status: status})

    defp fold([{:headers, ref, headers} | rest], ref, acc),
      do: fold(rest, ref, %{acc | headers: acc.headers ++ headers})

    defp fold([{:data, ref, data} | rest], ref, acc),
      do: fold(rest, ref, %{acc | body: [acc.body, data]})

    defp fold([{:done, ref} | _], ref, acc), do: {:done, acc}
    defp fold([_ | rest], ref, acc), do: fold(rest, ref, acc)

    defp finish(acc), do: %{acc | body: IO.iodata_to_binary(acc.body)}

    @doc "Start a request and return once status and headers are in; body chunks come from `next/1`."
    def stream(port, method, path, headers) do
      {:ok, conn} =
        Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])

      {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, nil)
      await_head(%{conn: conn, ref: ref, status: nil, headers: nil, queue: []})
    end

    defp await_head(%{status: status, headers: headers} = client)
         when status != nil and headers != nil,
         do: client

    defp await_head(client) do
      {:ok, conn, responses} = Mint.HTTP.recv(client.conn, 0, @timeout)

      client =
        Enum.reduce(responses, %{client | conn: conn}, fn
          {:status, _, s}, c -> %{c | status: s}
          {:headers, _, h}, c -> %{c | headers: h}
          other, c -> %{c | queue: c.queue ++ [other]}
        end)

      await_head(client)
    end

    @doc "`{:data, binary, client}`, `{:done, client}` or `{:error, reason, client}`."
    def next(%{queue: [{:data, _, data} | rest]} = client),
      do: {:data, data, %{client | queue: rest}}

    def next(%{queue: [{:done, _} | _]} = client), do: {:done, client}
    def next(%{queue: [{:error, _, reason} | _]} = client), do: {:error, reason, client}
    def next(%{queue: [_ | rest]} = client), do: next(%{client | queue: rest})

    def next(%{queue: []} = client) do
      case Mint.HTTP.recv(client.conn, 0, @timeout) do
        {:ok, conn, responses} ->
          next(%{client | conn: conn, queue: responses})

        {:error, conn, reason, responses} ->
          next(%{client | conn: conn, queue: responses ++ [{:error, client.ref, reason}]})
      end
    end

    @doc "Read the rest of a streamed body until it ends or breaks."
    def drain(client, acc \\ []) do
      case next(client) do
        {:data, data, client} -> drain(client, [acc, data])
        {:done, client} -> {:done, IO.iodata_to_binary(acc), client}
        {:error, reason, client} -> {:error, reason, IO.iodata_to_binary(acc), client}
      end
    end

    @doc "Open a WebSocket through the gateway: `{:ok, ws}` or `{:error, status}`."
    def ws_connect(port, path, headers, protocols \\ []) do
      {:ok, conn} =
        Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])

      headers =
        if protocols == [],
          do: headers,
          else: [{"sec-websocket-protocol", Enum.join(protocols, ", ")} | headers]

      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
      client = await_head(%{conn: conn, ref: ref, status: nil, headers: nil, queue: []})

      if client.status == 101 do
        {:ok, conn, websocket} =
          Mint.WebSocket.new(client.conn, ref, 101, client.headers, mode: :passive)

        protocol =
          Enum.find_value(client.headers, fn {k, v} -> k == "sec-websocket-protocol" && v end)

        buffered = for {:data, _, data} <- client.queue, do: data
        ws = %{conn: conn, ref: ref, websocket: websocket, protocol: protocol, frames: []}
        {:ok, decode_buffered(ws, buffered)}
      else
        Mint.HTTP.close(client.conn)
        {:error, client.status}
      end
    end

    defp decode_buffered(ws, chunks) do
      Enum.reduce(chunks, ws, fn data, ws ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(ws.websocket, data)
        %{ws | websocket: websocket, frames: ws.frames ++ frames}
      end)
    end

    def ws_send(ws, frame) do
      {:ok, websocket, data} = Mint.WebSocket.encode(ws.websocket, frame)
      {:ok, conn} = Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data)
      %{ws | conn: conn, websocket: websocket}
    end

    @doc "The next frame: `{:ok, frame, ws}` or `{:closed, ws}`."
    def ws_recv(ws, timeout \\ @timeout)
    def ws_recv(%{frames: [frame | rest]} = ws, _timeout), do: {:ok, frame, %{ws | frames: rest}}

    def ws_recv(ws, timeout) do
      case Mint.WebSocket.recv(ws.conn, 0, timeout) do
        {:ok, conn, responses} ->
          chunks = for {:data, _, data} <- responses, do: data
          ws_recv(decode_buffered(%{ws | conn: conn}, chunks), timeout)

        {:error, conn, _reason, _} ->
          {:closed, %{ws | conn: conn}}
      end
    end

    @doc "Wait for the socket to close; the close frame if one came."
    def ws_await_close(ws, timeout \\ @timeout) do
      case ws_recv(ws, timeout) do
        {:ok, {:close, code, reason}, ws} -> {:close, code, reason, ws}
        {:ok, _other, ws} -> ws_await_close(ws, timeout)
        {:closed, ws} -> {:closed, ws}
      end
    end

    def ws_close(ws, code \\ 1000, reason \\ "") do
      ws = ws_send(ws, {:close, code, reason})
      Mint.HTTP.close(ws.conn)
      :ok
    end
  end
end
