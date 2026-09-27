defmodule RavixWeb.PreviewGateway.Relay do
  @moduledoc """
  A browser's WebSocket, relayed frame for frame to the app in the sprite.

  By the time this handler starts, the gateway has authorized the request,
  opened the tunnel and had the app accept the upgrade, so the tunnel is a
  raw duplex carrying server frames. Bandit frames the browser side; `Frame`
  does the sprite side. Text stays text and binary stays binary, pings from
  the app are answered here, and a close from either end closes the other.

  Backpressure: Bandit writes a pushed frame to the browser before taking
  the next message, so what the TypeScript measured as `bufferedAmount` is
  here the tunnel data that piled up in the mailbox while a slow browser was
  being written to. Each turn drains that backlog and, past two MiB, closes
  the socket rather than let it grow. Writes towards the sprite are
  synchronous into the tunnel, so the browser's frames are paced by it.
  """

  @behaviour WebSock

  require Logger

  alias RavixWeb.PreviewGateway.{Frame, Watch}

  @backlog 2 * 1024 * 1024

  @type state :: %{
          tunnel: term(),
          tunnel_module: module(),
          watch: pid(),
          decoder: Frame.decoder(),
          backend: module(),
          row: RavixWeb.PreviewGateway.Backend.row()
        }

  @impl true
  def init(%{tunnel: _, tunnel_module: _, watch: _} = state) do
    {leftover, state} = Map.pop(state, :leftover, <<>>)
    state = Map.put(state, :decoder, Frame.new())

    case Frame.decode(state.decoder, leftover) do
      {:ok, [], decoder} -> {:ok, %{state | decoder: decoder}}
      {:ok, frames, decoder} -> dispatch(frames, [], %{state | decoder: decoder})
      {:error, _reason} -> failed(state)
    end
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) do
    case state.tunnel_module.send_data(state.tunnel, Frame.encode({opcode, data})) do
      :ok -> {:ok, state}
      {:error, _reason} -> failed(state)
    end
  end

  @impl true
  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:tunnel, tunnel, {:data, data}}, %{tunnel: tunnel} = state) do
    {data, size} = drain(tunnel, [data], byte_size(data))

    if size > @backlog do
      close(state, {1009, "Preview socket backlog"})
    else
      case Frame.decode(state.decoder, IO.iodata_to_binary(data)) do
        {:ok, frames, decoder} -> dispatch(frames, [], %{state | decoder: decoder})
        {:error, _reason} -> failed(state)
      end
    end
  end

  def handle_info({:tunnel, tunnel, :closed}, %{tunnel: tunnel} = state),
    do: failed(state)

  def handle_info({:tunnel, tunnel, {:error, _}}, %{tunnel: tunnel} = state),
    do: failed(state)

  def handle_info({:preview_gateway, :close}, state),
    do:
      close(
        state,
        if(retired?(state), do: {1001, "Preview ended"}, else: {1008, "Preview access ended"})
      )

  # The watcher died: without it revocation cannot be enforced, so fail closed.
  def handle_info({:EXIT, watch, _reason}, %{watch: watch} = state),
    do: failed(state)

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    Watch.stop(state.watch)
    state.tunnel_module.close(state.tunnel)
    :ok
  end

  # Everything the tunnel has already delivered, oldest first.
  defp drain(tunnel, acc, size) do
    receive do
      {:tunnel, ^tunnel, {:data, more}} -> drain(tunnel, [acc, more], size + byte_size(more))
    after
      0 -> {acc, size}
    end
  end

  defp dispatch([], pushes, state), do: {:push, Enum.reverse(pushes), state}

  defp dispatch([{type, data} | rest], pushes, state) when type in [:text, :binary],
    do: dispatch(rest, [{type, data} | pushes], state)

  defp dispatch([{:ping, data} | rest], pushes, state) do
    case state.tunnel_module.send_data(state.tunnel, Frame.encode({:pong, data})) do
      :ok ->
        dispatch(rest, pushes, state)

      {:error, _} ->
        failed(state, pushes)
    end
  end

  defp dispatch([{:pong, _} | rest], pushes, state), do: dispatch(rest, pushes, state)

  # 1005 and 1006 are the codes for "no code" and "lost"; neither may be sent.
  defp dispatch([{:close, code, reason} | _], pushes, state) do
    detail =
      if (code && code >= 1000) and code not in [1005, 1006],
        do: {code, reason},
        else: {1011, "Preview socket closed"}

    close(state, detail, pushes)
  end

  # Intent is persisted before the provider stops the service. Read it here too:
  # the transport can disappear before Watch delivers its revocation message.
  # Watch still owns when access/generation changes terminate a live connection.
  defp retired?(%{backend: backend, row: row}) do
    case backend.preview(row.track_id) do
      nil -> false
      current -> current.desired == :stopped or current.generation != row.generation
    end
  end

  defp failed(state, pushes \\ []) do
    detail =
      if retired?(state),
        do: {1001, "Preview ended"},
        else: {1011, "Preview socket failed"}

    close(state, detail, pushes)
  end

  # All relay exits use WebSock's normal stop with an explicit close detail.
  # Bandit writes that frame and ends the browser side after cleanup.
  defp close(state, {code, _reason} = detail, pushes \\ []) do
    Logger.debug("Preview WebSocket close code=#{code} frames=#{length(pushes)}")
    {:stop, :normal, detail, Enum.reverse(pushes), state}
  end
end
