defmodule Ravix.Tracks.Transcript do
  @moduledoc """
  The scrollback, as the page draws it.

  Two sources, joined on `turn_id`, and the join is the whole of this
  module's structure. Fountain keeps *turns* (what somebody asked for)
  separately from the *event log* (the bytes the machine produced answering).
  A transcript built from the events alone renders an agent talking to
  itself; one built from the turns alone renders questions with no answers.

  The browser used to do this parse itself, on every frame, with
  `blocksForTurn` from `packages/fountain-app/src/acp.ts`. Here the server
  does it once, over `Managoat.ACP.Blocks`, and the page renders what it is
  handed. The block shapes are the ones `src/components/Transcript.tsx`
  drew, so the port of that component reads the same fields:

    * `%{kind: :text, body, started_at, ended_at}`: the reply, markdown.
      Adjacent chunks are one block.
    * `%{kind: :thinking, body, started_at, ended_at}`: reasoning, folded
      away once the turn is over.
    * `%{kind: :tool, id, name, summary, status, output, started_at,
      ended_at, detail}`: one call and its result, paired on the ACP
      `toolCallId`. `status` is `:running` until a terminal update lands,
      then `:done` or `:error`. `detail` is what `src/lib/tools.ts` read a
      second time: the call's ACP `kind`, its arguments, the paths it named,
      and for an edit the before-and-after as diff lines.
    * `%{kind: :raw, body}`: a line the adapter emitted that is not ACP.

  Timestamps are the log's own ISO-8601 strings: when the chunk landed, not
  when the model produced it (one flush apart at most).

  A turn is `settled?` once Fountain has closed it (`stage: "turn"` in any
  state other than `started`); a group with no turn stage at all is the live
  one. Turns Ravix sent itself carry the `[ravix]` marker on their prompt,
  and `app_turn_label/1` is the one place that reads it.
  """

  alias Managoat.ACP.Blocks
  alias Managoat.ACP.Protocol

  @acp_runtimes ~w(claude codex opencode)
  @tool_kinds ~w(read edit delete move search execute fetch think other)
  @pending "pending"

  @typedoc "A stored log event, string keys, as `GET /api/conversations/:id/events` serves it."
  @type event :: %{optional(String.t()) => term()}

  @typedoc "One turn, as Fountain records it, plus its events and their blocks."
  @type turn :: %{
          id: String.t(),
          prompt: String.t() | nil,
          origin: String.t() | nil,
          status: String.t() | nil,
          inserted_at: String.t() | nil,
          events: [event()],
          blocks: [block()],
          settled?: boolean(),
          visible?: boolean()
        }

  @type block :: map()

  @typedoc "The transcript so far: turns in order, and the newest event id seen."
  @type page :: %{turns: [turn()], last_event_id: integer() | nil, runtime: String.t()}

  # ── the page ──────────────────────────────────────────────────────────

  @doc """
  Turns and events into one ordered page.

  Turn order comes from the turns list, because that is the order they were
  asked in and it survives an event log that arrives out of order or with a
  gap in it. Events whose `turn_id` matches no turn (which happens for the
  first few frames of a turn Fountain has not finished recording) are kept
  in a trailing group rather than dropped, so the very first thing a new
  track shows is not an empty panel.
  """
  @spec page([map()], [event()], String.t()) :: page()
  def page(raw_turns, events, runtime) do
    %{turns: [], last_event_id: nil, runtime: runtime || ""}
    |> add_turns(raw_turns)
    |> add_events(events)
  end

  @doc "An empty page for a track with no conversation yet."
  @spec empty(String.t()) :: page()
  def empty(runtime), do: page([], [], runtime)

  @doc """
  Merge a fresh turns list in. A turn already on the page keeps its events;
  a new one is placed by `inserted_at` among the recorded turns, ahead of the
  groups that only exist because events named them.
  """
  @spec add_turns(page(), [map()]) :: page()
  def add_turns(page, raw_turns) do
    records = Enum.map(raw_turns, &turn_record/1)
    by_id = Map.new(page.turns, &{&1.id, &1})

    merged =
      Enum.map(records, fn record ->
        case Map.fetch(by_id, record.id) do
          {:ok, existing} -> Map.merge(existing, record)
          :error -> new_turn(record, page.runtime)
        end
      end)

    known = MapSet.new(records, & &1.id)
    orphans = Enum.reject(page.turns, &MapSet.member?(known, &1.id))
    sorted = Enum.sort_by(merged, &ordered_at/1)

    %{page | turns: Enum.map(sorted ++ orphans, &rebuild(&1, page.runtime))}
  end

  # A turn Fountain sent without a usable timestamp belongs at the end, where a
  # just-created turn actually is. Treating a missing one as the empty string
  # made it the earliest thing in the transcript, so the newest turn rendered
  # above the entire history.
  defp ordered_at(%{inserted_at: at}) when is_binary(at), do: {0, at}
  defp ordered_at(_undated), do: {1, ""}

  @doc "Every event in `events`, laid into its turn. Duplicates (by id) are ignored."
  @spec add_events(page(), [event()]) :: page()
  def add_events(page, events), do: Enum.reduce(events, page, &add_event(&2, &1))

  @doc """
  One live event, laid into its turn, which is re-parsed. A page that has
  seen this event id already is unchanged, because a snapshot and the
  stream it was taken from overlap.
  """
  @spec add_event(page(), event()) :: page()
  def add_event(page, %{"id" => id} = event) when is_integer(id) do
    turn_id = turn_id_of(event)

    {turns, found?} =
      Enum.map_reduce(page.turns, false, fn turn, found? ->
        if turn.id == turn_id, do: {lay_in(turn, event, page.runtime), true}, else: {turn, found?}
      end)

    turns =
      if found?,
        do: turns,
        else: turns ++ [lay_in(new_turn(%{id: turn_id}, page.runtime), event, page.runtime)]

    %{page | turns: turns, last_event_id: max(page.last_event_id || 0, id)}
  end

  def add_event(page, _event), do: page

  @doc "The turns worth drawing: a prompt somebody typed, or output somebody can read."
  @spec visible_turns(page()) :: [turn()]
  def visible_turns(page), do: Enum.filter(page.turns, & &1.visible?)

  @doc "Is a turn in this page still being written? The last group, and only if unsettled."
  @spec live?(page(), boolean()) :: boolean()
  def live?(page, running?) do
    case List.last(visible_turns(page)) do
      nil -> false
      turn -> running? and not turn.settled?
    end
  end

  # ── one turn ──────────────────────────────────────────────────────────

  @doc "A Fountain turn as the `TurnRecord` of `shared/api.ts`."
  @spec turn_record(map()) :: %{
          id: String.t(),
          prompt: String.t() | nil,
          origin: String.t() | nil,
          status: String.t() | nil,
          inserted_at: String.t() | nil
        }
  def turn_record(raw) do
    %{
      id: to_string(raw["id"] || raw[:id]),
      prompt: string_or_nil(raw["prompt"] || raw[:prompt]),
      origin: string_or_nil(raw["origin"] || raw[:origin]),
      status: string_or_nil(raw["status"] || raw[:status]),
      inserted_at: string_or_nil(raw["inserted_at"] || raw[:inserted_at])
    }
  end

  defp new_turn(record, runtime) do
    %{id: nil, prompt: nil, origin: nil, status: nil, inserted_at: nil, events: [], blocks: []}
    |> Map.merge(record)
    |> rebuild(runtime)
  end

  defp lay_in(turn, event, runtime) do
    cond do
      Enum.any?(turn.events, &(&1["id"] == event["id"])) ->
        turn

      # The streaming case, and the only one that repeats: the event belongs
      # after everything the turn already holds, so its blocks are the blocks
      # already computed plus this one folded on. Re-reducing the whole turn
      # per event costs a JSON decode of every line of every earlier event,
      # which is quadratic in the length of the turn and runs inside each
      # reader's LiveView process.
      appended?(turn.events, event) ->
        finish(%{turn | events: turn.events ++ [event]}, fold(event, runtime, acc(turn)))

      # Out of order: the order the blocks are in changes, so it is rebuilt.
      true ->
        rebuild(%{turn | events: Enum.sort_by([event | turn.events], & &1["id"])}, runtime)
    end
  end

  defp appended?([], _event), do: true
  defp appended?(events, event), do: List.last(events)["id"] < event["id"]

  # Everything derived, from the events themselves.
  defp rebuild(turn, runtime),
    do: finish(turn, Enum.reduce(turn.events, empty_acc(), &fold(&1, runtime, &2)))

  # The derived fields, from a reduction over the turn's events.
  defp finish(turn, acc) do
    blocks = blocks_of(acc)
    visible = Enum.filter(blocks, &visible_block?/1)

    turn
    |> Map.put(:blocks, visible)
    |> Map.put(:acc, acc)
    |> Map.put(:settled?, turn[:settled?] == true or settled?(turn.events))
    |> Map.put(:visible?, has_text?(turn.prompt) or visible != [])
  end

  defp acc(%{acc: acc}), do: acc
  defp acc(_turn), do: empty_acc()

  defp empty_acc, do: {[], %{}}
  defp fold(event, runtime, acc), do: output(event, runtime, acc)
  defp blocks_of({blocks, _tools}), do: Enum.reverse(blocks)

  defp turn_id_of(event) do
    case event["turn_id"] do
      id when is_binary(id) and id != "" -> id
      _ -> @pending
    end
  end

  @doc """
  Has Fountain closed this turn? `stage: "turn"` in any state other than
  `started` is the end of one. A group with no turn stage at all is not
  settled, which is the answer that makes the newest events on screen the
  live ones.
  """
  @spec settled?([event()]) :: boolean()
  def settled?(events) do
    Enum.any?(events, fn e ->
      e["kind"] == "stage" and e["stage"] == "turn" and e["state"] != "started"
    end)
  end

  @doc """
  A turn Ravix sent itself, as one line, or nil for a person's prompt.

  Matched on the marker the prompt contract puts at the front of every one
  of them (`Ravix.Spec`), so there is exactly one place that decides what an
  app turn looks like and it is the same place that writes them.
  """
  @spec app_turn_label(String.t() | nil) :: String.t() | nil
  def app_turn_label("[ravix]" <> rest) do
    case rest |> String.split("\n") |> hd() |> String.trim() do
      "" -> "Ravix sent this machine an instruction."
      first -> first
    end
  end

  def app_turn_label(_prompt), do: nil

  # ── blocks ────────────────────────────────────────────────────────────

  @doc """
  Blocks for one turn's events: adjacent text merged, tools paired.

  ACP lines go through `Managoat.ACP.Blocks`, whose block vocabulary is the
  wire contract; what is added here is the pairing of a `tool_result` onto
  its `tool_use`, the timestamps, and the detail the chips need. Legacy
  dialects (a runtime that never spoke ACP on this page) are shown as plain
  text lines rather than parsed four ways.
  """
  @spec blocks_for_turn([event()], String.t()) :: [block()]
  def blocks_for_turn(events, runtime) do
    events |> Enum.reduce(empty_acc(), &output(&1, runtime, &2)) |> blocks_of()
  end

  defp output(%{"kind" => "output", "stream" => "acp", "data" => data} = event, _runtime, acc)
       when is_binary(data) do
    data
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce(acc, &acp_line(&1, event["ts"], &2))
  end

  # Legacy dialects: the text as-is rather than four vendor formats parsed
  # here. Claude, codex and opencode only ever spoke ACP on this page.
  defp output(%{"kind" => "output", "stream" => "stdout", "data" => data} = event, runtime, acc)
       when is_binary(data) do
    if acp_runtime?(runtime), do: acc, else: push_text(acc, :text, data, event["ts"])
  end

  defp output(_event, _runtime, acc), do: acc

  @doc "A block worth drawing: any tool, or text that is not blank."
  @spec visible_block?(block()) :: boolean()
  def visible_block?(%{kind: :tool}), do: true
  def visible_block?(%{body: body}) when is_binary(body), do: String.trim(body) != ""
  def visible_block?(_), do: false

  defp acp_runtime?(runtime) when is_binary(runtime),
    do: Enum.any?(@acp_runtimes, &String.starts_with?(runtime, &1))

  defp acp_runtime?(_), do: false

  defp acp_line(line, ts, acc) do
    case Protocol.classify_line(line) do
      {:notification, "session/update", params} ->
        update = if is_map(params["update"]), do: params["update"], else: params
        Enum.reduce(Blocks.from_update(update), acc, &apply_block(&1, update, ts, &2))

      {:invalid, raw} ->
        push(acc, %{kind: :raw, body: raw})

      _ ->
        acc
    end
  end

  defp apply_block(%{kind: :text, body: body}, _update, ts, acc),
    do: push_text(acc, :text, body, ts)

  defp apply_block(%{kind: :thinking, body: body}, _update, ts, acc),
    do: push_text(acc, :thinking, body, ts)

  defp apply_block(%{kind: :tool_use} = block, update, ts, {blocks, tools}) do
    tool = %{
      kind: :tool,
      id: block.id,
      name: block.name,
      summary: block.summary,
      status: :running,
      output: "",
      started_at: ts,
      ended_at: nil,
      detail: detail(empty_detail(), update)
    }

    tools = if is_binary(block.id), do: Map.put(tools, block.id, length(blocks)), else: tools
    {[tool | blocks], tools}
  end

  defp apply_block(%{kind: :tool_result, tool_id: id} = block, update, ts, {blocks, tools} = acc) do
    case Map.fetch(tools, id) do
      {:ok, index} ->
        position = length(blocks) - 1 - index

        blocks =
          List.update_at(blocks, position, fn tool ->
            %{
              tool
              | status: if(block.error?, do: :error, else: :done),
                output: block.body,
                ended_at: ts,
                detail: detail(tool.detail, update)
            }
          end)

        {blocks, tools}

      :error ->
        acc
    end
  end

  # Permission requests and anything the ACP library adds later have no
  # rendering in the transcript yet; they are dropped rather than drawn as
  # noise, as the browser dropped them.
  defp apply_block(_block, _update, _ts, acc), do: acc

  # Adjacent chunks of the same kind are one block. The timestamps are the
  # first and last chunk that landed in it.
  defp push_text({[%{kind: kind} = last | rest], tools}, kind, body, ts) do
    {[%{last | body: last.body <> body, ended_at: ts || last.ended_at} | rest], tools}
  end

  defp push_text(acc, kind, body, ts),
    do: push(acc, %{kind: kind, body: body, started_at: ts, ended_at: ts})

  defp push({blocks, tools}, block), do: {[block | blocks], tools}

  # ── tool detail (src/lib/tools.ts) ────────────────────────────────────

  @doc """
  What a tool call *was*, rather than that there was one.

  Both frames are read. `tool_call` carries the kind and the arguments;
  `tool_call_update` carries the result, and an adapter is free to put the
  diff on either, so the two are merged rather than one being trusted.
  """
  @spec detail(map(), map()) :: %{kind: atom(), input: map(), paths: [String.t()], edits: [map()]}
  def detail(current, update) do
    kind =
      case update["kind"] do
        k when k in @tool_kinds ->
          Map.fetch!(
            %{
              "read" => :read,
              "edit" => :edit,
              "delete" => :delete,
              "move" => :move,
              "search" => :search,
              "execute" => :execute,
              "fetch" => :fetch,
              "think" => :think,
              "other" => :other
            },
            k
          )

        _ ->
          current.kind
      end

    input =
      if is_map(update["rawInput"]),
        do: Map.merge(current.input, update["rawInput"]),
        else: current.input

    paths = Enum.uniq(current.paths ++ locations(update["locations"]))
    edits = current.edits ++ edits(update["content"])
    %{kind: kind, input: input, paths: paths, edits: edits}
  end

  defp empty_detail, do: %{kind: :other, input: %{}, paths: [], edits: []}

  defp locations(raw) when is_list(raw) do
    for %{"path" => path} <- raw, is_binary(path) and path != "", do: path
  end

  defp locations(_), do: []

  defp edits(content) when is_list(content) do
    for %{"type" => "diff"} = item <- content do
      edit(item["path"] || "", item["oldText"] || "", item["newText"] || "")
    end
  end

  defp edits(_), do: []

  @doc """
  An edit, as near a real diff as the adapter's before-and-after allows.

  ACP's `diff` content is two whole strings, so the shared lines at the top
  and bottom are found by walking in from both ends. That is not a diff
  algorithm and does not pretend to be one: an edit whose middle moved
  renders as one replaced run rather than as the minimal edit script. It is
  exact about what changed and only imprecise about how tightly it is
  framed, which is the right way round for something read at a glance.
  """
  @spec edit(String.t(), String.t(), String.t()) :: %{
          path: String.t(),
          lines: [%{kind: :add | :del | :ctx, text: String.t()}],
          added: non_neg_integer(),
          removed: non_neg_integer()
        }
  def edit(path, before, after_text) do
    old = if before == "", do: [], else: String.split(before, "\n")
    now = if after_text == "", do: [], else: String.split(after_text, "\n")
    head = common_prefix(old, now)
    tail = common_suffix(Enum.drop(old, head), Enum.drop(now, head))

    removed = Enum.slice(old, head, length(old) - head - tail)
    added = Enum.slice(now, head, length(now) - head - tail)

    # One line of shared context either side. More is noise on a chip; none
    # makes a one-line change impossible to place.
    lines =
      if(head > 0, do: [%{kind: :ctx, text: Enum.at(old, head - 1)}], else: []) ++
        Enum.map(removed, &%{kind: :del, text: &1}) ++
        Enum.map(added, &%{kind: :add, text: &1}) ++
        if(tail > 0, do: [%{kind: :ctx, text: Enum.at(old, length(old) - tail)}], else: [])

    %{path: path, lines: lines, added: length(added), removed: length(removed)}
  end

  defp common_prefix(a, b) do
    a |> Enum.zip(b) |> Enum.take_while(fn {x, y} -> x == y end) |> length()
  end

  defp common_suffix(a, b), do: common_prefix(Enum.reverse(a), Enum.reverse(b))

  defp has_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp has_text?(_), do: false

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil
end
