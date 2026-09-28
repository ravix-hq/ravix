defmodule Ravix.Tracks.Transcript.History do
  @moduledoc """
  Complete-turn chunks awaiting rendering, newest chunk first.

  Fountain currently only pages forwards (managoat/fountain#2531). Keep the
  unread log in this page, partitioned once, rather than fetching or parsing
  it again on each prepend. Archived conversations are fetched only on demand.
  This bounds rendering, not the initial provider read or retained raw bytes.
  """
  alias Ravix.Tracks.Transcript.Event

  defstruct chunks: [], records: [], conversations: [], conversation_id: nil, source: nil

  @type t :: %__MODULE__{}
  @turns_per_chunk 10

  @spec new([map()], list(), String.t(), list(), term()) :: t()
  def new(events, records, conversation_id, conversations, source) do
    # A lifecycle event without a turn belongs beside the preceding turn;
    # splitting it off would lose suspension/failure classification context.
    {tagged, _} =
      Enum.map_reduce(events, Event.pending(), fn raw, current ->
        event = Event.from(raw)

        id =
          if event.turn_id == Event.pending() and Event.suspension(event),
            do: current,
            else: event.turn_id

        next = if id == Event.pending(), do: current, else: id
        {{raw, id}, next}
      end)

    indexed = Enum.with_index(tagged)
    ends = Map.new(indexed, fn {{_raw, id}, index} -> {id, index} end)

    # Interleaved turns must travel together: a cut is safe only after every
    # turn opened to its left has supplied its last event.
    {groups, [], _} =
      Enum.reduce(indexed, {[], [], 0}, fn {{raw, id}, index}, {groups, group, bound} ->
        bound = max(bound, Map.fetch!(ends, id))
        group = [raw | group]
        if index == bound, do: {[group | groups], [], bound}, else: {groups, group, bound}
      end)

    chunks =
      groups
      |> Enum.chunk_every(@turns_per_chunk)
      |> Enum.map(fn groups -> groups |> Enum.reverse() |> Enum.flat_map(&Enum.reverse/1) end)

    %__MODULE__{
      chunks: chunks,
      records: records,
      conversations: conversations,
      conversation_id: conversation_id,
      source: source
    }
  end

  @spec more?(t() | nil) :: boolean()
  def more?(nil), do: false
  def more?(history), do: history.chunks != [] or history.conversations != []

  @spec take(t()) :: {list(), t()}
  def take(%{chunks: []} = history), do: {[], history}
  def take(%{chunks: [chunk | rest]} = history), do: {chunk, %{history | chunks: rest}}
end
