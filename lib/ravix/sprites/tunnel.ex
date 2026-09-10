defmodule Ravix.Sprites.Tunnel do
  @max_owner_queue 256
  @handshake_timeout 15_000
  @max_frame 64 * 1024
  @resume_interval 10

  @moduledoc """
  Real TCP to a port inside a sprite, over the `/proxy` WebSocket.

  A preview runs on `127.0.0.1` inside the machine and is deliberately not
  on Sprites' public route, so the only way to reach it is the same way a
  shell on the box would: open a socket to the port. Sprites offers that as
  a WebSocket at `/v1/sprites/:name/proxy`. The handshake is an HTTP upgrade
  carrying the deployment token, one text frame naming the host and port,
  and one text frame back saying `{"status":"connected"}`. From then on every
  binary frame is bytes on the wire in one direction or the other, and the
  tunnel is a duplex stream that happens to be framed.

  One process per tunnel, owned by the process that opened it. Bytes from
  the sprite arrive in the opener's mailbox:

    * `{:tunnel, tunnel, {:data, binary}}`
    * `{:tunnel, tunnel, :closed}` exactly once, however the tunnel ends:
      the far end closing, a failure, or `close/1` from any process (which
      is how the gateway cuts a live stream when access is revoked)
    * `{:tunnel, tunnel, {:error, reason}}` followed by `:closed`

  Both directions are bounded. Writing with `send_data/2` hands the frame to
  the kernel and blocks the caller while the socket's send buffer is full;
  if the sprite stops reading for thirty seconds the write fails and the
  tunnel ends. Reading is paused (the socket is left in passive mode) while
  the owner's mailbox holds more than #{@max_owner_queue} messages and
  resumes as the owner catches up, which is the socket `pause`/`resume` the
  TypeScript did around a Duplex's high-water mark. An opener that never
  reads its mailbox therefore stalls the sprite rather than filling memory.

  The tunnel is not linked to its owner. It monitors the owner and stops
  when the owner exits; an owner that wants to know about the tunnel process
  itself can monitor the pid.
  """

  use GenServer

  alias Ravix.Sprites.Error

  @typedoc "An open tunnel."
  @type t :: pid()

  @typedoc "What the opener receives."
  @type message :: {:tunnel, t(), {:data, binary()} | :closed | {:error, term()}}

  @doc """
  Open a tunnel to `port` on `127.0.0.1` inside `sprite`, on behalf of the
  calling process (or `opts[:owner]`).

  Returns once Sprites has acknowledged the connection, or after
  `opts[:timeout]` milliseconds (default fifteen seconds) for each of the
  HTTP upgrade and the acknowledgement. Every failure is a
  `Ravix.Sprites.Error` with a message written to be shown, or
  `:unconfigured` when there is no Sprites token.
  """
  @spec open(Ravix.Sprites.config(), String.t(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, Error.t() | :unconfigured}
  def open(cfg, sprite, port, opts \\ [])

  def open(nil, _sprite, _port, _opts), do: {:error, :unconfigured}

  def open(cfg, sprite, port, opts) when is_binary(sprite) and is_integer(port) do
    owner = Keyword.get(opts, :owner, self())
    timeout = Keyword.get(opts, :timeout, @handshake_timeout)

    case GenServer.start(__MODULE__, {cfg, sprite, port, owner, timeout}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, %Error{} = error}} -> {:error, error}
      {:error, reason} -> {:error, Error.new(502, "Preview tunnel failed: #{inspect(reason)}")}
    end
  end

  @doc """
  Write bytes to the port inside the sprite.

  Blocks while the socket's send buffer is full (that is the backpressure)
  and returns `{:error, :closed}` once the tunnel has ended. Large payloads
  are split into frames of at most #{@max_frame} bytes; the far end sees a
  byte stream either way.
  """
  @spec send_data(t(), iodata()) :: :ok | {:error, term()}
  def send_data(tunnel, data) do
    GenServer.call(tunnel, {:send, data}, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @doc """
  End the tunnel, from any process. Idempotent.

  The owner receives `:closed` (once), so a body stream or head read in
  flight in the owner ends rather than waiting forever.
  """
  @spec close(t()) :: :ok
  def close(tunnel) do
    GenServer.stop(tunnel, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  # ── the handshake ────────────────────────────────────────────────────

  @impl true
  def init({cfg, sprite, port, owner, timeout}) do
    owner_ref = Process.monitor(owner)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, conn, scheme} <- connect(cfg, deadline),
         {:ok, conn, ref} <- upgrade(conn, scheme, cfg, sprite),
         {:ok, conn, websocket, early} <- accept(conn, ref, deadline),
         {:ok, conn, websocket} <- request_port(conn, ref, websocket, port),
         ack_deadline = System.monotonic_time(:millisecond) + timeout,
         {:ok, conn, websocket, frames} <-
           await_connected(conn, ref, websocket, early, ack_deadline) do
      state = %{
        conn: conn,
        ref: ref,
        websocket: websocket,
        socket: Mint.HTTP.get_socket(conn),
        scheme: scheme,
        owner: owner,
        owner_ref: owner_ref,
        paused: false,
        closed: false
      }

      case dispatch(frames, state) do
        {:ok, state} -> {:ok, resume(state)}
        {:stop, state} -> {:stop, {:shutdown, Error.new(502, "Preview tunnel ended.")}, state}
      end
    else
      {:error, %Error{} = error} -> {:stop, {:shutdown, error}}
    end
  end

  defp connect(cfg, deadline) do
    uri = URI.parse(cfg.base_url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    transport_opts = [
      timeout: remaining(deadline),
      send_timeout: 30_000,
      send_timeout_close: true
    ]

    case Mint.HTTP.connect(scheme, uri.host, port,
           protocols: [:http1],
           transport_opts: transport_opts
         ) do
      {:ok, conn} ->
        {:ok, conn, scheme}

      {:error, reason} ->
        {:error, Error.new(502, "Could not reach Sprites: #{Exception.message(reason)}")}
    end
  end

  defp upgrade(conn, scheme, cfg, sprite) do
    uri = URI.parse(cfg.base_url)
    ws_scheme = if scheme == :https, do: :wss, else: :ws
    base = String.trim_trailing(uri.path || "", "/")
    path = "#{base}/v1/sprites/#{URI.encode(sprite, &URI.char_unreserved?/1)}/proxy"
    headers = [{"authorization", "Bearer " <> cfg.token}]

    case Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Could not reach Sprites: #{Exception.message(reason)}")}
    end
  end

  # The HTTP half of the upgrade: status, headers, and whatever bytes Sprites
  # sent in the same packet as the 101 (Mint hands those over as data).
  defp accept(conn, ref, deadline, acc \\ %{status: nil, headers: [], data: []}) do
    case await_socket(conn, deadline) do
      {:ok, message} ->
        accept_message(conn, ref, deadline, acc, Mint.WebSocket.stream(conn, message))

      :timeout ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Sprites did not answer the tunnel request in time.")}
    end
  end

  defp accept_message(_conn, ref, deadline, acc, {:ok, conn, responses}) do
    case collect_upgrade(responses, ref, acc) do
      {:done, acc} -> establish(conn, ref, acc)
      {:more, acc} -> accept(conn, ref, deadline, acc)
    end
  end

  defp accept_message(_conn, _ref, _deadline, _acc, {:error, conn, reason, _responses}) do
    Mint.HTTP.close(conn)
    {:error, Error.new(502, "Sprites closed the tunnel: #{Exception.message(reason)}")}
  end

  @typep upgrade_acc :: %{
           status: non_neg_integer() | nil,
           headers: Mint.Types.headers(),
           data: iodata()
         }
  @spec collect_upgrade(list(), reference(), upgrade_acc()) :: {:more | :done, upgrade_acc()}
  defp collect_upgrade([], _ref, acc), do: {:more, acc}

  defp collect_upgrade([{:status, ref, status} | rest], ref, acc),
    do: collect_upgrade(rest, ref, %{acc | status: status})

  defp collect_upgrade([{:headers, ref, headers} | rest], ref, acc),
    do: collect_upgrade(rest, ref, %{acc | headers: acc.headers ++ headers})

  defp collect_upgrade([{:data, ref, data} | rest], ref, acc),
    do: collect_upgrade(rest, ref, %{acc | data: [acc.data, data]})

  defp collect_upgrade([{:done, ref} | _rest], ref, acc), do: {:done, acc}
  defp collect_upgrade([_other | rest], ref, acc), do: collect_upgrade(rest, ref, acc)

  defp establish(conn, ref, %{status: status, headers: headers, data: data}) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, conn, websocket, IO.iodata_to_binary(data)}

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{status_code: code}} ->
        Mint.HTTP.close(conn)

        {:error,
         Error.new(502, "Sprites refused the tunnel (#{code}). Check the deployment token.")}

      {:error, conn, _reason} ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Invalid Sprites WebSocket handshake.")}
    end
  end

  defp request_port(conn, ref, websocket, port) do
    init = Jason.encode!(%{host: "127.0.0.1", port: port})

    case send_frame(conn, ref, websocket, {:text, init}) do
      {:ok, websocket} ->
        {:ok, conn, websocket}

      {:error, reason} ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Sprites closed the tunnel: #{format(reason)}")}
    end
  end

  # The first message must be the connected acknowledgement. Anything else
  # (a binary frame, other JSON, a close) is Sprites refusing the port.
  # Frames that arrive with the acknowledgement are returned for delivery.
  defp await_connected(conn, ref, websocket, buffered, deadline) do
    with {:ok, websocket, frames} <- decode(websocket, buffered),
         {:ok, websocket, frames} <- answer_pings(conn, ref, websocket, frames),
         {:ok, :more} <- acknowledgement(frames) do
      case await_socket(conn, deadline) do
        {:ok, {tag, _socket, data}} when tag in [:tcp, :ssl] ->
          await_connected(conn, ref, websocket, data, deadline)

        {:ok, _closed_or_error} ->
          refuse(conn, "Sprites closed the tunnel before connecting.")

        :timeout ->
          refuse(conn, "Sprites tunnel acknowledgement timed out.")
      end
    else
      {:ok, :connected, rest} -> {:ok, conn, websocket, rest}
      {:refused, message} -> refuse(conn, message)
      {:error, reason} -> refuse(conn, "Preview tunnel failed: #{format(reason)}")
    end
  end

  defp acknowledgement([]), do: {:ok, :more}

  defp acknowledgement([{:text, text} | rest]) do
    case Jason.decode(text) do
      {:ok, %{"status" => "connected"}} -> {:ok, :connected, rest}
      _other -> {:refused, "Sprites refused the preview port."}
    end
  end

  defp acknowledgement([{:close, _code, _reason} | _rest]),
    do: {:refused, "Sprites closed the tunnel before connecting."}

  defp acknowledgement([_other | _rest]), do: {:refused, "Sprites refused the preview port."}

  defp refuse(conn, message) do
    Mint.HTTP.close(conn)
    {:error, Error.new(502, message)}
  end

  defp decode(websocket, <<>>), do: {:ok, websocket, []}

  defp decode(websocket, data) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} -> {:ok, websocket, frames}
      {:error, _websocket, reason} -> {:error, reason}
    end
  end

  defp answer_pings(conn, ref, websocket, frames) do
    frames
    |> Enum.reduce_while({:ok, websocket, []}, fn
      {:ping, data}, {:ok, websocket, kept} ->
        case send_frame(conn, ref, websocket, {:pong, data}) do
          {:ok, websocket} -> {:cont, {:ok, websocket, kept}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:pong, _data}, acc ->
        {:cont, acc}

      frame, {:ok, websocket, kept} ->
        {:cont, {:ok, websocket, [frame | kept]}}
    end)
    |> case do
      {:ok, websocket, kept} -> {:ok, websocket, Enum.reverse(kept)}
      {:error, _reason} = error -> error
    end
  end

  # One socket message, or :timeout at the deadline. Selective, so the
  # owner's monitor and anything else in the mailbox wait their turn.
  defp await_socket(conn, deadline) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {tag, ^socket, _payload} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        {:ok, message}

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        {:ok, message}
    after
      remaining(deadline) -> :timeout
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp format(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format(reason), do: inspect(reason)

  # ── the duplex ───────────────────────────────────────────────────────

  @impl true
  def handle_call({:send, _data}, _from, %{closed: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:send, data}, _from, state) do
    data
    |> IO.iodata_to_binary()
    |> frames()
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, state} ->
      case send_frame(state.conn, state.ref, state.websocket, {:binary, chunk}) do
        {:ok, websocket} -> {:cont, {:ok, %{state | websocket: websocket}}}
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
    |> case do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:stop, :normal, {:error, reason}, fail(state, reason)}
    end
  end

  defp frames(binary) when byte_size(binary) <= @max_frame, do: [binary]

  defp frames(<<chunk::binary-size(@max_frame), rest::binary>>), do: [chunk | frames(rest)]

  @impl true
  def handle_info({tag, socket, data}, %{socket: socket} = state) when tag in [:tcp, :ssl] do
    with {:ok, websocket, frames} <- decode(state.websocket, data),
         {:ok, websocket, frames} <- answer_pings(state.conn, state.ref, websocket, frames),
         {:ok, state} <- dispatch(frames, %{state | websocket: websocket}) do
      {:noreply, resume(state)}
    else
      {:stop, state} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, :normal, fail(state, reason)}
    end
  end

  def handle_info({tag, socket}, %{socket: socket} = state)
      when tag in [:tcp_closed, :ssl_closed] do
    {:stop, :normal, closed(state)}
  end

  def handle_info({tag, socket, reason}, %{socket: socket} = state)
      when tag in [:tcp_error, :ssl_error] do
    {:stop, :normal, fail(state, reason)}
  end

  def handle_info(:resume, state), do: {:noreply, resume(%{state | paused: false})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # Nobody is left to tell; a message to a dead process is a no-op anyway.
    {:stop, :normal, %{state | closed: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    state = if reason == :normal, do: closed(state), else: fail(state, reason)

    if Mint.HTTP.open?(state.conn) do
      _ = send_frame(state.conn, state.ref, state.websocket, :close)
      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # Binary frames are the byte stream; text after the acknowledgement is
  # not something Sprites sends and is ignored rather than trusted.
  defp dispatch([], state), do: {:ok, state}

  defp dispatch([{:binary, data} | rest], state) do
    send(state.owner, {:tunnel, self(), {:data, data}})
    dispatch(rest, state)
  end

  defp dispatch([{:close, _code, _reason} | _rest], state), do: {:stop, closed(state)}
  defp dispatch([_other | rest], state), do: dispatch(rest, state)

  # Re-arm the socket for one more packet unless the owner is behind, in
  # which case check again shortly: the pause is the backpressure.
  defp resume(%{closed: true} = state), do: state

  defp resume(state) do
    case Process.info(state.owner, :message_queue_len) do
      {:message_queue_len, queued} when queued < @max_owner_queue ->
        setopts = if state.scheme == :https, do: &:ssl.setopts/2, else: &:inet.setopts/2
        _ = setopts.(state.socket, active: :once)
        %{state | paused: false}

      _behind_or_gone ->
        unless state.paused, do: Process.send_after(self(), :resume, @resume_interval)
        %{state | paused: true}
    end
  end

  defp send_frame(conn, ref, websocket, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, frame),
         {:ok, _conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, websocket}
    else
      {:error, _websocket_or_conn, reason} -> {:error, reason}
    end
  end

  defp fail(%{closed: true} = state, _reason), do: state

  defp fail(state, reason) do
    send(state.owner, {:tunnel, self(), {:error, reason}})
    closed(state)
  end

  defp closed(%{closed: true} = state), do: state

  defp closed(state) do
    send(state.owner, {:tunnel, self(), :closed})
    %{state | closed: true}
  end
end
