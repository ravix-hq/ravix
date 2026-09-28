defmodule Ravix.Tracks.Transcript.History do
  @moduledoc """
  The earlier edge of a loaded transcript: where Load earlier reads next.

  Against a Fountain with newest-first pages (managoat/fountain#2531) this is
  a cursor. `before` is the loaded page's `meta.next_cursor`; `held` is the
  raw events at the older edge of that page which may continue on the next
  one: a turn cut at Fountain's `whole_turns` ceiling (`turn_split`), or a
  run of turn-less output cut by `limit`. Held events are rendered with the
  page they continue on, so a turn split across pages renders once, whole,
  exactly as a full build would render it. Nothing else of a page is kept.

  Against an older Fountain (no `page` object) it falls back to the forward
  read: the whole current log, partitioned once into complete-turn chunks.

  Either way, older conversations are opened newest first, only when this
  one is exhausted.
  """
  alias Ravix.Fountain
  alias Ravix.Tracks.Transcript.Event

  defstruct chunks: [],
            records: [],
            conversations: [],
            conversation_id: nil,
            source: nil,
            before: nil,
            held: []

  @type t :: %__MODULE__{}
  @turns_per_chunk 10

  # Sized from Fountain's own conversations: an agent turn is typically a few
  # hundred to two thousand events, so a thousand is one to a few complete
  # turns, `whole_turns` extends it to the last turn's start, and it is the
  # size of the forward page it replaces.
  @page_limit 1000

  @doc "The fallback: a forward-read log, partitioned into complete-turn chunks, newest first."
  @spec new([map()], list(), String.t(), list(), term()) :: t()
  def new(events, records, conversation_id, conversations, source) do
    chunks =
      events
      |> groups()
      |> Enum.reverse()
      |> Enum.chunk_every(@turns_per_chunk)
      |> Enum.map(fn groups ->
        groups |> Enum.reverse() |> Enum.flat_map(fn group -> Enum.map(group, &elem(&1, 1)) end)
      end)

    %__MODULE__{
      chunks: chunks,
      records: records,
      conversations: conversations,
      conversation_id: conversation_id,
      source: source
    }
  end

  @doc "A conversation about to be read newest first, before its first page."
  @spec cursor(list(), String.t(), list(), term()) :: t()
  def cursor(records, conversation_id, conversations, source) do
    %__MODULE__{
      records: records,
      conversations: conversations,
      conversation_id: conversation_id,
      source: source
    }
  end

  @doc """
  Read `history`'s conversation back to the next events that can be rendered.

  One `order=desc&whole_turns=true` page, and another only when the whole
  page is held (a single turn beyond Fountain's ceiling, or turn-less output
  longer than a page). Returns the raw events to render, ascending, the
  advanced history, and the pages and events read.
  """
  @spec read(Fountain.Client.t(), t()) ::
          {:ok, [map()], t(), %{pages: pos_integer(), events: non_neg_integer()}}
          | {:error, Fountain.failure()}
  def read(client, history), do: fetch(client, history, %{pages: 0, events: 0})

  @doc "Continue `read/2` past a page absorbed already, when all of it was held."
  @spec settle(Fountain.Client.t(), [map()], t(), map()) ::
          {:ok, [map()], t(), map()} | {:error, Fountain.failure()}
  def settle(client, [], %{before: before} = history, stats) when is_integer(before),
    do: fetch(client, history, stats)

  def settle(_client, events, history, stats), do: {:ok, events, history, stats}

  defp fetch(client, history, stats) do
    with {:ok, fetched} <-
           Fountain.events_page(client, history.conversation_id, page_opts(history)),
         :ok <- advanced(history, fetched) do
      {events, history} = absorb(history, fetched)
      stats = %{pages: stats.pages + 1, events: stats.events + length(fetched.events)}
      settle(client, events, history, stats)
    end
  end

  # A cursor that does not move back would read the same page forever.
  defp advanced(%{before: before}, %{has_more: true, next_cursor: next})
       when is_integer(before) and (not is_integer(next) or next >= before),
       do:
         {:error,
          %Fountain.Error{
            status: 0,
            code: "pagination_stalled",
            message: "Fountain event pagination did not advance",
            kind: :api
          }}

  defp advanced(_history, _fetched), do: :ok

  @doc "The newest-first page request after `history`'s cursor."
  @spec page_opts(t()) :: keyword()
  def page_opts(history) do
    opts = [order: :desc, whole_turns: true, prompts: true, limit: @page_limit]
    if history.before, do: [{:before, history.before} | opts], else: opts
  end

  @doc """
  Take a newest-first page in: `{render, history}`, with `render` the raw
  events to render now, ascending, and the rest held for the next page.

  The page's events are newer than nothing the history holds and older than
  everything it holds, so held events simply follow them. Only the older
  edge can be incomplete, and only while older events exist.
  """
  @spec absorb(t(), Fountain.events_page()) :: {[map()], t()}
  def absorb(history, fetched) do
    events = Enum.reverse(fetched.events) ++ history.held
    more? = fetched.has_more and is_integer(fetched.next_cursor)
    split? = match?(%{turn_split: true}, fetched.window)
    {held, render} = if more?, do: split_open_edge(events, split?), else: {[], events}
    {render, %{history | before: if(more?, do: fetched.next_cursor), held: held}}
  end

  # The complete-turn groups from the oldest up to the last one that may
  # continue on the older page. A leading turn-less run may: `limit` alone
  # cut it, and it may also be the tail of a turn below, which a suspension
  # event binds to. Below a `turn_split` cut, so may any turn whose opening
  # `turn`/`started` event is not on the page yet.
  defp split_open_edge(events, split?) do
    opened =
      if split?,
        do:
          for(
            raw <- events,
            event = Event.from(raw),
            Event.starts_turn?(event),
            into: MapSet.new(),
            do: event.turn_id
          ),
        else: nil

    groups = groups(events)

    open =
      groups
      |> Enum.with_index()
      |> Enum.filter(fn {group, index} -> open?(group, index, opened) end)
      |> Enum.map(&elem(&1, 1))

    case open do
      [] ->
        {[], events}

      indexes ->
        count = groups |> Enum.take(Enum.max(indexes) + 1) |> Enum.map(&length/1) |> Enum.sum()
        Enum.split(events, count)
    end
  end

  defp open?([{raw, _tagged, _id} | _] = group, index, opened) do
    (index == 0 and Event.from(raw).turn_id == Event.pending()) or
      (opened != nil and
         Enum.any?(group, fn {raw, _tagged, _id} ->
           turn_id = Event.from(raw).turn_id
           turn_id != Event.pending() and not MapSet.member?(opened, turn_id)
         end))
  end

  @doc """
  The events to render, with each run of turn-less output under an identity
  of its own. Runs of unbound output must not connect setup to a late
  unbound event, and keeping them distinct in the rendered transcript as
  well as the partition stops a prepend discarding one as a duplicate.
  """
  @spec label([map()]) :: [map() | Event.t()]
  def label(events) do
    {tagged, _} = Enum.map_reduce(events, {Event.pending(), nil}, &tag_event/2)
    Enum.map(tagged, fn {_raw, tagged, _id} -> tagged end)
  end

  # Interleaved turns must travel together: a cut is safe only after every
  # turn opened to its left has supplied its last event. Ascending groups of
  # `{raw, labelled, partition}`.
  defp groups(events) do
    {tagged, _} = Enum.map_reduce(events, {Event.pending(), nil}, &tag_event/2)
    indexed = Enum.with_index(tagged)
    ends = Map.new(indexed, fn {{_raw, _tagged, id}, index} -> {id, index} end)

    {groups, [], _} =
      Enum.reduce(indexed, {[], [], 0}, fn {{_, _, id} = entry, index}, {groups, group, bound} ->
        bound = max(bound, Map.fetch!(ends, id))
        group = [entry | group]

        if index == bound,
          do: {[Enum.reverse(group) | groups], [], bound},
          else: {groups, group, bound}
      end)

    Enum.reverse(groups)
  end

  # Suspension still travels with the preceding real turn for classification.
  defp tag_event(raw, {current, run}) do
    event = Event.from(raw)

    cond do
      event.turn_id != Event.pending() ->
        {{raw, raw, event.turn_id}, {event.turn_id, nil}}

      Event.suspension(event) ->
        {{raw, raw, current}, {current, nil}}

      true ->
        run = run || "pending:#{event.id}"
        {{raw, %{event | turn_id: run}, run}, {current, run}}
    end
  end

  @doc """
  What crosses the async task boundary for the next read: the cursor as it
  is, or only the next retained chunk and its image records in the fallback.
  """
  @spec request(t()) :: t()
  def request(%{chunks: [], before: nil} = history), do: %{history | records: []}
  def request(%{chunks: []} = history), do: history

  def request(%{chunks: [chunk | _]} = history) do
    ids = MapSet.new(chunk, &Event.from(&1).turn_id)
    records = Enum.filter(history.records, &MapSet.member?(ids, &1.id))
    %{history | chunks: [chunk], records: records}
  end

  @doc "Retain unread fallback chunks locally; otherwise the read's history replaces this one."
  @spec advance(t(), t()) :: t()
  def advance(%{chunks: [_ | rest]} = held, _returned), do: %{held | chunks: rest}
  def advance(%{chunks: [], before: nil, conversations: []} = held, _returned), do: held
  def advance(_held, returned), do: returned

  @spec more?(t() | nil) :: boolean()
  def more?(nil), do: false

  def more?(history),
    do: history.chunks != [] or history.before != nil or history.conversations != []

  @doc "Has `held` read further back than `incoming`, which starts the same thread over?"
  @spec further?(t(), t()) :: boolean()
  def further?(held, incoming), do: rank(held) < rank(incoming)

  defp rank(%{chunks: [], before: before} = history) when is_integer(before),
    do: {length(history.conversations), before}

  defp rank(history), do: {length(history.conversations), length(history.chunks)}

  @spec take(t()) :: {list(), t()}
  def take(%{chunks: []} = history), do: {[], history}
  def take(%{chunks: [chunk | rest]} = history), do: {chunk, %{history | chunks: rest}}
end
