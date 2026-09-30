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
  alias Ravix.Sprites.WebSocket

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
  `{:unconfigured, :sprites}` when there is no Sprites token.
  """
  @spec open(Ravix.Sprites.config(), String.t(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, Error.t() | {:unconfigured, :sprites}}
  def open(cfg, sprite, port, opts \\ [])

  def open(nil, _sprite, _port, _opts), do: {:error, {:unconfigured, :sprites}}

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
    path = "/v1/sprites/#{URI.encode(sprite, &URI.char_unreserved?/1)}/proxy"

    with {:ok, ws, early} <- WebSocket.connect(cfg, path, deadline, "tunnel"),
         {:ok, ws} <- request_port(ws, port),
         ack_deadline = System.monotonic_time(:millisecond) + timeout,
         {:ok, ws, frames} <- await_connected(ws, early, ack_deadline) do
      state = %{
        ws: ws,
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

  defp request_port(ws, port) do
    init = Jason.encode!(%{host: "127.0.0.1", port: port})

    case WebSocket.send_frame(ws, {:text, init}) do
      {:ok, ws} ->
        {:ok, ws}

      {:error, reason} ->
        Mint.HTTP.close(ws.conn)
        {:error, Error.new(502, "Sprites closed the tunnel: #{format(reason)}")}
    end
  end

  # The first message must be the connected acknowledgement. Anything else
  # (a binary frame, other JSON, a close) is Sprites refusing the port.
  # Frames that arrive with the acknowledgement are returned for delivery.
  # The acknowledgement is settled inside the `do` block, not the `else`.
  #
  # A `with`'s bindings are not visible to its `else`, so the `:connected`
  # branch used to return the `websocket` *parameter* rather than the one
  # `decode/2` rebound -- discarding whatever partial frame it had buffered. The
  # tunnel then resumed decoding mid-frame and the preview "answered with
  # something other than HTTP" (#15). Here the `else` only handles `{:error, _}`,
  # which needs no websocket, and every path that does have one names it.
  defp await_connected(ws, buffered, deadline) do
    with {:ok, ws, frames} <- WebSocket.decode(ws, buffered),
         {:ok, ws, frames} <- WebSocket.answer_pings(ws, frames) do
      case acknowledgement(frames) do
        # This connection: the one that decoded these frames.
        {:ok, :connected, rest} -> {:ok, ws, rest}
        {:ok, :more} -> await_more(ws, deadline)
        {:refused, message} -> refuse(ws, message)
      end
    else
      {:error, reason} -> refuse(ws, "Preview tunnel failed: #{format(reason)}")
    end
  end

  # Split out only because inlining it puts `await_connected/3` past Credo's
  # nesting and complexity limits.
  defp await_more(ws, deadline) do
    case WebSocket.await_socket(ws, deadline) do
      {:ok, {tag, _socket, data}} when tag in [:tcp, :ssl] ->
        await_connected(ws, data, deadline)

      {:ok, _closed_or_error} ->
        refuse(ws, "Sprites closed the tunnel before connecting.")

      :timeout ->
        refuse(ws, "Sprites tunnel acknowledgement timed out.")
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

  defp refuse(ws, message) do
    Mint.HTTP.close(ws.conn)
    {:error, Error.new(502, message)}
  end

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
      case WebSocket.send_frame(state.ws, {:binary, chunk}) do
        {:ok, ws} -> {:cont, {:ok, %{state | ws: ws}}}
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
  def handle_info(:resume, state), do: {:noreply, resume(%{state | paused: false})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    # Nobody is left to tell; a message to a dead process is a no-op anyway.
    {:stop, :normal, %{state | closed: true}}
  end

  def handle_info(message, state) do
    case WebSocket.classify(state.ws, message) do
      {:data, data} -> received(data, state)
      :closed -> {:stop, :normal, closed(state)}
      {:error, reason} -> {:stop, :normal, fail(state, reason)}
      :unknown -> {:noreply, state}
    end
  end

  defp received(data, state) do
    with {:ok, ws, frames} <- WebSocket.decode(state.ws, data),
         {:ok, ws, frames} <- WebSocket.answer_pings(ws, frames),
         {:ok, state} <- dispatch(frames, %{state | ws: ws}) do
      {:noreply, resume(state)}
    else
      {:stop, state} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, :normal, fail(state, reason)}
    end
  end

  @impl true
  def terminate(reason, state) do
    state = if reason == :normal, do: closed(state), else: fail(state, reason)

    WebSocket.close(state.ws)
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
        WebSocket.arm(state.ws)
        %{state | paused: false}

      _behind_or_gone ->
        unless state.paused, do: Process.send_after(self(), :resume, @resume_interval)
        %{state | paused: true}
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
