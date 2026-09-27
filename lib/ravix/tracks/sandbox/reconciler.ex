defmodule Ravix.Tracks.Sandbox.Reconciler do
  @moduledoc "Singleton sweep; PostgreSQL leases also fence overlapping node takeovers."
  use GenServer
  alias Ravix.Projects.Deletion
  alias Ravix.Tracks.Sandbox

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def tick(client \\ Ravix.Fountain.client()) do
    # ownership: persisted operations authorize recovery and resource cleanup.
    Ravix.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(Sandbox.Store.pending(), &Sandbox.advance(client, &1),
      max_concurrency: 4,
      timeout: 300_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()

    Deletion.reconcile(client)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 5_000)
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    tick()
    schedule(interval)
    {:noreply, interval}
  end

  defp schedule(false), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
