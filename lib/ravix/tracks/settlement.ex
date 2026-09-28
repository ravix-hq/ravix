defmodule Ravix.Tracks.Settlement do
  @moduledoc "Durable failure classification at the follower's turn-settlement boundary."
  alias Ravix.{Fountain, Trace}
  alias Ravix.Tracks.{AgentFailure, Store, Transcript}
  alias Ravix.Tracks.Transcript.Event

  def record(client, thread_id, conversation_id, %Event{turn_id: "pending"} = event) do
    if Event.suspension(event),
      do: record_bound(client, thread_id, conversation_id, event),
      else: :ok
  end

  def record(client, thread_id, conversation_id, event),
    do: record_bound(client, thread_id, conversation_id, event)

  defp record_bound(client, thread_id, conversation_id, event) do
    # ownership: Follower subscribers established Access.thread_access for this thread.
    case Store.get_thread(thread_id) do
      %{conversation_id: ^conversation_id} = thread ->
        # ownership: record/4 verified the follower's current thread binding.
        classify(client, conversation_id, event, Store.transcript_runtime(thread))

      _ ->
        :ok
    end
  end

  @doc "Operator-only, idempotent historical backfill; never called by a transcript read."
  def backfill(thread_id, client \\ Fountain.client()) do
    # ownership: this is the explicit maintenance command's thread ID, not a web door.
    case Store.get_thread(thread_id) do
      nil ->
        {:error, :not_found}

      thread ->
        # ownership: the operator selected this thread for historical classification.
        runtime = Store.transcript_runtime(thread)
        ids = Enum.reject(thread.previous_conversation_ids ++ [thread.conversation_id], &is_nil/1)

        Enum.reduce_while(ids, :ok, fn id, :ok ->
          continue_backfill(backfill_conversation(client, id, runtime))
        end)
    end
  end

  defp backfill_conversation(client, id, runtime) do
    with {:ok, log} <- Fountain.events(client, id, []) do
      page = Transcript.page(log, runtime, %{})

      Enum.reduce_while(page.turns, :ok, fn turn, :ok ->
        continue_backfill(backfill_turn(id, turn, runtime))
      end)
    end
  end

  defp backfill_turn(id, %{settled?: true} = turn, runtime),
    do: persist(id, turn.id, Enum.reverse(turn.events), runtime)

  defp backfill_turn(_id, _turn, _runtime), do: :ok

  defp continue_backfill({:error, _} = error), do: {:halt, error}
  defp continue_backfill(_result), do: {:cont, :ok}

  # A sandbox-wide suspension belongs only to the immediately preceding open
  # turn, exactly as in the transcript. A sleep between turns records nothing.
  defp classify(client, conversation_id, %Event{turn_id: "pending"} = event, runtime) do
    with {:ok, log} <- Fountain.events(client, conversation_id, []) do
      page = Transcript.page(Enum.uniq_by(log ++ [event], &Event.from(&1).id), runtime, %{})

      case Enum.find(page.turns, fn turn -> Enum.any?(turn.events, &(&1.id == event.id)) end) do
        nil -> :ok
        turn -> persist(conversation_id, turn.id, Enum.reverse(turn.events), runtime)
      end
    end
  end

  defp classify(client, conversation_id, event, runtime) do
    # ownership: no door; record/4 verified the authorized follower's current binding.
    if Store.turn_classified?(conversation_id, event.turn_id) do
      {:ok, :already_classified}
    else
      # Fetch outside the DB transaction. The lock in persist/4 serializes only
      # classification and its writes, never provider latency.
      with {:ok, log} <- Fountain.events(client, conversation_id, []) do
        events = Enum.filter(log, &(Event.from(&1).turn_id == event.turn_id))
        events = Enum.uniq_by(events ++ [event], &Event.from(&1).id)
        persist(conversation_id, event.turn_id, events, runtime)
      end
    end
  end

  defp persist(conversation_id, turn_id, events, runtime) do
    # ownership: the current follower binding or explicit maintenance command selected this turn.
    Store.classify_turn_once(conversation_id, turn_id, fn -> detect(events, runtime) end)
  end

  defp detect(events, runtime) do
    Trace.span("transcript.failure_detection", %{"ravix.event_count" => length(events)}, fn ->
      blocks = Transcript.blocks_for_turn(events, runtime)
      {:ok, AgentFailure.detect(events, runtime, blocks)}
    end)
  end
end
