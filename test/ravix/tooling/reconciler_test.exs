defmodule Ravix.Tooling.ReconcilerTest do
  use Ravix.DataCase, async: true
  use Mimic
  import Ecto.Query
  import Ravix.ToolingFixture
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Fountain
  alias Ravix.PromptQueue.Store, as: Queue
  alias Ravix.Tooling.{Reconciler, Task, Tasks, Wait}
  alias Ravix.Tracks.{Follower, Transcript.Event}

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: Ecto.UUID.generate())
    {principal, _, _} = principal(user)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    %{p: principal, track: track, project: project}
  end

  test "settlement persists ten replies without get_task, sharing one thread read", c do
    tasks = for n <- 1..10, do: submit(c, "#{n}")
    server = server()
    :ok = Reconciler.tick(server)
    turns = Enum.map(tasks, &turn/1)
    events = Enum.with_index(tasks, 1) |> Enum.map(fn {t, n} -> event(t, n) end)

    expect(Fountain, :turns, fn _, id ->
      assert id == c.track.conversation_id
      {:ok, turns}
    end)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == nil
      {:ok, %{events: events, next_cursor: 10, has_more: false}}
    end)

    Phoenix.PubSub.subscribe(Ravix.PubSub, Tasks.topic(hd(tasks).id))
    settle(c.track.id)
    :sys.get_state(server)
    assert_receive {:tooling_task, _}

    for task <- tasks do
      assert %{state: "TASK_STATE_COMPLETED", result: "reply"} = Repo.get!(Task, task.id)
    end

    assert {:ok, %{tasks: results, stale: false}} =
             Wait.wait(c.p, %{"task_ids" => Enum.map(tasks, & &1.id), "timeout_ms" => 0})

    assert length(results) == 10
    assert Enum.all?(results, &(&1.status.state == "TASK_STATE_COMPLETED"))
    # A duplicate event has no remaining receipt to read from Fountain.
    settle(c.track.id)
    :sys.get_state(server)
  end

  test "a batch reuses paginated turn windows and never reads the later transcript", c do
    first = submit(c, "first")
    second = submit(c, "second")
    server = server()
    Reconciler.tick(server)

    events =
      Enum.map(1..100, &event(%{id: "earlier"}, &1)) ++
        Enum.map(101..175, &event(first, &1)) ++
        Enum.map(176..250, &event(second, &1)) ++
        Enum.map(251..750, &event(%{id: "later"}, &1))

    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(first), turn(second)]} end)

    expect(Fountain, :events_page, 3, fn _, _, opts ->
      cursor = opts[:after] || 0
      assert cursor in [0, 100, 200]
      {:ok, %{events: Enum.slice(events, cursor, 100), next_cursor: cursor + 100, has_more: true}}
    end)

    settle(c.track.id)
    :sys.get_state(server)

    for task <- [first, second] do
      assert Repo.get!(Task, task.id).result == String.duplicate("reply", 75)
      assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
    end
  end

  test "sweep selection is aged, bounded and advances beyond an unresolved thread", c do
    tasks =
      for n <- 1..3 do
        track = insert_track(project: c.project, conversation_id: Ecto.UUID.generate())
        {:ok, task} = Tasks.send(c.p, track.id, "hello", "#{n}")
        age(task)
        task
      end

    # Receipts created before the expand migration have no reconciliation stamp.
    ids = Enum.map(tasks, & &1.id)
    Repo.update_all(from(t in Task, where: t.id in ^ids), set: [reconciled_at: nil])
    {:ok, _young} = Tasks.send(c.p, c.track.id, "hello", "young")
    cutoff = DateTime.utc_now()
    [first, second] = Ravix.Tooling.Store.due_threads("", cutoff, 2)
    assert [third] = Ravix.Tooling.Store.due_threads(second, cutoff, 2)
    assert Enum.sort([first, second, third]) == Enum.sort(Enum.map(tasks, & &1.track_id))
    assert Ravix.Tooling.Store.due_threads(third, cutoff, 2) == []
  end

  test "backstop recovers a missed settlement from durable rows", c do
    task = submit(c, "missed")
    age(task)
    expect_reply(task)
    server = server()
    assert :ok = Reconciler.tick(server)
    assert %{state: "TASK_STATE_COMPLETED", result: "reply"} = Repo.get!(Task, task.id)
  end

  test "running turns use the long cadence while settlement bypasses it", c do
    task = submit(c, "running")
    age(task)
    server = server()
    running = %{turn(task) | status: "running"}

    reads = :atomics.new(2, [])

    stub(Fountain, :turns, fn _, _ ->
      :atomics.add(reads, 1, 1)
      {:ok, [running]}
    end)

    stub(Fountain, :events_page, fn _, _, _ ->
      :atomics.add(reads, 2, 1)
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    Reconciler.tick(server)
    first = Repo.get!(Task, task.id)
    assert first.state == "TASK_STATE_WORKING"
    assert first.reconciled_at

    # Simulate successive five-second sweeps without sleeping or mocking Tasks.
    for elapsed <- 5..40//5 do
      reconciled_ago(task, elapsed)
      Reconciler.tick(server)
      Reconciler.tick(server)
      assert :atomics.get(reads, 1) == 1
      assert :atomics.get(reads, 2) == 1
    end

    reconciled_ago(task, 46)
    Reconciler.tick(server)
    current = Repo.get!(Task, task.id)
    assert :atomics.get(reads, 1) == 2
    assert :atomics.get(reads, 2) == 2
    assert current.updated_at == first.updated_at
    assert DateTime.diff(DateTime.utc_now(), current.reconciled_at) < 3

    expect_reply(task)
    settle(c.track.id)
    :sys.get_state(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  test "sent submitted receipts retry within five seconds even without a state change", c do
    task = submit(c, "short")
    age(task)
    server = server()
    expect(Fountain, :turns, fn _, _ -> {:ok, []} end)
    Reconciler.tick(server)
    current = Repo.get!(Task, task.id)
    assert current.state == "TASK_STATE_SUBMITTED"
    assert current.reconciled_at

    reconciled_ago(task, 4)
    expect_reply(task)
    Reconciler.tick(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  for {state, queue_status} <- [
        {"TASK_STATE_INPUT_REQUIRED", :sent},
        {"TASK_STATE_WORKING", :sending}
      ] do
    test "#{state} with queue #{queue_status} retains the short cadence", c do
      state = unquote(state)
      queue_status = unquote(queue_status)
      {:ok, task} = Tasks.send(c.p, c.track.id, "hello", state)

      Repo.get!(Task, task.id)
      |> Ecto.Changeset.change(state: state, turn_id: task.id)
      |> Repo.update!()

      Queue.set_status(task.id, queue_status)
      reconciled_ago(task, 4)
      expect_reply(task)
      assert :ok = Reconciler.tick(server())
      assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
    end
  end

  defp reconciled_ago(task, seconds) do
    Repo.update_all(
      from(t in Task, where: t.id == ^task.id),
      set: [reconciled_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
    )
  end

  test "queue failures, unconfirmed delivery, retry and cancellation persist without reads", c do
    {:ok, task} = Tasks.send(c.p, c.track.id, "hello", "queue")
    server = server()

    for {status, expected} <- [
          failed: "TASK_STATE_FAILED",
          queued: "TASK_STATE_SUBMITTED",
          unconfirmed: "TASK_STATE_INPUT_REQUIRED",
          cancelled: "TASK_STATE_CANCELED"
        ] do
      Queue.set_status(task.id, status)
      :sys.get_state(server)
      assert Repo.get!(Task, task.id).state == expected
    end
  end

  test "confirmed delivery clears a persisted hold even before Fountain exposes its turn", c do
    {:ok, task} = Tasks.send(c.p, c.track.id, "hello", "held")
    server = server()
    Queue.set_status(task.id, :unconfirmed)
    :sys.get_state(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_INPUT_REQUIRED"
    expect(Fountain, :turns, fn _, _ -> {:ok, []} end)
    Queue.mark_delivered(task.id)
    :sys.get_state(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_SUBMITTED"
  end

  test "sent queue event reconciles a completed turn even before topic discovery", c do
    {:ok, task} = Tasks.send(c.p, c.track.id, "hello", "sent")
    server = server()
    expect_reply(task)
    Queue.mark_delivered(task.id)
    :sys.get_state(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  test "provider failure preserves rows for a later sweep", c do
    task = submit(c, "recover")
    age(task)
    server = server()
    expect(Fountain, :turns, fn _, _ -> {:error, :unavailable} end)
    assert :ok = Reconciler.tick(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_SUBMITTED"
    # A failed attempt is stamped too, so an immediate sweep does not retry.
    assert :ok = Reconciler.tick(server)
    age(task)
    expect_reply(task)
    assert :ok = Reconciler.tick(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  test "a cancellation during provider reconciliation cannot be overwritten", c do
    {:ok, task} = Tasks.send(c.p, c.track.id, "hello", "race")
    Queue.claim(task.id)
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(task)]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      Queue.set_status(task.id, :cancelled)
      {:ok, %{events: [event(task, 1)], next_cursor: 1, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_CANCELED"}} = Tasks.get(c.p, task.id)
    # The next event persists the queue state; the obsolete completion never won.
    refute Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  defp server do
    pid = start_supervised!({Reconciler, interval: false, subscribe: false})
    Sandbox.allow(Repo, self(), pid)
    allow(Fountain, self(), pid)

    # Subscribe only after sandbox/provider allowances exist. Other async tests
    # can publish queue hints as soon as this process joins the global topic.
    :sys.replace_state(pid, fn state ->
      Phoenix.PubSub.subscribe(Ravix.PubSub, "tooling:queue")
      state
    end)

    pid
  end

  defp submit(c, id) do
    {:ok, task} = Tasks.send(c.p, c.track.id, "hello", id)
    Queue.mark_delivered(task.id)
    task
  end

  defp age(task) do
    task
    |> Ecto.Changeset.change(
      updated_at: DateTime.add(DateTime.utc_now(), -10, :second),
      reconciled_at: DateTime.add(DateTime.utc_now(), -10, :second)
    )
    |> Repo.update!()
  end

  defp expect_reply(task) do
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(task)]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [event(task, 1)], next_cursor: 1, has_more: false}}
    end)
  end

  defp settle(id) do
    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      Follower.topic(id),
      {:transcript, id, Event.from(%{"kind" => "stage", "stage" => "turn", "state" => "done"})}
    )
  end

  defp turn(task),
    do:
      Fountain.Shapes.turn(%{
        "id" => task.id,
        "status" => "completed",
        "client_request_id" => task.id
      })

  defp event(task, n),
    do: %{
      "id" => n,
      "turn_id" => task.id,
      "kind" => "output",
      "stream" => "stdout",
      "data" => "reply",
      "ts" => "2026-09-26T00:00:00Z"
    }
end
