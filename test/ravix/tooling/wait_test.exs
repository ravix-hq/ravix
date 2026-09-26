defmodule Ravix.Tooling.WaitTest do
  use Ravix.DataCase, async: true
  use Mimic
  import Ravix.ToolingFixture
  alias Ravix.{Fountain, Hub, Tooling, Tracks}
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{OAuth, Tasks}
  alias Ravix.Tracks.Follower
  alias Ravix.Tracks.Transcript.Event

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: Ecto.UUID.generate())
    {p, _, _} = principal(user)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    {:ok, one} = Tasks.send(p, track.id, "one", "one")
    {:ok, two} = Tasks.send(p, track.id, "two", "two")
    Enum.each([one, two], &QueueStore.mark_delivered(&1.id))
    test = self()

    stub(Tracks, :follow, fn _, _, opts ->
      Phoenix.PubSub.subscribe(Ravix.PubSub, Follower.topic(opts[:thread_id]))
      send(test, {:subscribed, self()})
      {:ok, test}
    end)

    {:ok, statuses} = Agent.start_link(fn -> %{one.id => "running", two.id => "running"} end)

    stub(Fountain, :turns, fn _, _ ->
      turns =
        Agent.get(statuses, & &1)
        |> Enum.map(fn {id, status} ->
          Fountain.Shapes.turn(%{"id" => id, "client_request_id" => id, "status" => status})
        end)

      send(test, :refreshed)
      {:ok, turns}
    end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    %{p: p, one: one, two: two, track: track, project: project, statuses: statuses}
  end

  test "turn PubSub wakes two-task wait promptly and returns every task", ctx do
    waiter = start_wait(ctx)
    assert_receive {:subscribed, server}
    assert_receive :refreshed
    assert_receive :refreshed
    Agent.update(ctx.statuses, &Map.put(&1, ctx.one.id, "ended"))

    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      Follower.topic(ctx.track.id),
      {:transcript, ctx.track.id,
       Event.from(%{"kind" => "stage", "stage" => "turn", "state" => "done"})}
    )

    assert {:ok, {:ok, result}} = Task.yield(waiter, 100)
    assert result.changed == [ctx.one.id]

    assert Enum.map(result.tasks, & &1.status.state) == [
             "TASK_STATE_COMPLETED",
             "TASK_STATE_WORKING"
           ]

    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  test "timeout returns all current states without polling on tokens", ctx do
    waiter = start_wait(ctx, %{"timeout_ms" => 100})
    assert_receive {:subscribed, _}
    assert_receive :refreshed
    assert_receive :refreshed

    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      Follower.topic(ctx.track.id),
      {:transcript, ctx.track.id, Event.from(%{"kind" => "output", "data" => "token"})}
    )

    assert {:ok, {:ok, %{changed: [], tasks: tasks}}} = Task.yield(waiter, 500)
    assert length(tasks) == 2
    refute_receive :refreshed, 0
  end

  test "since notices a nonterminal transition; known terminal states can wait", ctx do
    assert {:ok, %{changed: changed}} =
             Tooling.call(ctx.p, "wait_task", %{
               "task_ids" => [ctx.one.id],
               "since" => %{ctx.one.id => "TASK_STATE_SUBMITTED"},
               "timeout_ms" => 1000
             })

    assert changed == [ctx.one.id]
    Agent.update(ctx.statuses, &Map.put(&1, ctx.one.id, "failed"))

    assert {:ok, %{changed: [id]}} =
             Tooling.call(ctx.p, "wait_task", %{"task_ids" => [ctx.one.id], "timeout_ms" => 1000})

    assert id == ctx.one.id

    assert {:ok, %{changed: []}} =
             Tooling.call(ctx.p, "wait_task", %{
               "task_ids" => [id],
               "since" => %{id => "TASK_STATE_FAILED"},
               "timeout_ms" => 10
             })
  end

  test "queue changes wake the waiter and revocation is checked before returning", ctx do
    {:ok, queued} = Tasks.send(ctx.p, ctx.track.id, "queued", "queued")
    waiter = start_wait(ctx, %{"task_ids" => [queued.id, ctx.two.id]})
    assert_receive {:subscribed, _}
    assert_receive :refreshed
    QueueStore.set_status(queued.id, :failed)
    assert {:ok, {:ok, %{changed: [id]}}} = Task.yield(waiter, 1000)
    assert id == queued.id
    waiter = start_wait(ctx, %{"task_ids" => [ctx.two.id]})
    assert_receive {:subscribed, _}
    OAuth.disconnect(ctx.p.user, ctx.p.grant.id)
    Hub.publish(ctx.project.id, :people, track_id: ctx.track.id)
    assert {:ok, {:error, :unauthenticated}} = Task.yield(waiter, 1000)
  end

  test "queued cancellation through the scoped context wakes a waiter", ctx do
    {:ok, queued} = Tasks.send(ctx.p, ctx.track.id, "queued", "cancelled")
    waiter = start_wait(ctx, %{"task_ids" => [queued.id]})
    assert_receive {:subscribed, _}
    assert {:ok, _} = Tasks.cancel(ctx.p, queued.id)
    assert {:ok, {:ok, %{changed: [id], tasks: [task]}}} = Task.yield(waiter, 1000)
    assert id == queued.id
    assert task.status.state == "TASK_STATE_CANCELED"
  end

  test "foreign tasks and insufficient scopes are rejected before subscribing", ctx do
    {other, _, _} = principal(ctx.p.user)
    assert {:error, :not_found} = Tooling.call(other, "wait_task", %{"task_ids" => [ctx.one.id]})
    {limited, _, _} = principal(ctx.p.user, "mcp", ["tracks:write"])
    assert {:error, _} = Tooling.call(limited, "wait_task", %{"task_ids" => [ctx.one.id]})
    refute_receive {:subscribed, _}, 0
  end

  test "one active wait per user/client is admitted and the limit maps to 429", ctx do
    waiter = start_wait(ctx)
    assert_receive {:subscribed, _}

    assert {:error, {:rate_limited, message}} =
             Tooling.call(ctx.p, "wait_task", %{
               "task_ids" => [ctx.one.id],
               "timeout_ms" => 100
             })

    assert RavixWeb.Error.from({:rate_limited, message}).status == 429
    Task.shutdown(waiter, :brutal_kill)
  end

  test "invalid lists, timeouts and since values are rejected", ctx do
    for args <- [
          %{"task_ids" => []},
          %{"task_ids" => List.duplicate(ctx.one.id, 51)},
          %{"task_ids" => [ctx.one.id, ctx.one.id]},
          %{"task_ids" => [42]},
          %{"task_ids" => [ctx.one.id], "timeout_ms" => 50_001},
          %{"task_ids" => [ctx.one.id], "timeout_ms" => -1},
          %{"task_ids" => [ctx.one.id], "since" => %{ctx.one.id => 42}},
          %{"task_ids" => [ctx.one.id], "since" => %{"foreign" => "TASK_STATE_WORKING"}}
        ] do
      assert {:error, {:unprocessable, "invalid_arguments", _}} =
               Tooling.call(ctx.p, "wait_task", args)
    end

    assert {:ok, %{changed: [], tasks: [_]}} =
             Tooling.call(ctx.p, "wait_task", %{
               "task_ids" => [ctx.one.id],
               "timeout_ms" => 0
             })
  end

  test "deadline and caller death cancel blocked refreshes and release subscriptions", ctx do
    test = self()

    stub(Fountain, :turns, fn _, _ ->
      send(test, {:blocked, self()})

      receive do
        :never -> {:ok, []}
      end
    end)

    waiter = start_wait(ctx, %{"timeout_ms" => 100})
    assert_receive {:subscribed, server}
    assert_receive {:blocked, worker}
    server_ref = Process.monitor(server)
    worker_ref = Process.monitor(worker)
    assert {:ok, {:ok, %{changed: []}}} = Task.yield(waiter, 300)
    assert_receive {:DOWN, ^server_ref, :process, ^server, _}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}

    waiter = start_wait(ctx)
    assert_receive {:subscribed, server}
    assert_receive {:blocked, worker}
    server_ref = Process.monitor(server)
    worker_ref = Process.monitor(worker)
    Task.shutdown(waiter, :brutal_kill)
    assert_receive {:DOWN, ^server_ref, :process, ^server, _}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}

    refute Enum.any?(Registry.lookup(Ravix.PubSub, Follower.topic(ctx.track.id)), fn {pid, _} ->
             pid == server
           end)
  end

  defp start_wait(ctx, extra \\ %{}) do
    args = Map.merge(%{"task_ids" => [ctx.one.id, ctx.two.id], "timeout_ms" => 1000}, extra)

    Task.Supervisor.async_nolink(Ravix.TaskSupervisor, fn ->
      Tooling.call(ctx.p, "wait_task", args)
    end)
  end
end
