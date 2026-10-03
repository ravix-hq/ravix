defmodule Ravix.Search.Index do
  @moduledoc """
  Incremental, idempotent indexing of completed transcript turns already read
  by an authorized follower or Access.thread_access. No provider reads here.
  Each page contributes at most 200 completed turns, each role at most 65,536 characters.
  Older history is filled when its transcript pages are opened.
  """
  alias Ravix.Search.Store
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.{Block, Event, Turn}

  @doc "Persist selected text from a settled turn's events, already held by settlement."
  def record(conversation_id, events, runtime) do
    page = Transcript.page(events, runtime, %{})
    persist(Enum.map(page.turns, &%{&1 | conversation_id: conversation_id}))
  end

  @doc "Backfill a bounded authorized page in its caller, before the async read completes."
  def note(page), do: persist(page.turns)

  @doc false
  def persist(turns) do
    turns
    |> Enum.filter(& &1.settled?)
    |> Enum.take(200)
    |> Enum.flat_map(fn %Turn{} = turn ->
      if is_binary(turn.conversation_id) and is_binary(turn.id) and
           not String.starts_with?(turn.id, "pending"), do: entries(turn), else: []
    end)
    |> Enum.group_by(& &1.conversation_id)
    |> Enum.each(fn {conversation_id, entries} -> Store.index_turn(conversation_id, entries) end)

    :ok
  end

  defp entries(turn) do
    assistant =
      Enum.flat_map(turn.blocks, fn
        %Block.Text{body: body} -> [body]
        _ -> []
      end)
      |> Enum.join("\n\n")

    events = Enum.map(turn.events, &Event.from/1)
    cursor = events |> Enum.map(& &1.id) |> Enum.filter(&is_integer/1) |> Enum.max(fn -> 0 end)

    at =
      events
      |> Enum.find_value(fn event ->
        case is_binary(event.ts) && DateTime.from_iso8601(event.ts) do
          {:ok, at, _} -> at
          _ -> nil
        end
      end) || DateTime.utc_now()

    for {kind, text} <- [{"prompt", turn.prompt}, {"assistant", assistant}],
        is_binary(text),
        String.trim(text) != "" do
      %{
        id: Ravix.Crypto.sha256(Jason.encode!([turn.conversation_id, turn.id, kind])),
        conversation_id: turn.conversation_id,
        turn_id: turn.id,
        kind: kind,
        text: String.slice(text, 0, 65_536),
        last_event_id: cursor,
        occurred_at: %{at | microsecond: {elem(at.microsecond, 0), 6}}
      }
    end
  end
end
