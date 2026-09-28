defmodule Ravix.Tracks.Sandbox.OpenTrace do
  @moduledoc "Completion measurements for durable dedicated opens, including time between sweeps."
  alias Ravix.Trace
  alias Ravix.Tracks.Transcript.Event

  # Emit only after the leased ready transition succeeds. A process-local timer
  # would lose provisioning time across retries, restarts and node takeovers.
  def record(operation, events) do
    Trace.span(
      "tracks.sandbox.open",
      %{
        "ravix.track_id" => operation.track_id,
        "ravix.sandbox_generation" => operation.generation,
        "ravix.open_action" => operation.action,
        "ravix.open_to_ready_ms" =>
          max(0, DateTime.diff(operation.completed_at, operation.inserted_at, :millisecond)),
        "ravix.start_mode" => start_mode(events)
      },
      fn -> :ok end
    )
  end

  defp start_mode({:ok, events}) do
    events
    |> Enum.map(&Event.from/1)
    |> Enum.filter(&match?(%Event{kind: :stage, stage: "checkpoint_restore"}, &1))
    |> List.last()
    |> case do
      %Event{state: "done"} -> "warm"
      %Event{state: "started"} -> "unknown"
      _ -> "cold"
    end
  end

  # An unavailable history is not evidence of a cold start.
  defp start_mode({:error, _}), do: "unknown"
end
