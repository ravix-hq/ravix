defmodule Ravix.Tooling.TasksTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{OAuth, Task, Tasks}
  import Ravix.ToolingFixture

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: "conversation")
    {p, _, _} = principal(user)
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "test-key") end)
    %{user: user, p: p, project: project, track: track}
  end

  test "explicit thread delivery and polling stay in that conversation", %{p: p, track: track} do
    {:ok, thread} =
      Ravix.Tracks.Store.create_thread(%{
        track_id: track.id,
        title: "Next",
        conversation_id: "next"
      })

    assert {:ok, task} = Tasks.send(p, track.id, "hello", "request", thread.id)
    assert QueueStore.get(task.id).thread_id == thread.id

    assert {:error, {:conflict, "request_id_used", _}} =
             Tasks.send(p, track.id, "hello", "request")

    foreign = insert_track()
    assert {:error, :not_found} = Tasks.send(p, track.id, "hello", "other", foreign.id)
    QueueStore.mark_delivered(task.id)
    expect(Fountain, :turns, fn _, "next" -> {:ok, [turn(task.id, "mine", "completed")]} end)

    expect(Fountain, :events_page, fn _, "next", _ ->
      {:ok, %{events: [event(1, "mine", "Answer")], next_cursor: 1, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_COMPLETED", result: "Answer"}} = Tasks.get(p, task.id)
  end

  test "submission is durable, retries return the same task, conflicting arguments fail", %{
    p: p,
    track: track
  } do
    assert {:ok, task} = Tasks.send(p, track.id, "hello", "request")
    assert Repo.get!(Task, task.id).state == "TASK_STATE_SUBMITTED"
    assert QueueStore.get(task.id).body["prompt"] == "hello"
    assert {:ok, %{id: id}} = Tasks.send(p, track.id, "hello", "request")
    assert id == task.id

    assert {:error, {:conflict, "request_id_used", _}} =
             Tasks.send(p, track.id, "different", "request")

    assert {:ok, %{state: "TASK_STATE_SUBMITTED"}} = Tasks.get(p, task.id)
    assert {:ok, %{state: "TASK_STATE_CANCELED"}} = Tasks.cancel(p, task.id)
    assert {:ok, %{state: "TASK_STATE_CANCELED"}} = Tasks.cancel(p, task.id)
    assert QueueStore.get(task.id).status == :cancelled
  end

  test "delivery is not completion and only the correlated turn contributes its reply", %{
    p: p,
    track: track
  } do
    {:ok, task} = Tasks.send(p, track.id, "hello", "request")
    QueueStore.mark_delivered(task.id)
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn("someone-else", "other", "completed")]} end)
    assert {:ok, %{state: "TASK_STATE_SUBMITTED"}} = Tasks.get(p, task.id)
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(task.id, "mine", "completed")]} end)

    expect(Fountain, :events_page, fn _, "conversation", opts ->
      assert opts[:limit] == 100

      {:ok,
       %{
         events: [event(1, "other", "Private other reply"), event(2, "mine", "My answer")],
         next_cursor: 2,
         has_more: false
       }}
    end)

    assert {:ok, done} = Tasks.get(p, task.id)
    assert done.state == "TASK_STATE_COMPLETED"
    assert done.result == "My answer"
    assert done.turn_id == "mine"
    assert {:ok, ^done} = Tasks.get(p, task.id)
    assert {:error, {:conflict, "task_not_cancelable", _}} = Tasks.cancel(p, task.id)
  end

  test "pages accumulate once and provider failures preserve receipts", %{p: p, track: track} do
    {:ok, task} = Tasks.send(p, track.id, "hello", "request")
    QueueStore.mark_delivered(task.id)
    stub(Fountain, :turns, fn _, _ -> {:error, {:unconfigured, :fountain}} end)
    assert {:error, _} = Tasks.get(p, task.id)
    assert Repo.get!(Task, task.id).state == "TASK_STATE_SUBMITTED"
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(task.id, "mine", "done")]} end)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == nil
      {:ok, %{events: [event(1, "mine", "one ")], next_cursor: 1, has_more: true}}
    end)

    assert {:ok, %{state: "TASK_STATE_WORKING", result: "one "}} = Tasks.get(p, task.id)

    expect(Fountain, :events_page, fn _, _, opts ->
      assert opts[:after] == 1
      {:ok, %{events: [event(2, "mine", "two")], next_cursor: 2, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_COMPLETED", result: "one two"}} = Tasks.get(p, task.id)
  end

  test "task IDs never grant access to other users or clients; revoked memberships stop reads", %{
    p: p,
    track: track
  } do
    {:ok, task} = Tasks.send(p, track.id, "hello", "request")
    {other_client, _, _} = principal(p.user)
    assert {:error, :not_found} = Tasks.get(other_client, task.id)
    guest = insert_user()
    insert_track_member(track, guest)
    {guest_p, _, _} = principal(guest)
    assert {:error, :not_found} = Tasks.get(guest_p, task.id)
    assert {:ok, own} = Tasks.send(guest_p, track.id, "my prompt", "guest-message")
    Repo.delete_all(Ravix.Tracks.TrackMember)
    assert {:error, :not_found} = Tasks.get(guest_p, own.id)
    assert {:error, :not_found} = Tasks.cancel(guest_p, own.id)
    assert {:ok, %{tasks: [], totalSize: 0}} = Tasks.list(guest_p, %{})
    OAuth.disconnect(p.user, p.grant.id)
    assert {:error, :unauthenticated} = Tasks.get(p, task.id)
  end

  test "failed/cancelled delivery and unconfirmed running work have distinct states", %{
    p: p,
    track: track
  } do
    {:ok, task} = Tasks.send(p, track.id, "hello", "request")
    QueueStore.set_status(task.id, :failed)
    assert {:ok, %{state: "TASK_STATE_FAILED"}} = Tasks.get(p, task.id)
    {:ok, task2} = Tasks.send(p, track.id, "second", "request2")
    QueueStore.set_status(task2.id, :cancelled)
    assert {:ok, %{state: "TASK_STATE_CANCELED"}} = Tasks.get(p, task2.id)
    {:ok, task3} = Tasks.send(p, track.id, "third", "request3")
    QueueStore.mark_delivered(task3.id)
    assert {:error, {:conflict, "task_not_cancelable", _}} = Tasks.cancel(p, task3.id)
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(task3.id, "t3", "running")]} end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_WORKING"}} = Tasks.get(p, task3.id)
  end

  test "listing is scoped, filtered and paginated without returning artifacts by default", %{
    p: p,
    track: track
  } do
    {:ok, first} = Tasks.send(p, track.id, "one", "first")
    {:ok, second} = Tasks.send(p, track.id, "two", "second")
    assert {:ok, page} = Tasks.list(p, %{"pageSize" => 1})
    assert [%{id: id} = item] = page.tasks
    assert id == second.id
    refute Map.has_key?(item, :artifacts)
    assert page.totalSize == 2
    assert page.nextPageToken != ""

    assert {:ok, next} =
             Tasks.list(p, %{
               "pageSize" => 1,
               "pageToken" => page.nextPageToken,
               "includeArtifacts" => true
             })

    assert [%{id: id, artifacts: [_]}] = next.tasks
    assert id == first.id
    assert next.nextPageToken == ""
    assert {:ok, %{tasks: []}} = Tasks.list(p, %{"contextId" => "other"})
    assert {:ok, %{tasks: []}} = Tasks.list(p, %{"status" => "TASK_STATE_FAILED"})

    assert {:ok, %{tasks: []}} =
             Tasks.list(p, %{"statusTimestampAfter" => "2099-01-01T00:00:00Z"})

    for params <- [
          %{"pageSize" => 0},
          %{"pageToken" => "bad"},
          %{"statusTimestampAfter" => "bad"},
          %{"historyLength" => -1}
        ] do
      assert {:error, _} = Tasks.list(p, params)
    end
  end

  defp turn(request, id, status),
    do: Fountain.Shapes.turn(%{"id" => id, "status" => status, "client_request_id" => request})

  defp event(id, turn, data),
    do: %{
      "id" => id,
      "turn_id" => turn,
      "kind" => "output",
      "stream" => "stdout",
      "data" => data,
      "ts" => "2026-09-22T00:00:00Z"
    }
end
