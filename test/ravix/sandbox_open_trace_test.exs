defmodule Ravix.SandboxOpenTraceTest do
  use Ravix.DataCase, async: false
  use Ravix.TraceCase, async: false

  alias Ravix.Tracks.Sandbox.{OpenTrace, Operation}

  test "completion span measures the durable request through readiness" do
    operation = %Operation{
      track_id: "track",
      generation: 2,
      action: :rebuild,
      inserted_at: ~U[2026-09-28 10:00:00.000000Z],
      completed_at: ~U[2026-09-28 10:01:12.345000Z]
    }

    for {events, more?, mode} <- [
          {[], false, "cold"},
          {[stage("started"), stage("done")], false, "warm"},
          {[stage("started"), stage("done")], true, "warm"},
          {[stage("started"), stage("failed")], true, "cold"},
          {[stage("started")], true, "unknown"},
          {[], true, "unknown"}
        ] do
      assert :ok = OpenTrace.record(operation, {:ok, %{events: events, has_more: more?}})
      assert_receive {:span, recorded = span(name: "tracks.sandbox.open")}
      assert attributes(recorded)["ravix.start_mode"] == mode
      assert attributes(recorded)["ravix.open_to_ready_ms"] == 72_345
      assert attributes(recorded)["ravix.track_id"] == "track"
      assert attributes(recorded)["ravix.sandbox_generation"] == 2
      assert attributes(recorded)["ravix.open_action"] == :rebuild
    end
  end

  test "a ready transition emits once, including when stage history is unavailable" do
    alias Ravix.Fountain.FakeTransport
    alias Ravix.Tracks.Sandbox
    alias Ravix.Tracks.Sandbox.Store

    track =
      insert_track(
        sandbox_layout: :dedicated,
        setup_state: "ready",
        conversation_id: "opening-conversation"
      )

    {:ok, operation} = Store.begin_operation(track.id, 0, :open)
    {:ok, operation} = Store.update_operation(operation, %{phase: "setup"})

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations/#{track.conversation_id}/events"},
         {503, [], %{error: "unavailable"}}}
      ])

    Sandbox.advance(client, operation.id)
    assert_receive {:span, recorded = span(name: "tracks.sandbox.open")}
    completed = Store.get_operation(operation.id)
    assert completed.phase == "done"
    assert Store.get_track(track.id).sandbox_state == :ready
    assert attributes(recorded)["ravix.start_mode"] == "unknown"

    assert attributes(recorded)["ravix.open_to_ready_ms"] ==
             DateTime.diff(completed.completed_at, completed.inserted_at, :millisecond)

    Sandbox.advance(client, operation.id)
    refute_received {:span, span(name: "tracks.sandbox.open")}
  end

  test "ready is broadcast while the provisioning history read is blocked" do
    alias Ravix.Fountain.FakeTransport
    alias Ravix.Tracks.Sandbox
    alias Ravix.Tracks.Sandbox.Store

    track =
      insert_track(
        sandbox_layout: :dedicated,
        setup_state: "ready",
        conversation_id: "blocked-history"
      )

    {:ok, operation} = Store.begin_operation(track.id, 0, :open)
    {:ok, operation} = Store.update_operation(operation, %{phase: "setup"})
    Ravix.Hub.subscribe(track.project_id)
    parent = self()

    client =
      FakeTransport.client([
        {%{
           method: "GET",
           path: "/api/conversations/blocked-history/events",
           query: %{"limit" => "100"}
         },
         fn _ ->
           send(parent, {:history_read, self()})

           receive do
             :release_history ->
               {200, [], %{data: [], meta: %{has_more: true, next_cursor: 100}}}
           end
         end}
      ])

    task = Task.async(fn -> Sandbox.advance(client, operation.id) end)

    try do
      assert_receive {:history_read, reader}
      id = track.id
      assert_receive {:hub, %Ravix.Hub.Event{name: :tracks, track_id: ^id}}
      assert Store.get_track(id).sandbox_state == :ready
      assert Store.get_operation(operation.id).phase == "done"
      refute_received {:span, span(name: "tracks.sandbox.open")}
      send(reader, :release_history)
      assert {:ok, %Operation{phase: "done"}} = Task.await(task)
      assert_receive {:span, recorded = span(name: "tracks.sandbox.open")}
      assert attributes(recorded)["ravix.start_mode"] == "unknown"
      refute_received {:hub, %Ravix.Hub.Event{name: :tracks, track_id: ^id}}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp stage(state),
    do: %{"kind" => "stage", "stage" => "checkpoint_restore", "state" => state}
end
