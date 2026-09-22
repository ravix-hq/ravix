defmodule RavixWeb.ToolingStreamTest do
  use RavixWeb.ConnCase, async: true
  use Mimic
  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.PromptQueue.Store, as: QueueStore
  alias Ravix.Tooling.{OAuth, Tasks}
  alias RavixWeb.Tooling.Stream
  import Ravix.ToolingFixture

  setup do
    user = insert_user()
    project = insert_project(user: user, runtime: "plain")
    track = insert_track(project: project, conversation_id: "conversation")
    {p, _, _} = principal(user, "a2a")
    stub(Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
    {:ok, task} = Tasks.send(p, track.id, "hello", "stream-test")
    QueueStore.mark_delivered(task.id)
    %{p: p, task: task, track: track}
  end

  test "stream emits reply artifacts and terminal status, preserving the result for reconnect", %{
    p: p,
    task: task
  } do
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(task, "running")]} end)
    expect(Fountain, :turns, fn _, _ -> {:ok, [turn(task, "completed")]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: 0, has_more: false}}
    end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok,
       %{
         events: [
           %{
             "id" => 1,
             "turn_id" => "turn",
             "kind" => "output",
             "stream" => "stdout",
             "data" => "Done",
             "ts" => "2026-09-22T00:00:00Z"
           }
         ],
         next_cursor: 1,
         has_more: false
       }}
    end)

    conn = Stream.start(build_conn(), 4, p, task)
    assert conn.resp_body =~ "artifactUpdate"
    assert conn.resp_body =~ "statusUpdate"
    assert conn.resp_body =~ "TASK_STATE_COMPLETED"
    assert conn.resp_body =~ "Done"
    assert {:ok, %{result: "Done"}} = Tasks.get(p, task.id)
  end

  test "revocation while streaming closes the stream without exposing the next reply", %{
    p: p,
    task: task
  } do
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(task, "running")]} end)

    expect(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: 0, has_more: false}}
    end)

    expect(Fountain, :events_page, fn _, _, _ ->
      OAuth.disconnect(p.user, p.grant.id)
      {:ok, %{events: [], next_cursor: 1, has_more: false}}
    end)

    conn = Stream.start(build_conn(), 4, p, task)
    assert conn.resp_body =~ "error"
    refute conn.resp_body =~ "TASK_STATE_COMPLETED"
    assert {:error, :unauthenticated} = Tasks.get(p, task.id)
  end

  test "blocking send waits for correlated completion", %{p: p, task: task} do
    stub(Fountain, :turns, fn _, _ -> {:ok, [turn(task, "completed")]} end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: 1, has_more: false}}
    end)

    conn = Stream.wait(build_conn(), 7, p, task)
    assert json_response(conn, 200)["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
  end

  test "revoked credentials fail before a stream is opened or blocking output returned", %{
    p: p,
    task: task
  } do
    OAuth.disconnect(p.user, p.grant.id)
    assert json_response(Stream.start(build_conn(), 1, p, task), 200)["error"]
    assert json_response(Stream.wait(build_conn(), 1, p, task), 200)["error"]
  end

  defp turn(task, status),
    do:
      Fountain.Shapes.turn(%{"id" => "turn", "client_request_id" => task.id, "status" => status})
end
