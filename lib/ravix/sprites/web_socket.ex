defmodule Ravix.Sprites.WebSocket do
  @moduledoc """
  The half of a Sprites WebSocket that does not care what it carries.

  Two things talk to a sprite over a WebSocket: `Ravix.Sprites.Tunnel`, which
  is TCP to a port inside the machine over `/proxy`, and `Ravix.Sprites.Pty`,
  which is a terminal over `/exec`. Both are an HTTP upgrade carrying the
  deployment token, then frames. That part was written once, inside the
  tunnel; it is here so the terminal does not have a second copy of it, with
  its own idea of what a failed upgrade is called.

  Everything is functional over a `t:t/0`, as Mint is: the process that
  called `connect/4` owns the socket and receives its messages. After the
  upgrade the socket is left passive; the owner arms it with `arm/1` for one
  packet at a time, which is how both callers apply backpressure.

  `noun` is the word the errors use for the thing being opened --- "tunnel",
  "terminal" --- since they are read by people and "the WebSocket" is not
  what they asked for.

  A refused upgrade is a 502 by default: to the preview gateway's browser,
  Sprites answering 401 is a bad gateway, not a reason to sign in again.
  `upstream_status: true` keeps Sprites' own status instead, for a caller
  that must tell "this session no longer exists" (404) from "the machine
  could not be reached".
  """

  alias Ravix.Sprites.Error

  @enforce_keys [:conn, :ref, :websocket, :socket, :scheme]
  defstruct @enforce_keys

  @typedoc "An upgraded connection: Mint's, the request ref, and the frame codec."
  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          ref: Mint.Types.request_ref(),
          websocket: Mint.WebSocket.t(),
          socket: :inet.socket() | :ssl.sslsocket(),
          scheme: :http | :https
        }

  @typedoc "A frame, as `Mint.WebSocket` decodes and encodes them."
  @type frame :: Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()

  @doc """
  Upgrade `path` (under the configured base URL) to a WebSocket.

  Returns the connection and whatever bytes Sprites sent in the same packet
  as the `101`, which are frames the caller must decode before anything else.
  `deadline` is monotonic milliseconds and bounds the TCP connect and the
  upgrade together.
  """
  @spec connect(Ravix.Config.Sprites.t(), String.t(), integer(), String.t(), keyword()) ::
          {:ok, t(), binary()} | {:error, Error.t()}
  def connect(cfg, path, deadline, noun, opts \\ []) do
    labels = %{noun: noun, upstream_status: Keyword.get(opts, :upstream_status, false)}

    with {:ok, conn, scheme} <- open(cfg, deadline),
         {:ok, conn, ref} <- upgrade(conn, scheme, cfg, path),
         {:ok, conn, websocket, early} <- accept(conn, ref, deadline, labels) do
      {:ok,
       %__MODULE__{
         conn: conn,
         ref: ref,
         websocket: websocket,
         socket: Mint.HTTP.get_socket(conn),
         scheme: scheme
       }, early}
    end
  end

  defp open(cfg, deadline) do
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

  defp upgrade(conn, scheme, cfg, path) do
    uri = URI.parse(cfg.base_url)
    ws_scheme = if scheme == :https, do: :wss, else: :ws
    base = String.trim_trailing(uri.path || "", "/")
    headers = [{"authorization", "Bearer " <> cfg.token}]

    case Mint.WebSocket.upgrade(ws_scheme, conn, base <> path, headers) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Could not reach Sprites: #{Exception.message(reason)}")}
    end
  end

  # The HTTP half of the upgrade: status, headers, and whatever bytes Sprites
  # sent in the same packet as the 101 (Mint hands those over as data).
  defp accept(conn, ref, deadline, labels, acc \\ %{status: nil, headers: [], data: []}) do
    case await_socket(conn, deadline) do
      {:ok, message} ->
        accept_message(conn, ref, deadline, labels, acc, Mint.WebSocket.stream(conn, message))

      :timeout ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Sprites did not answer the #{labels.noun} request in time.")}
    end
  end

  defp accept_message(_conn, ref, deadline, labels, acc, {:ok, conn, responses}) do
    case collect_upgrade(responses, ref, acc) do
      {:done, acc} -> establish(conn, ref, labels, acc)
      {:more, acc} -> accept(conn, ref, deadline, labels, acc)
    end
  end

  defp accept_message(_conn, _ref, _deadline, labels, _acc, {:error, conn, reason, _responses}) do
    Mint.HTTP.close(conn)
    {:error, Error.new(502, "Sprites closed the #{labels.noun}: #{Exception.message(reason)}")}
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

  defp establish(conn, ref, labels, %{status: status, headers: headers, data: data}) do
    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, conn, websocket, IO.iodata_to_binary(data)}

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{status_code: code}} ->
        Mint.HTTP.close(conn)
        status = if labels.upstream_status and code in 400..599, do: code, else: 502

        {:error,
         Error.new(
           status,
           "Sprites refused the #{labels.noun} (#{code}). Check the deployment token."
         )}

      {:error, conn, _reason} ->
        Mint.HTTP.close(conn)
        {:error, Error.new(502, "Invalid Sprites WebSocket handshake.")}
    end
  end

  # ── frames ───────────────────────────────────────────────────────────

  @doc "Frames out of bytes read from the socket; a partial frame is kept for the next call."
  @spec decode(t(), binary()) :: {:ok, t(), [Mint.WebSocket.frame()]} | {:error, term()}
  def decode(%__MODULE__{} = ws, <<>>), do: {:ok, ws, []}

  def decode(%__MODULE__{} = ws, data) do
    case Mint.WebSocket.decode(ws.websocket, data) do
      {:ok, websocket, frames} -> {:ok, %{ws | websocket: websocket}, frames}
      {:error, _websocket, reason} -> {:error, reason}
    end
  end

  @doc "Answer every ping among `frames` and return the rest, in order."
  @spec answer_pings(t(), [Mint.WebSocket.frame()]) ::
          {:ok, t(), [Mint.WebSocket.frame()]} | {:error, term()}
  def answer_pings(%__MODULE__{} = ws, frames) do
    frames
    |> Enum.reduce_while({:ok, ws, []}, fn
      {:ping, data}, {:ok, ws, kept} ->
        case send_frame(ws, {:pong, data}) do
          {:ok, ws} -> {:cont, {:ok, ws, kept}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:pong, _data}, acc ->
        {:cont, acc}

      frame, {:ok, ws, kept} ->
        {:cont, {:ok, ws, [frame | kept]}}
    end)
    |> case do
      {:ok, ws, kept} -> {:ok, ws, Enum.reverse(kept)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encode and write one frame. Blocks while the socket's send buffer is full."
  @spec send_frame(t(), frame()) :: {:ok, t()} | {:error, term()}
  def send_frame(%__MODULE__{} = ws, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(ws.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data) do
      {:ok, %{ws | websocket: websocket, conn: conn}}
    else
      {:error, _websocket_or_conn, reason} -> {:error, reason}
    end
  end

  # ── the socket ───────────────────────────────────────────────────────

  @doc """
  One socket message for this connection, or `:timeout` at the deadline.
  Selective, so the owner's monitors and anything else in the mailbox wait
  their turn.
  """
  @spec await_socket(Mint.HTTP.t() | t(), integer()) :: {:ok, tuple()} | :timeout
  def await_socket(%__MODULE__{conn: conn}, deadline), do: await_socket(conn, deadline)

  def await_socket(conn, deadline) do
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

  @doc """
  What a message in the owner's mailbox means for this connection: bytes,
  the far end closing, a socket error, or `:unknown` for a message that is
  not this socket's.
  """
  @spec classify(t(), term()) ::
          {:data, binary()} | :closed | {:error, term()} | :unknown
  def classify(%__MODULE__{socket: socket}, {tag, socket, data}) when tag in [:tcp, :ssl],
    do: {:data, data}

  def classify(%__MODULE__{socket: socket}, {tag, socket}) when tag in [:tcp_closed, :ssl_closed],
    do: :closed

  def classify(%__MODULE__{socket: socket}, {tag, socket, reason})
      when tag in [:tcp_error, :ssl_error],
      do: {:error, reason}

  def classify(_ws, _message), do: :unknown

  @doc "Ask for the next packet as a message: backpressure is not calling this."
  @spec arm(t()) :: :ok
  def arm(%__MODULE__{scheme: :https, socket: socket}) do
    _ = :ssl.setopts(socket, active: :once)
    :ok
  end

  def arm(%__MODULE__{socket: socket}) do
    _ = :inet.setopts(socket, active: :once)
    :ok
  end

  @doc "Say goodbye if the socket is still up, and close it. Idempotent."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = ws) do
    if Mint.HTTP.open?(ws.conn) do
      _ = send_frame(ws, :close)
      Mint.HTTP.close(ws.conn)
    end

    :ok
  end

  @doc "Milliseconds until `deadline`, never negative."
  @spec remaining(integer()) :: non_neg_integer()
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
