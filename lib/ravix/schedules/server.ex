defmodule Ravix.Schedules.Server do
  @moduledoc "Cluster singleton timer; durable claims also protect against overlapping cluster membership."
  use GenServer
  alias Ravix.Schedules.Runner

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 30_000)
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    task = Task.Supervisor.async_nolink(Ravix.TaskSupervisor, &Runner.tick/0)
    Task.await(task, :infinity)
    schedule(interval)
    {:noreply, interval}
  end

  defp schedule(false), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
