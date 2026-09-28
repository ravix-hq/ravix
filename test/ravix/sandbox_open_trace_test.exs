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

    for {events, mode} <- [
          {{:ok, []}, "cold"},
          {{:ok, [stage("started"), stage("done")]}, "warm"},
          {{:ok, [stage("started"), stage("failed")]}, "cold"},
          {{:ok, [stage("started")]}, "unknown"},
          {{:error, :unavailable}, "unknown"}
        ] do
      assert :ok = OpenTrace.record(operation, events)
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

  defp stage(state),
    do: %{"kind" => "stage", "stage" => "checkpoint_restore", "state" => state}
end
