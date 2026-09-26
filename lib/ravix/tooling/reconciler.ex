defmodule Ravix.Tooling.Reconciler do
  @moduledoc """
  Durable task bookkeeping, owned by the `tooling.tasks` cluster singleton.

  Queue hints join the same follower topics as PromptQueue.Server; settle
  events reconcile a thread once, sharing turns and event pages. The five-second
  backstop rotates through at most 50 aged threads per pass, so an unreachable
  provider cannot starve later threads. Nothing is handed over on node loss:
  subscriptions and the sweep cursor rebuild from the database (ADR 0003).
  Brief singleton overlap is safe: locked receipt writes reject stale cursors
  and terminal results. The singleton avoids multiplying provider traffic.
  """
  use GenServer
  require Logger
  alias Ravix.Tooling.{Store, Tasks}
  alias Ravix.Tracks.{Follower, Transcript.Event}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def tick(pid), do: GenServer.call(pid, :tick, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 5_000)

    if Keyword.get(opts, :subscribe, true),
      do: Phoenix.PubSub.subscribe(Ravix.PubSub, "tooling:queue")

    schedule(interval)
    {:ok, %{interval: interval, threads: MapSet.new(), cursor: ""}}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, sweep(state)}

  @impl true
  def handle_info(:tick, state) do
    state = sweep(state)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info({:tooling_queue, track_id}, state) when is_binary(track_id) do
    state = subscribe(state)
    reconcile(track_id: track_id)
    {:noreply, state}
  end

  def handle_info({:transcript, thread_id, %Event{} = event}, state) do
    if Event.settles?(event), do: reconcile(thread_id: thread_id)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp sweep(state) do
    state = subscribe(state)
    cutoff = DateTime.add(DateTime.utc_now(), -3, :second)
    ids = Store.due_threads(state.cursor, cutoff, 50)

    Task.Supervisor.async_stream_nolink(
      Ravix.TaskSupervisor,
      ids,
      fn id -> reconcile(thread_id: id) end,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    %{state | cursor: List.last(ids) || ""}
  end

  defp reconcile(opts) do
    # ownership: this singleton performs only bookkeeping of existing receipts;
    # Store correlates their queue rows. Tasks' public doors still authorize reads.
    case Tasks.reconcile_rows(Store.reconciliation_rows(opts)) do
      :ok -> :ok
      {:error, _} -> Logger.warning("Tooling task reconciliation deferred to the next sweep")
    end
  end

  defp subscribe(state) do
    # ownership: internal topic discovery for existing task receipts, never a
    # user subscription or a response containing task data.
    wanted = MapSet.new(Store.pending_threads())

    Enum.each(
      MapSet.difference(wanted, state.threads),
      &Phoenix.PubSub.subscribe(Ravix.PubSub, Follower.topic(&1))
    )

    Enum.each(
      MapSet.difference(state.threads, wanted),
      &Phoenix.PubSub.unsubscribe(Ravix.PubSub, Follower.topic(&1))
    )

    %{state | threads: wanted}
  end

  defp schedule(false), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
