defmodule Ravix.Sprites.Pty do
  @moduledoc """
  An interactive terminal on a sprite: Sprites' exec WebSocket in TTY mode.

  `Ravix.Sprites.exec/4` is one HTTP request and one answer, which is right
  for `git status` and wrong for `iex -S mix`. Sprites also offers the same
  exec as a WebSocket (`/v1/sprites/:name/exec`), and with `tty=true` the
  process gets a real pseudo-terminal: raw bytes both ways as binary frames,
  and JSON text frames for everything else --- `resize` from us,
  `session_info` and `exit` from Sprites. Fountain's own client drives its
  agents' turns over this transport; see Fountain's
  `docs/integrations/sprites-contract.md`, "The exec transport".

  Two further parts of that contract are what make a terminal survive a
  browser reconnecting or an instance going away:

    * `detachable=true` keeps the process running when the socket drops, and
      `session_info` names it. `max_run_after_disconnect` bounds how long an
      abandoned one lives, so a closed laptop does not leave a shell on the
      machine for ever.
    * `/v1/sprites/:name/exec/:session_id` re-attaches to it, and replays its
      buffered output from the start before tailing, which is what gives a
      reattached terminal its scrollback back.

  `kill/3` is the REST `POST .../exec/:session_id/kill`, for a terminal that
  must end rather than merely be let go.

  This is functional over a `t:t/0`, as `Ravix.Sprites.WebSocket` is. The
  process that called `open/4` owns the socket, feeds each of its messages
  to `handle/2`, and asks for the next packet with `arm/1` when it is ready
  for one --- the owner, `Ravix.Terminal.Shell`, decides what backpressure
  means. Nothing here logs or traces the bytes: a terminal carries whatever
  somebody typed, including a password at a prompt.
  """

  alias Ravix.Sprites.Error
  alias Ravix.Sprites.WebSocket
  alias Ravix.Trace

  @handshake_timeout 15_000
  @max_frame 64 * 1024

  # How long a detached shell outlives the last socket to it. Long enough to
  # ride out a deploy or a laptop lid; short enough that a terminal somebody
  # walked away from does not keep a process on the machine all week.
  @max_run_after_disconnect "30m"

  @enforce_keys [:ws]
  defstruct @enforce_keys

  @typedoc "An open terminal socket."
  @type t :: %__MODULE__{ws: WebSocket.t()}

  @typedoc """
  What to open: a new shell, or one that is already running.

  A new one is an argv, a working directory, environment and a size; an
  existing one is the id `session_info` gave it.
  """
  @type target ::
          {:spawn,
           %{
             argv: [String.t(), ...],
             dir: String.t(),
             env: [{String.t(), String.t()}],
             cols: pos_integer(),
             rows: pos_integer()
           }}
          | {:attach, String.t()}

  @typedoc """
  What the socket said, in order:

    * `{:data, bytes}` --- terminal output, escape sequences and all
    * `{:session, id}` --- the id to re-attach with later
    * `{:exit, code}` --- the process ended
    * `:closed` --- the socket ended without one; the process may still run
  """
  @type event :: {:data, binary()} | {:session, String.t()} | {:exit, integer()} | :closed

  @doc """
  Open a terminal. Blocks the caller for the handshake, up to
  `opts[:timeout]` milliseconds (fifteen seconds by default).

  Returns the events that arrived with the upgrade, which the caller handles
  before anything else, and leaves the socket passive: call `arm/1` for the
  first packet.
  """
  @spec open(Ravix.Sprites.config(), String.t(), target(), keyword()) ::
          {:ok, t(), [event()]} | {:error, Error.t() | {:unconfigured, :sprites}}
  def open(cfg, sprite, target, opts \\ [])

  def open(nil, _sprite, _target, _opts), do: {:error, {:unconfigured, :sprites}}

  def open(cfg, sprite, target, opts) when is_binary(sprite) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @handshake_timeout)

    # The span says which sprite and whether this was a new shell or a
    # reattach. Not the argv, the directory or the environment: the same
    # rule as `Ravix.Sprites.exec/4`, for the same reason.
    Trace.span(
      "sprites.pty",
      %{"ravix.sprite" => sprite, "ravix.pty" => elem(target, 0) |> Atom.to_string()},
      fn -> connect(cfg, path(sprite, target), deadline) end
    )
  end

  defp connect(cfg, path, deadline) do
    with {:ok, ws, early} <-
           WebSocket.connect(cfg, path, deadline, "terminal", upstream_status: true) do
      pty = %__MODULE__{ws: ws}

      case frames(pty, early) do
        {:ok, pty, events} -> {:ok, pty, events}
        {:error, reason} -> {:error, failed(pty, reason)}
      end
    end
  end

  defp path(sprite, {:spawn, spec}) do
    query =
      Enum.map(spec.argv, &{"cmd", &1}) ++
        [{"path", hd(spec.argv)}, {"dir", spec.dir}] ++
        Enum.map(spec.env, fn {k, v} -> {"env", "#{k}=#{v}"} end) ++
        [
          {"stdin", "true"},
          {"tty", "true"},
          {"cols", Integer.to_string(spec.cols)},
          {"rows", Integer.to_string(spec.rows)},
          {"detachable", "true"},
          {"max_run_after_disconnect", @max_run_after_disconnect}
        ]

    "/v1/sprites/#{encode(sprite)}/exec?" <> URI.encode_query(query)
  end

  defp path(sprite, {:attach, session_id}),
    do: "/v1/sprites/#{encode(sprite)}/exec/#{encode(session_id)}"

  @doc """
  What one message in the owner's mailbox means for this terminal.

  `:unknown` for a message that is not this socket's, so the owner can hand
  every message here first. After an `{:ok, ...}` the socket is passive
  again until `arm/1`.
  """
  @spec handle(t(), term()) :: {:ok, t(), [event()]} | {:error, term()} | :unknown
  def handle(%__MODULE__{ws: ws} = pty, message) do
    case WebSocket.classify(ws, message) do
      {:data, data} -> frames(pty, data)
      :closed -> {:ok, pty, [:closed]}
      {:error, reason} -> {:error, reason}
      :unknown -> :unknown
    end
  end

  defp frames(pty, data) do
    with {:ok, ws, frames} <- WebSocket.decode(pty.ws, data),
         {:ok, ws, frames} <- WebSocket.answer_pings(ws, frames) do
      {:ok, %{pty | ws: ws}, Enum.flat_map(frames, &event/1)}
    end
  end

  # In TTY mode a binary frame is the terminal's bytes, unprefixed.
  defp event({:binary, data}), do: [{:data, data}]
  defp event({:text, text}), do: control(Jason.decode(text))
  defp event({:close, _code, _reason}), do: [:closed]
  defp event(_other), do: []

  defp control({:ok, %{"type" => "session_info", "session_id" => id}})
       when is_binary(id) and id != "",
       do: [{:session, id}]

  # The Elixir SDK normalises an integer id to a string; so does this.
  defp control({:ok, %{"type" => "session_info", "session_id" => id}}) when is_integer(id),
    do: [{:session, Integer.to_string(id)}]

  defp control({:ok, %{"type" => "exit"} = message}) do
    case message["exit_code"] do
      code when is_integer(code) -> [{:exit, code}]
      _missing -> [{:exit, 0}]
    end
  end

  # `port` notifications and anything this version does not know.
  defp control(_other), do: []

  @doc "Bytes typed into the terminal. Large pastes go as several frames."
  @spec input(t(), iodata()) :: {:ok, t()} | {:error, term()}
  def input(%__MODULE__{} = pty, data) do
    data
    |> IO.iodata_to_binary()
    |> chunks()
    |> Enum.reduce_while({:ok, pty}, fn chunk, {:ok, pty} ->
      case WebSocket.send_frame(pty.ws, {:binary, chunk}) do
        {:ok, ws} -> {:cont, {:ok, %{pty | ws: ws}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp chunks(<<>>), do: []
  defp chunks(binary) when byte_size(binary) <= @max_frame, do: [binary]
  defp chunks(<<chunk::binary-size(@max_frame), rest::binary>>), do: [chunk | chunks(rest)]

  @doc "The terminal's new size, in character cells."
  @spec resize(t(), pos_integer(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def resize(%__MODULE__{} = pty, cols, rows) when cols > 0 and rows > 0 do
    message = Jason.encode!(%{type: "resize", cols: cols, rows: rows})

    case WebSocket.send_frame(pty.ws, {:text, message}) do
      {:ok, ws} -> {:ok, %{pty | ws: ws}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Ask for the next packet as a message."
  @spec arm(t()) :: :ok
  def arm(%__MODULE__{ws: ws}), do: WebSocket.arm(ws)

  @doc """
  Let go of the terminal without ending it: the socket closes and the
  process carries on until somebody re-attaches or
  `max_run_after_disconnect` runs out.
  """
  @spec detach(t()) :: :ok
  def detach(%__MODULE__{ws: ws}), do: WebSocket.close(ws)

  @doc """
  End a terminal's process on the machine, attached or not.

  A session Sprites no longer knows is already ended, which is what was
  asked for, so a 404 is `:ok`.
  """
  @spec kill(Ravix.Sprites.config(), String.t(), String.t()) ::
          :ok | {:error, Error.t() | {:unconfigured, :sprites}}
  def kill(nil, _sprite, _session_id), do: {:error, {:unconfigured, :sprites}}

  def kill(cfg, sprite, session_id) do
    # SIGHUP rather than Sprites' default SIGTERM: an interactive bash ignores
    # SIGTERM, and a hang-up is what a terminal closing means to a shell.
    Trace.span("sprites.pty_kill", %{"ravix.sprite" => sprite}, fn ->
      [
        method: :post,
        url: "#{cfg.base_url}/v1/sprites/#{encode(sprite)}/exec/#{encode(session_id)}/kill",
        params: [signal: "SIGHUP", timeout: "5s"],
        auth: {:bearer, cfg.token},
        retry: false,
        decode_body: false,
        receive_timeout: 20_000
      ]
      |> Keyword.merge(Application.get_env(:ravix, :req_options, []))
      |> Req.new()
      |> Req.request()
      |> case do
        {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          {:error, Error.new(502, "Sprites said #{status} when asked to end the terminal.")}

        {:error, _reason} ->
          {:error, Error.new(502, "Could not reach the machine to end the terminal.")}
      end
    end)
  end

  defp failed(pty, reason) do
    WebSocket.close(pty.ws)
    Error.new(502, "The terminal's first answer could not be read: #{inspect(reason)}")
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
