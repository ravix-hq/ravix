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

  for status <- ["running", "interrupted", "failed", "completed"] do
    test "suspension hint settles a #{status} turn without a turn stage", c do
      task = submit(c, "suspend")
      server = server()
      Reconciler.tick(server)
      events = Ravix.SuspensionFixture.events(task.id)
      expect(Fountain, :turns, fn _, _ -> {:ok, [%{turn(task) | status: unquote(status)}]} end)

      expect(Fountain, :events_page, fn _, _, _ ->
        {:ok, %{events: events, next_cursor: 3, has_more: false}}
      end)

      send(server, {:transcript, c.track.id, Event.from(List.last(events))})
      :sys.get_state(server)
      saved = Repo.get!(Task, task.id)
      assert saved.state == "TASK_STATE_FAILED"
      assert saved.result == Ravix.SuspensionFixture.message()
      assert saved.failure_message == saved.result
      assert Repo.get_by!(Ravix.Tracks.TurnFailure, turn_id: task.id).code == "machine_suspended"
    end
  end

  for {status, expected} <- [
        {"interrupted", "TASK_STATE_FAILED"},
        {"ended", "TASK_STATE_COMPLETED"}
      ] do
    test "45-second backstop settles WORKING when Fountain reports #{status}", c do
      task = submit(c, "backstop")

      task
      |> Ecto.Changeset.change(state: "TASK_STATE_WORKING", turn_id: task.id)
      |> Repo.update!()

      reconciled_ago(task, 46)
      expect(Fountain, :turns, fn _, _ -> {:ok, [%{turn(task) | status: unquote(status)}]} end)

      expect(Fountain, :events_page, fn _, _, _ ->
        {:ok, %{events: [event(task, 1)], next_cursor: 1, has_more: false}}
      end)

      assert :ok = Reconciler.tick(server())
      assert Repo.get!(Task, task.id).state == unquote(expected)
    end
  end

  test "an uncorrelated suspension after the saved cursor settles the active receipt", c do
    task = submit(c, "cursor")

    task
    |> Ecto.Changeset.change(
      state: "TASK_STATE_WORKING",
      turn_id: task.id,
      cursor: 2,
      turn_seen: true
    )
    |> Repo.update!()

    reconciled_ago(task, 46)
    expect(Fountain, :turns, fn _, _ -> {:ok, [%{turn(task) | status: "running"}]} end)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == 2

      {:ok,
       %{events: [List.last(Ravix.SuspensionFixture.events())], next_cursor: 3, has_more: false}}
    end)

    assert :ok = Reconciler.tick(server())
    assert Repo.get!(Task, task.id).failure_message == Ravix.SuspensionFixture.message()
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
        Queue.mark_delivered(task.id)
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

  test "unchanged threads back off to five minutes and settlement resets the cadence", c do
    task = submit(c, "running")
    age(task)
    server = server()
    reads = :atomics.new(1, [])

    stub(Fountain, :turns, fn _, _ ->
      :atomics.add(reads, 1, 1)
      {:ok, [%{turn(task) | status: "running"}]}
    end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    for {delay, count} <- Enum.with_index([5, 60, 180, 300, 300], 1) do
      make_due(c.track.id)
      Reconciler.tick(server)
      checkpoint = Ravix.Tooling.Store.checkpoint(c.track.id, c.track.conversation_id)
      assert_in_delta DateTime.diff(checkpoint.next_due_at, DateTime.utc_now()), delay, 1
      assert :atomics.get(reads, 1) == count
      Reconciler.tick(server)
      assert :atomics.get(reads, 1) == count
    end

    # A settle hint bypasses five minutes of backoff even if the provider still says running.
    settle(c.track.id)
    :sys.get_state(server)
    assert :atomics.get(reads, 1) == 6
    assert Ravix.Tooling.Store.checkpoint(c.track.id, c.track.conversation_id).unchanged == 0
    expect_reply(task)
    settle(c.track.id)
    :sys.get_state(server)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_COMPLETED"
  end

  defp make_due(id) do
    Repo.update_all(from(c in Ravix.Tooling.ThreadCheckpoint, where: c.id == ^id),
      set: [next_due_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
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
    make_due(c.track.id)
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
    make_due(c.track.id)
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

  test "new pages and reply fragments survive restart, and later receipts inherit the thread cursor",
       c do
    alias Ravix.Fountain.FakeTransport
    task = submit(c, "incremental")
    age(task)
    client = FakeTransport.client()
    stub(Fountain, :client, fn -> client end)
    base = "/api/conversations/#{c.track.conversation_id}"
    server = server()

    for {cursor, last, status} <- [
          {nil, 100, "running"},
          {100, 101, "running"},
          {101, 102, "completed"}
        ] do
      FakeTransport.expect(
        client,
        %{method: "GET", path: base <> "/turns"},
        {200, [], %{data: [%{id: task.id, client_request_id: task.id, status: status}]}}
      )

      query = if cursor, do: %{limit: "100", after: to_string(cursor)}, else: %{limit: "100"}

      events =
        if cursor == nil,
          do: Enum.map(1..100, &event(%{id: "old"}, &1)),
          else: [event(task, last)]

      FakeTransport.expect(
        client,
        %{method: "GET", path: base <> "/events", query: query},
        {200, [], %{data: events, meta: %{next_cursor: last, has_more: cursor == nil}}}
      )

      make_due(c.track.id)
      Reconciler.tick(server)
      assert Repo.get!(Task, task.id).cursor == last
      assert Ravix.Tooling.Store.checkpoint(c.track.id, c.track.conversation_id).cursor == last
    end

    assert length(FakeTransport.calls(client)) == 6

    assert %{result: "replyreply", state: "TASK_STATE_COMPLETED", reply_events: []} =
             Repo.get!(Task, task.id)

    GenServer.stop(server)
    replacement = server()
    Reconciler.tick(replacement)
    assert length(FakeTransport.calls(client)) == 6
    GenServer.stop(replacement)
    {:ok, next} = Tasks.send(c.p, c.track.id, "next", "next")
    assert next.cursor == 102
  end

  test "a replacement resumes an unfinished reply from the durable cursor", c do
    task = submit(c, "restart")
    age(task)
    first = server()
    expect(Fountain, :turns, fn _, _ -> {:ok, [%{turn(task) | status: "running"}]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [event(task, 1)], next_cursor: 1, has_more: false}}
    end)

    Reconciler.tick(first)
    GenServer.stop(first)
    second = server()
    make_due(c.track.id)
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(task)]} end)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == 1
      {:ok, %{events: [event(task, 2)], next_cursor: 2, has_more: false}}
    end)

    Reconciler.tick(second)
    assert Repo.get!(Task, task.id).result == "replyreply"
  end

  test "held-only and terminal threads are neither due nor subscribed", c do
    {:ok, held} = Tasks.send(c.p, c.track.id, "hello", "held-only")
    Queue.set_status(held.id, :unconfirmed)
    Tasks.reconcile_rows(Ravix.Tooling.Store.reconciliation_rows(thread_id: c.track.id))
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert Ravix.Tooling.Store.due_threads("", future, 50) == []
    assert Ravix.Tooling.Store.pending_threads() == []
    Queue.set_status(held.id, :cancelled)
    Tasks.reconcile_rows(Ravix.Tooling.Store.reconciliation_rows(thread_id: c.track.id))
    assert Ravix.Tooling.Store.due_threads("", future, 50) == []
  end

  test "transcript chunks never enter the reconciler mailbox", c do
    submit(c, "stream")
    pid = server(false)
    Reconciler.tick(pid)
    :sys.suspend(pid)

    try do
      for id <- 1..1000 do
        Phoenix.PubSub.broadcast(
          Ravix.PubSub,
          Follower.topic(c.track.id),
          {:transcript, c.track.id, Event.from(event(%{id: "running"}, id))}
        )
      end

      assert {:messages, []} = Process.info(pid, :messages)
      settle(c.track.id)
      assert {:messages, [{:transcript, _, %Event{stage: "turn"}}]} = Process.info(pid, :messages)
    after
      # Discard the synthetic settlement without making a provider request.
      :sys.replace_state(pid, fn state ->
        receive do
          {:transcript, _, _} -> :ok
        after
          0 -> :ok
        end

        state
      end)

      :sys.resume(pid)
    end
  end

  test "a hint fences an older reconcile's backoff write", c do
    alias Ravix.Tooling.Store
    before = Store.checkpoint(c.track.id, c.track.conversation_id)
    Store.reset_checkpoint(c.track.id, c.track.conversation_id)
    Store.finish_checkpoint(before, "unchanged")
    Store.advance_checkpoint(c.track.id, c.track.conversation_id, 100)
    current = Store.checkpoint(c.track.id, c.track.conversation_id)
    assert current.signature == nil
    assert current.unchanged == 0
    assert DateTime.compare(current.next_due_at, DateTime.utc_now()) != :gt
    assert current.cursor == 100
  end

  test "receipt and thread cursor roll back together when a transaction fails", c do
    task = submit(c, "atomic-cursor")
    expect_reply(task)

    assert {:error, :interrupted} =
             Ravix.Tooling.Store.transaction(fn ->
               :ok =
                 Tasks.reconcile_rows(
                   Ravix.Tooling.Store.reconciliation_rows(thread_id: c.track.id)
                 )

               assert Ravix.Tooling.Store.checkpoint(c.track.id, c.track.conversation_id).cursor ==
                        1

               Ravix.Tooling.Store.rollback(:interrupted)
             end)

    assert Repo.get!(Task, task.id).cursor == nil
    assert Ravix.Tooling.Store.checkpoint(c.track.id, c.track.conversation_id).cursor == nil
    assert Repo.get!(Task, task.id).state == "TASK_STATE_SUBMITTED"
  end

  defp server(subscribe \\ true) do
    # A graceful stop waits for an in-flight query before releasing the process.
    # A supervisor's shutdown signal can interrupt another async test's queue hint.
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Reconciler, interval: false, subscribe: false},
          restart: :temporary
        )
      )

    Sandbox.allow(Repo, self(), pid)
    allow(Fountain, self(), pid)

    # Subscribe only after sandbox/provider allowances exist. Other async tests
    # can publish queue hints as soon as this process joins the global topic.
    :sys.replace_state(pid, fn state ->
      if subscribe, do: Phoenix.PubSub.subscribe(Ravix.PubSub, "tooling:queue")
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
      Follower.settle_topic(id),
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
