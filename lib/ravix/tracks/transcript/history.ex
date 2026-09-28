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
    # Runs of unbound output must not connect setup to a late unbound event.
    # Suspension still travels with the preceding real turn for classification.
    {tagged, _} = Enum.map_reduce(events, {Event.pending(), nil}, &tag_event/2)

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

  defp tag_event(raw, {current, run}) do
    event = Event.from(raw)

    cond do
      event.turn_id != Event.pending() ->
        {{raw, event.turn_id}, {event.turn_id, nil}}

      Event.suspension(event) ->
        {{raw, current}, {current, nil}}

      true ->
        run = run || "pending:#{event.id}"
        # Keep separate runs distinct in the rendered transcript as well as
        # the partition, or prepend would discard one as a duplicate.
        {{%{event | turn_id: run}, run}, {current, run}}
    end
  end

  @doc "Only the next retained chunk crosses the async task boundary."
  @spec request(t()) :: t()
  def request(%{chunks: []} = history), do: %{history | records: []}

  def request(%{chunks: [chunk | _]} = history) do
    ids = MapSet.new(chunk, &Event.from(&1).turn_id)
    records = Enum.filter(history.records, &MapSet.member?(ids, &1.id))
    %{history | chunks: [chunk], records: records}
  end

  @doc "Retain unread chunks locally; a newly fetched archive supplies its own remainder."
  @spec advance(t(), t()) :: t()
  def advance(%{chunks: [_ | rest]} = held, _returned), do: %{held | chunks: rest}
  def advance(%{chunks: [], conversations: []} = held, _returned), do: held
  def advance(%{chunks: []}, returned), do: returned

  @spec more?(t() | nil) :: boolean()
  def more?(nil), do: false
  def more?(history), do: history.chunks != [] or history.conversations != []

  @spec take(t()) :: {list(), t()}
  def take(%{chunks: []} = history), do: {[], history}
  def take(%{chunks: [chunk | rest]} = history), do: {chunk, %{history | chunks: rest}}
end
