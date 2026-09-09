defmodule RavixWeb.PreviewGateway.Watch do
  @moduledoc """
  Access, re-checked for as long as a connection stays open.

  A request is authorized once, but a stream or a WebSocket may live for
  hours, and membership can end in the meantime: the person is removed from
  the track, signs out, the track closes, or the preview is rebuilt under a
  new generation. So every open connection has a watcher: it subscribes to
  the project's hub events and also checks once a second, and the moment the
  grant no longer stands it closes the connection.

  The watcher is linked to the connection process, so a connection that ends
  takes its watcher with it; the gateway also stops it explicitly, since one
  keep-alive connection serves many requests. Closing has two halves: a
  `{:preview_gateway, :close}` message to the owner, which a WebSocket
  handles between frames, and a closer attached once the tunnel exists, which
  cuts an HTTP stream blocked on the sprite.
  """

  use GenServer

  alias RavixWeb.PreviewGateway.Backend

  @interval 1000

  @doc """
  Check now and, if the grant stands, start watching on the caller's behalf.

  Returns `:revoked` when the grant already fails, so the caller can answer
  401 before proxying anything.
  """
  @spec start(module(), Backend.row(), Backend.grant(), String.t()) ::
          GenServer.on_start() | :revoked
  def start(backend, row, grant, project_id) do
    if allowed?(backend, row, grant) do
      GenServer.start_link(__MODULE__, {backend, row, grant, project_id, self()})
    else
      :revoked
    end
  end

  @doc "Run `closer` on revocation; immediately if it already happened."
  @spec attach(pid(), (-> any())) :: :ok
  def attach(pid, closer) when is_function(closer, 0), do: GenServer.call(pid, {:attach, closer})

  @doc "Whether the watcher has closed the connection."
  @spec closed?(pid()) :: boolean()
  def closed?(pid), do: GenServer.call(pid, :closed?)

  @doc "The connection is over; stop watching."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({backend, row, grant, project_id, owner}) do
    Ravix.Hub.subscribe(project_id)
    Process.send_after(self(), :tick, @interval)

    {:ok, %{backend: backend, row: row, grant: grant, owner: owner, closed: false, closer: nil}}
  end

  @impl true
  def handle_call({:attach, closer}, _from, %{closed: true} = state) do
    closer.()
    {:reply, :ok, %{state | closer: closer}}
  end

  def handle_call({:attach, closer}, _from, state), do: {:reply, :ok, %{state | closer: closer}}
  def handle_call(:closed?, _from, state), do: {:reply, state.closed, state}

  @impl true
  def handle_info({:hub, _event}, state), do: {:noreply, check(state)}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval)
    {:noreply, check(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp check(%{closed: true} = state), do: state

  defp check(%{backend: backend, row: row, grant: grant} = state) do
    current = backend.preview(row.track_id)

    if allowed?(backend, row, grant) and current != nil and current.generation == row.generation do
      state
    else
      close(state)
    end
  end

  defp close(state) do
    send(state.owner, {:preview_gateway, :close})
    if state.closer, do: state.closer.()
    %{state | closed: true}
  end

  defp allowed?(backend, row, grant), do: backend.allowed?(row, grant)
end
