defmodule Ravix.Tooling.Wait do
  @moduledoc """
  Request-owned waits. Broadcasts are hints; scoped persisted tasks are the answer.

  Both Hub.publish/3 and Follower.relay/5 use Phoenix.PubSub.broadcast/3,
  not local_broadcast. The existing cluster distribution suite proves follower topic fan-out
  crosses nodes. Hub uses the same configured PubSub adapter. A waiter subscribes to those
  same topics, and Tracks.follow/3 keeps the globally named follower alive
  even without a browser. No local task-state cache or singleton waiter is used.
  The database is re-read under OAuth/ownership checks before every response.

  One active waiter per OAuth user/client pair is admitted cluster-wide.
  Provider reads run outside the receive loop and are killed at the deadline.
  A timeout returns the latest persisted states when the provider cannot finish.
  """
  use GenServer, restart: :temporary
  alias Ravix.{Hub, Tracks}
  alias Ravix.Tooling.Tasks
  alias Ravix.Tracks.{Follower, Transcript.Event}

  def wait(principal, args) do
    ids = args["task_ids"]
    since = Map.get(args, "since", %{})
    timeout = Map.get(args, "timeout_ms", 50_000)
    deadline = now() + timeout

    with true <- Enum.all?(Map.keys(since), &(&1 in ids)),
         {:ok, rows} <- Tasks.observe(principal, ids) do
      if timeout == 0 or result(rows, since).changed != [] do
        {:ok, result(rows, since)}
      else
        run(%{principal: principal, ids: ids, since: since, rows: rows, deadline: deadline})
      end
    else
      false ->
        {:error, {:unprocessable, "invalid_arguments", "since must name only requested tasks."}}

      error ->
        error
    end
  end

  defp run(args) do
    ref = make_ref()
    args = Map.merge(args, %{owner: self(), ref: ref, callers: Process.get(:"$callers", [])})

    case DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, args}) do
      {:ok, pid} ->
        await(pid, args, ref)

      {:error, {:already_started, _}} ->
        {:error,
         {:rate_limited,
          "A wait is already active for this user and client. Retry after it returns."}}

      {:error, _} ->
        {:error, {:unavailable, "Could not start task wait."}}
    end
  end

  defp await(pid, args, ref) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {^ref, result} -> result
        {:DOWN, ^monitor, :process, ^pid, _} -> {:error, {:unavailable, "Task refresh failed."}}
      after
        max(args.deadline - now(), 0) -> snapshot(args)
      end
    after
      send(pid, :cancel)
      Process.demonitor(monitor, [:flush])
    end
  end

  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: {:global, name(args.principal)})

  defp name(principal), do: {__MODULE__, principal.user.id, principal.grant.client_id}

  @impl true
  def init(args) do
    Process.put(:"$callers", [args.owner | args.callers])
    owner_ref = Process.monitor(args.owner)
    timer = Process.send_after(self(), :deadline, max(args.deadline - now(), 0))

    state =
      Map.merge(args, %{
        owner_ref: owner_ref,
        timer: timer,
        projects: [],
        followers: %{},
        worker: nil,
        dirty: false
      })

    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    projects = state.rows |> Enum.map(& &1.project_id) |> Enum.uniq()
    Enum.each(projects, &Hub.subscribe/1)
    state = %{state | projects: projects}
    state = follow(state)
    {:noreply, refresh(state)}
  end

  defp follow(state) do
    state =
      case Tasks.observe(state.principal, state.ids) do
        {:ok, rows} -> %{state | rows: rows}
        {:error, _} -> state
      end

    state.rows
    |> Enum.uniq_by(& &1.thread_id)
    |> Enum.reject(&(is_nil(&1.conversation_id) or Tasks.terminal?(&1.task)))
    |> Enum.reduce(state, &follow_row/2)
  end

  defp follow_row(row, state) do
    if Map.has_key?(state.followers, row.thread_id) or now() >= state.deadline do
      state
    else
      case Tracks.follow(state.principal.user, row.track_id, thread_id: row.thread_id) do
        {:ok, pid} ->
          %{
            state
            | followers: Map.put(state.followers, row.thread_id, {pid, Process.monitor(pid)})
          }

        {:error, _} ->
          state
      end
    end
  end

  @impl true
  def handle_info(:cancel, state), do: {:stop, :normal, state}
  def handle_info(:deadline, state), do: finish(state, snapshot(state))

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({ref, result}, %{worker: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | worker: nil}

    refreshed(state, result)
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %Task{ref: ref}} = state),
    do: finish(%{state | worker: nil}, {:error, {:unavailable, "Task refresh failed."}})

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    followers = Map.reject(state.followers, fn {_, {_, monitor}} -> monitor == ref end)
    {:noreply, follow(%{state | followers: followers})}
  end

  def handle_info({:hub, %Hub.Event{} = event}, state) do
    relevant =
      event.project_id in state.projects and event.name in [:turn, :queue, :people, :tracks] and
        Enum.any?(state.rows, &(is_nil(event.track_id) or event.track_id == &1.track_id))

    {:noreply, if(relevant, do: refresh(follow(state)), else: state)}
  end

  def handle_info({:transcript, thread_id, %Event{kind: :stage} = event}, state) do
    relevant =
      Map.has_key?(state.followers, thread_id) and
        (event.stage == "turn" or Event.failed_stage?(event))

    {:noreply, if(relevant, do: refresh(state), else: state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp refreshed(state, {:ok, _}) do
    case snapshot(state) do
      {:ok, %{changed: []}} ->
        if state.dirty, do: {:noreply, refresh(%{state | dirty: false})}, else: {:noreply, state}

      result ->
        finish(state, result)
    end
  end

  defp refreshed(state, error), do: finish(state, error)

  defp refresh(%{worker: %Task{}} = state), do: %{state | dirty: true}

  defp refresh(state) do
    principal = state.principal
    ids = state.ids

    worker =
      Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn -> refresh_tasks(principal, ids) end)

    %{state | worker: worker}
  end

  defp refresh_tasks(principal, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, tasks} ->
      case Tasks.get(principal, id) do
        {:ok, task} -> {:cont, {:ok, [task | tasks]}}
        error -> {:halt, error}
      end
    end)
  end

  defp snapshot(state) do
    with {:ok, rows} <- Tasks.observe(state.principal, state.ids),
         do: {:ok, result(rows, state.since)}
  end

  defp result(rows, since) do
    tasks = Enum.map(rows, & &1.task)

    changed =
      Enum.filter(tasks, fn task ->
        case Map.fetch(since, task.id) do
          {:ok, previous} -> task.state != previous
          :error -> Tasks.terminal?(task)
        end
      end)

    %{tasks: Enum.map(tasks, &Tasks.present/1), changed: Enum.map(changed, & &1.id)}
  end

  defp finish(state, result) do
    :global.unregister_name(name(state.principal))
    send(state.owner, {state.ref, result})
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    if state.worker, do: Task.shutdown(state.worker, :brutal_kill)
    Enum.each(state.projects, &Hub.unsubscribe/1)

    Enum.each(state.followers, fn {id, {_, ref}} ->
      Process.demonitor(ref, [:flush])
      Follower.unsubscribe(id)
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
