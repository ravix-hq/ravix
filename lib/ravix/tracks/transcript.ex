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
  handed.

  Every shape this module builds is a struct: `Ravix.Tracks.Transcript.Page`
  holds `Ravix.Tracks.Transcript.Turn`s, each of which holds
  `Ravix.Tracks.Transcript.Block`s -- five of those, one per drawn thing,
  matched by struct rather than by a `:kind` field. They were anonymous maps
  translated from `src/components/Transcript.tsx`, which is why a turn
  carried an `:acc` key named in no type and `block` was declared as
  `map()`. See `Ravix.Tracks.Transcript.Block` for what that cost.

  Timestamps are the log's own ISO-8601 strings: when the chunk landed, not
  when the model produced it (one flush apart at most).

  A turn is `settled?` once Fountain has closed it (`stage: "turn"` in any
  state other than `started`); a group with no turn stage at all is the live
  one. Turns Ravix sent itself carry the `[ravix]` marker on their prompt,
  and `app_turn_label/1` is the one place that reads it.
  """

  alias Managoat.ACP.Blocks
  alias Managoat.ACP.Protocol
  alias Ravix.Fountain.Shapes.Turn, as: Wire
  alias Ravix.Tracks.Transcript.{Block, Detail, Edit, Event, Page, Turn}

  @acp_runtimes ~w(claude codex opencode)
  @tool_kinds ~w(read edit delete move search execute fetch think other)

  @typedoc "A parsed log event. See `Ravix.Tracks.Transcript.Event`."
  @type event :: Event.t()

  @typedoc "One turn and its output. See `Ravix.Tracks.Transcript.Turn`."
  @type turn :: Turn.t()

  @typedoc "One drawn thing. See `Ravix.Tracks.Transcript.Block`."
  @type block :: Block.t()

  @typedoc "The transcript so far. See `Ravix.Tracks.Transcript.Page`."
  @type page :: Page.t()

  # ── the page ──────────────────────────────────────────────────────────

  @doc """
  Turns and events into one ordered page.

  Events may arrive as `Ravix.Tracks.Transcript.Event` structs or as the raw
  maps Fountain sends; `Event.from/1` is idempotent, so the public entry
  points normalise and everything inside works on structs.

  Turn order comes from the turns list, because that is the order they were
  asked in and it survives an event log that arrives out of order or with a
  gap in it. Events whose `turn_id` matches no turn (which happens for the
  first few frames of a turn Fountain has not finished recording) are kept
  in a trailing group rather than dropped, so the very first thing a new
  track shows is not an empty panel.
  """
  @spec page([Wire.t()], [Event.t() | map()], String.t()) :: Page.t()
  def page(raw_turns, events, runtime) do
    %Page{turns: [], last_event_id: nil, runtime: runtime || ""}
    |> add_turns(raw_turns)
    |> add_events(events)
  end

  @doc "An empty page for a track with no conversation yet."
  @spec empty(String.t()) :: Page.t()
  def empty(runtime), do: page([], [], runtime)

  @doc """
  Merge a fresh turns list in. A turn already on the page keeps its events;
  a new one is placed by `inserted_at` among the recorded turns, ahead of the
  groups that only exist because events named them.
  """
  @spec add_turns(Page.t(), [Wire.t()]) :: Page.t()
  def add_turns(%Page{} = page, raw_turns) do
    records = Enum.map(raw_turns, &turn_record/1)
    by_id = Map.new(page.turns, &{&1.id, &1})

    merged =
      Enum.map(records, fn record ->
        case Map.fetch(by_id, record.id) do
          # Only the wire fields are refreshed, named one by one: this was a
          # `Map.merge/2` of the whole record over the whole turn, which
          # worked only because the record happened to hold no key the turn
          # derives. Naming them is what keeps the events and the fold the
          # turn has already accumulated out of reach of a fresh turns list.
          {:ok, existing} ->
            %{
              existing
              | prompt: record.prompt,
                origin: record.origin,
                status: record.status,
                inserted_at: record.inserted_at
            }

          :error ->
            new_turn(record, page.runtime)
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
  defp ordered_at(%Turn{inserted_at: at}) when is_binary(at), do: {0, at}
  defp ordered_at(%Turn{}), do: {1, ""}

  @doc "Every event in `events`, laid into its turn. Duplicates (by id) are ignored."
  @spec add_events(Page.t(), [Event.t() | map()]) :: Page.t()
  def add_events(page, events), do: Enum.reduce(events, page, &add_event(&2, &1))

  @doc """
  One live event, laid into its turn, which is re-parsed. A page that has
  seen this event id already is unchanged, because a snapshot and the
  stream it was taken from overlap.
  """
  @spec add_event(Page.t(), Event.t() | map()) :: Page.t()
  def add_event(page, raw) do
    case Event.from(raw) do
      %Event{id: id} = event when is_integer(id) -> place(page, event, id)
      _unnumbered -> page
    end
  end

  defp place(%Page{} = page, %Event{turn_id: turn_id} = event, id) do
    {turns, found?} =
      Enum.map_reduce(page.turns, false, fn turn, found? ->
        if turn.id == turn_id, do: {lay_in(turn, event, page.runtime), true}, else: {turn, found?}
      end)

    turns =
      if found?,
        do: turns,
        else: turns ++ [lay_in(new_turn(%Turn{id: turn_id}, page.runtime), event, page.runtime)]

    %{page | turns: turns, last_event_id: max(page.last_event_id || 0, id)}
  end

  @doc "The turns worth drawing: a prompt somebody typed, or output somebody can read."
  @spec visible_turns(Page.t()) :: [Turn.t()]
  def visible_turns(%Page{} = page), do: Enum.filter(page.turns, & &1.visible?)

  @doc "Is a turn in this page still being written? The last group, and only if unsettled."
  @spec live?(Page.t(), boolean()) :: boolean()
  def live?(%Page{} = page, running?) do
    case List.last(visible_turns(page)) do
      nil -> false
      turn -> running? and not turn.settled?
    end
  end

  # ── one turn ──────────────────────────────────────────────────────────

  @doc """
  A `Ravix.Fountain.Shapes.Turn` in the container the page grows.

  The wire record and the page's turn are two shapes because a turn grows
  `events`, `blocks` and a fold as output arrives; this carries the part that
  came off the wire across into the other. It used to read each field as
  `raw["id"] || raw[:id]`, accepting either spelling from a map with no shape
  at all, and then answered with an anonymous map that `add_turns/2` merged
  over a turn. Both ends have a shape now, so this only changes containers.
  """
  @spec turn_record(Wire.t()) :: Turn.t()
  def turn_record(%Wire{} = turn) do
    %Turn{
      id: turn.id,
      prompt: turn.prompt,
      origin: turn.origin,
      status: turn.status,
      inserted_at: turn.inserted_at
    }
  end

  defp new_turn(%Turn{} = record, runtime), do: rebuild(record, runtime)

  # The streaming case is asked first, and is the only one that repeats: the
  # event belongs after everything the turn already holds, so its blocks are
  # the blocks already computed plus this one folded on. Re-reducing the whole
  # turn per event costs a JSON decode of every line of every earlier event,
  # which is quadratic in the length of the turn and runs inside each reader's
  # LiveView process.
  #
  # Asked *first* because the three things this used to do per event were each
  # a walk of every event the turn already held --- the duplicate scan below,
  # a `++` that copied the list to put one event on the end, and `settled?/1`
  # over the whole log --- so the fold stopped being quadratic and the
  # bookkeeping around it stayed that way. An event numbered above everything
  # here cannot be a duplicate, cannot be out of order, and cannot unsettle a
  # turn, so none of those questions has to be asked of the log at all.
  defp lay_in(%Turn{} = turn, event, runtime) do
    cond do
      appended?(turn.events, event) ->
        finish(
          %{
            turn
            | events: [event | turn.events],
              settled?: turn.settled? or Event.settles?(event)
          },
          fold(event, runtime, turn.fold)
        )

      Enum.any?(turn.events, &(&1.id == event.id)) ->
        turn

      # Out of order: the order the blocks are in changes, so it is rebuilt.
      true ->
        rebuild(%{turn | events: Enum.sort_by([event | turn.events], & &1.id, :desc)}, runtime)
    end
  end

  defp appended?([], _event), do: true
  defp appended?([newest | _rest], event), do: newest.id < event.id

  # Everything derived, from the events themselves. `settled?` is sticky: a
  # turn Fountain has closed stays closed even if a later rebuild sees a
  # shorter event list.
  defp rebuild(%Turn{} = turn, runtime) do
    finish(
      %{turn | settled?: turn.settled? or settled?(turn.events)},
      turn.events
      |> Enum.reverse()
      |> Enum.reduce(empty_acc(), &fold(&1, runtime, &2))
    )
  end

  # The derived fields, from a fold that is already up to date. `settled?` is
  # the caller's, because the two callers know it for different reasons and
  # only one of them can afford to read the whole log for it.
  defp finish(%Turn{} = turn, acc) do
    blocks = blocks_of(acc)
    visible = Enum.filter(blocks, &visible_block?/1)

    %{
      turn
      | blocks: visible,
        fold: acc,
        visible?: has_text?(turn.prompt) or visible != []
    }
  end

  defp empty_acc, do: Turn.empty_fold()
  defp fold(event, runtime, acc), do: output(event, runtime, acc)
  defp blocks_of(blocks), do: Enum.reverse(blocks)

  @doc """
  Has Fountain closed this turn? `stage: "turn"` in any state other than
  `started` is the end of one. A group with no turn stage at all is not
  settled, which is the answer that makes the newest events on screen the
  live ones.
  """
  @spec settled?([Event.t()]) :: boolean()
  def settled?(events), do: Enum.any?(events, &Event.settles?/1)

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
  wire contract and stays the library's maps -- that is the boundary. What is
  added here is this module's own shapes: the pairing of a `tool_result` onto
  its `tool_use`, the timestamps, and the detail the chips need. Legacy
  dialects (a runtime that never spoke ACP on this page) are shown as plain
  text lines rather than parsed four ways.
  """
  @spec blocks_for_turn([Event.t() | map()], String.t()) :: [Block.t()]
  def blocks_for_turn(events, runtime) do
    events
    |> Enum.reduce(empty_acc(), &output(Event.from(&1), runtime, &2))
    |> blocks_of()
  end

  defp output(%Event{kind: :output, stream: :acp, data: data} = event, _runtime, acc)
       when is_binary(data) do
    data
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce(acc, &acp_line(&1, event.ts, &2))
  end

  # Legacy dialects: the text as-is rather than four vendor formats parsed
  # here. Claude, codex and opencode only ever spoke ACP on this page.
  defp output(%Event{kind: :output, stream: :stdout, data: data} = event, runtime, acc)
       when is_binary(data) do
    if acp_runtime?(runtime), do: acc, else: push_text(acc, Block.Text, data, event.ts)
  end

  # A stage that failed, with whatever Fountain said about it. These carried no
  # block at all until #35, so a machine that could not be built showed as the
  # last successful stage and then nothing: the track looked like it was still
  # thinking, and the only red thing on the page was a queued prompt claiming
  # the conversation had ended. The reason is Fountain's own text and is drawn
  # as such -- it named a billing page on the deployment that found this, which
  # is exactly the kind of sentence that must not be swallowed.
  defp output(%Event{kind: :stage, state: "failed"} = event, _runtime, acc) do
    [%Block.Failure{stage: event.stage, body: failure_reason(event)} | acc]
  end

  defp output(_event, _runtime, acc), do: acc

  @doc """
  What Fountain said about a stage that failed, or `""` when it said nothing.

  `data` is a JSON object on the wire, `{"reason": "..."}`. Anything else is
  returned as it arrived rather than dropped, since the point is not losing it.

  Public because `Ravix.PromptQueue.Server` reads the same event for the same
  reason: a prompt held behind a conversation that never started should say why,
  and both places must agree on where "why" lives (#35).
  """
  @spec failure_reason(Event.t()) :: String.t()
  def failure_reason(%Event{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> String.trim(reason)
      {:ok, %{}} -> ""
      _ -> String.trim(data)
    end
  end

  def failure_reason(_event), do: ""

  @doc "A block worth drawing: any tool, a failure, or text that is not blank."
  @spec visible_block?(Block.t()) :: boolean()
  def visible_block?(%Block.Tool{}), do: true
  # A failed stage is worth drawing even when Fountain gave no reason: that a
  # stage failed at all is the news, and a silent turn is what #35 was.
  def visible_block?(%Block.Failure{}), do: true
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
        [%Block.Raw{body: raw} | acc]

      _ ->
        acc
    end
  end

  defp apply_block(%{kind: :text, body: body}, _update, ts, acc),
    do: push_text(acc, Block.Text, body, ts)

  defp apply_block(%{kind: :thinking, body: body}, _update, ts, acc),
    do: push_text(acc, Block.Thinking, body, ts)

  defp apply_block(%{kind: :tool_use} = block, update, ts, blocks),
    do: [Block.tool(block, ts, detail(Detail.new(), update)) | blocks]

  # A result is paired onto its call by matching the struct that carries the
  # id, not by an offset remembered when the call went past. The offset
  # version was a transliteration of `tools[id] = blocks.length - 1`: it kept
  # a second map beside the blocks, converted forward index to reverse
  # position with `length(blocks) - 1 - index`, and was correct only while
  # nothing ever changed the length of the list in between. Matching asks the
  # list directly, so no invariant has to hold and no second map has to exist.
  #
  # A `tool_id` that is not a string pairs with nothing --- a `%Tool{id: nil}`
  # would otherwise match one --- so those fall to the catch-all below.
  defp apply_block(%{kind: :tool_result, tool_id: id} = block, update, ts, blocks)
       when is_binary(id),
       do: pair_result(blocks, id, block, update, ts)

  # Permission requests and anything the ACP library adds later have no
  # rendering in the transcript yet; they are dropped rather than drawn as
  # noise, as the browser dropped them.
  defp apply_block(_block, _update, _ts, acc), do: acc

  # Adjacent chunks of the same kind are one block. The timestamps are the
  # first and last chunk that landed in it. `%module{}` binds the struct at
  # the head of the list and the second argument matches against it, which is
  # the struct-name-as-tag version of the `kind` field these blocks carried.
  defp push_text([%module{} = last | rest], module, body, ts),
    do: [%{last | body: last.body <> body, ended_at: ts || last.ended_at} | rest]

  defp push_text(blocks, module, body, ts),
    do: [struct!(module, body: body, started_at: ts, ended_at: ts) | blocks]

  # The tool the result belongs to, updated in place. Not found is the list
  # unchanged: a result whose call this turn never saw is dropped, as it was.
  defp pair_result([%Block.Tool{id: id} = tool | rest], id, result, update, ts) do
    [
      %{
        tool
        | status: if(result.error?, do: :error, else: :done),
          output: result.body,
          ended_at: ts,
          detail: detail(tool.detail, update)
      }
      | rest
    ]
  end

  defp pair_result([block | rest], id, result, update, ts),
    do: [block | pair_result(rest, id, result, update, ts)]

  defp pair_result([], _id, _result, _update, _ts), do: []

  # ── tool detail (src/lib/tools.ts) ────────────────────────────────────

  @doc """
  What a tool call *was*, rather than that there was one.

  Both frames are read. `tool_call` carries the kind and the arguments;
  `tool_call_update` carries the result, and an adapter is free to put the
  diff on either, so the two are merged rather than one being trusted.
  """
  @spec detail(Detail.t(), map()) :: Detail.t()
  def detail(%Detail{} = current, update) do
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
    %Detail{kind: kind, input: input, paths: paths, edits: edits}
  end

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
  @spec edit(String.t(), String.t(), String.t()) :: Edit.t()
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
      if(head > 0, do: [%Edit.Line{kind: :ctx, text: Enum.at(old, head - 1)}], else: []) ++
        Enum.map(removed, &%Edit.Line{kind: :del, text: &1}) ++
        Enum.map(added, &%Edit.Line{kind: :add, text: &1}) ++
        if(tail > 0,
          do: [%Edit.Line{kind: :ctx, text: Enum.at(old, length(old) - tail)}],
          else: []
        )

    %Edit{path: path, lines: lines, added: length(added), removed: length(removed)}
  end

  defp common_prefix(a, b) do
    a |> Enum.zip(b) |> Enum.take_while(fn {x, y} -> x == y end) |> length()
  end

  defp common_suffix(a, b), do: common_prefix(Enum.reverse(a), Enum.reverse(b))

  defp has_text?(text) when is_binary(text), do: String.trim(text) != ""
  defp has_text?(_), do: false
end
