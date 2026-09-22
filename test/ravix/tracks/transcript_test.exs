defmodule Ravix.Tracks.TranscriptTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.{Block, Detail, Edit, Event}

  @ts "2026-09-09T10:00:00Z"
  @later "2026-09-09T10:00:05Z"

  defp update(params),
    do: Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: params}})

  defp text_chunk(text),
    do: update(%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: text}})

  defp thought(text),
    do: update(%{sessionUpdate: "agent_thought_chunk", content: %{type: "text", text: text}})

  defp tool_call(id, extra \\ %{}),
    do:
      update(
        Map.merge(
          %{sessionUpdate: "tool_call", toolCallId: id, title: "Read file", kind: "read"},
          extra
        )
      )

  defp tool_done(id, extra),
    do:
      update(
        Map.merge(
          %{sessionUpdate: "tool_call_update", toolCallId: id, status: "completed"},
          extra
        )
      )

  describe "Event.from/1" do
    test "closes the vocabularies it matches on, without growing the atom table" do
      assert Event.from(%{"kind" => "output", "stream" => "acp"}).kind == :output
      assert Event.from(%{"kind" => "stage"}).kind == :stage

      # A word Fountain invents must not become an atom. It becomes `:other`,
      # which is a value Ravix already knows how to not match on.
      #
      # Asked of these two words rather than of `:erlang.system_info(:atom_count)`,
      # which is the whole VM's: this module runs beside every other async test,
      # any of which may make an atom (a module loading, a Mimic copy) between a
      # before and an after, and the count then fails a parse that made none.
      n = System.unique_integer([:positive])
      kind = "telepathy-#{n}"
      stream = "smoke-#{n}"

      assert %Event{kind: :other, stream: :other} =
               Event.from(%{"kind" => kind, "stream" => stream})

      assert_raise ArgumentError, fn -> String.to_existing_atom(kind) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(stream) end
    end

    test "gives an event with no turn somewhere to sit" do
      assert Event.from(%{"id" => 1}).turn_id == Event.pending()
      assert Event.from(%{"id" => 1, "turn_id" => ""}).turn_id == Event.pending()
      assert Event.from(%{"id" => 1, "turn_id" => "t9"}).turn_id == "t9"
    end

    test "is idempotent, so a caller need not know whether it has parsed yet" do
      once = Event.from(%{"id" => 3, "kind" => "stage", "stage" => "turn", "state" => "done"})
      assert Event.from(once) == once
    end

    test "carries every field even for a payload that has none of them" do
      bare = Event.from(%{})

      assert bare.id == nil
      assert bare.stream == nil
      assert bare.kind == :other
      assert Map.keys(bare) -- [:__struct__ | Map.keys(Map.from_struct(bare))] == []
    end

    test "keeps the prompt block Fountain puts on a turn's opening event, and no other" do
      opening = %{"kind" => "stage", "stage" => "turn", "state" => "started"}

      assert Event.from(Map.put(opening, "blocks", [%{"kind" => "prompt", "body" => "do x"}])).prompt ==
               "do x"

      # Fountain's own parse of an output event is not kept: the transcript
      # parses `data` itself, and a `text` block is not somebody's prompt.
      assert Event.from(%{"kind" => "output", "blocks" => [%{"kind" => "text", "body" => "hi"}]}).prompt ==
               nil

      for blocks <- [nil, [], [%{"kind" => "prompt", "body" => ""}], [%{"kind" => "prompt"}], "x"],
          do: assert(Event.from(Map.put(opening, "blocks", blocks)).prompt == nil)

      assert Event.starts_turn?(Event.from(opening))
      refute Event.starts_turn?(Event.from(%{opening | "state" => "completed"}))
      refute Event.starts_turn?(Event.from(%{"kind" => "output"}))
    end

    test "answers the two questions three modules used to ask in string keys" do
      turn_done = Event.from(%{"kind" => "stage", "stage" => "turn", "state" => "done"})
      turn_open = Event.from(%{"kind" => "stage", "stage" => "turn", "state" => "started"})
      failed = Event.from(%{"kind" => "stage", "stage" => "provision", "state" => "failed"})
      chatter = Event.from(%{"kind" => "output", "stream" => "acp", "data" => "x"})

      assert Event.settles?(turn_done)
      refute Event.settles?(turn_open)
      refute Event.settles?(chatter)

      assert Event.failed_stage?(failed)
      refute Event.failed_stage?(turn_done)
      refute Event.failed_stage?(chatter)
    end
  end

  defp event(id, data, opts \\ []) do
    %{
      "id" => id,
      "kind" => Keyword.get(opts, :kind, "output"),
      "stream" => Keyword.get(opts, :stream, "acp"),
      "data" => data,
      "turn_id" => Keyword.get(opts, :turn, "t1"),
      "ts" => Keyword.get(opts, :ts, @ts),
      "stage" => Keyword.get(opts, :stage),
      "state" => Keyword.get(opts, :state)
    }
  end

  describe "blocks_for_turn/2" do
    test "adjacent text chunks are one block, timestamped by first and last chunk" do
      events = [event(1, text_chunk("Hel")), event(2, text_chunk("lo"), ts: @later)]

      assert [%Block.Text{body: "Hello", started_at: @ts, ended_at: @later}] =
               Transcript.blocks_for_turn(events, "claude")
    end

    test "a plan is the newest checklist, drawn where it arrived; a cleared one is removed" do
      plan = fn entries -> update(%{sessionUpdate: "plan", entries: entries}) end

      first =
        plan.([
          %{content: "Read the code", status: "in_progress", priority: "high"},
          %{content: "Fix it", status: "pending"}
        ])

      second =
        plan.([
          %{content: "Read the code", status: "completed"},
          %{content: "Fix it", status: "in_progress"},
          # Not a word ACP has: read as not done yet, never as done.
          %{content: "Ship it", status: "shipped"},
          # Nothing to draw.
          %{content: "  ", status: "pending"},
          %{status: "pending"}
        ])

      events = [
        event(1, first),
        event(2, text_chunk("Looking.")),
        event(3, second)
      ]

      assert [%Block.Text{body: "Looking."}, %Block.Plan{entries: entries}] =
               Transcript.blocks_for_turn(events, "claude")

      assert entries == [
               %Block.Plan.Entry{content: "Read the code", status: :completed},
               %Block.Plan.Entry{content: "Fix it", status: :in_progress},
               %Block.Plan.Entry{content: "Ship it", status: :pending}
             ]

      assert [%Block.Text{}] =
               Transcript.blocks_for_turn(events ++ [event(4, plan.([]))], "claude")
    end

    test "a plan counts as something to show" do
      events = [
        event(1, update(%{sessionUpdate: "plan", entries: [%{content: "x", status: "pending"}]}))
      ]

      assert [%{visible?: true, blocks: [%Block.Plan{}]}] =
               Transcript.page(events, "claude").turns
    end

    test "several lines in one event are parsed in order, and thinking is its own block" do
      data = Enum.join([thought("hm"), text_chunk("ok")], "\n")

      assert [%Block.Thinking{body: "hm"}, %Block.Text{body: "ok"}] =
               Transcript.blocks_for_turn([event(1, data)], "claude")
    end

    test "a tool call is paired with its result on the id, with detail from both frames" do
      call =
        tool_call("c1", %{
          rawInput: %{file_path: "/home/sprite/work/kyoto/src/app.ts"},
          locations: [%{path: "/home/sprite/work/kyoto/src/app.ts"}]
        })

      done =
        tool_done("c1", %{
          content: [%{type: "content", content: %{type: "text", text: "line one\nline two"}}]
        })

      assert [%Block.Tool{} = tool] =
               Transcript.blocks_for_turn([event(1, call), event(2, done, ts: @later)], "claude")

      assert tool.id == "c1"
      assert tool.name == "Read file"
      assert tool.status == :done
      assert tool.output == "line one\nline two"
      assert tool.started_at == @ts
      assert tool.ended_at == @later
      assert tool.detail.kind == :read
      assert tool.detail.input == %{"file_path" => "/home/sprite/work/kyoto/src/app.ts"}
      assert tool.detail.paths == ["/home/sprite/work/kyoto/src/app.ts"]
      assert tool.summary == "/home/sprite/work/kyoto/src/app.ts"
    end

    test "a call still running has no result, and a non-terminal update does not finish it" do
      pending =
        update(%{sessionUpdate: "tool_call_update", toolCallId: "c1", status: "in_progress"})

      assert [%{status: :running, output: "", ended_at: nil}] =
               Transcript.blocks_for_turn(
                 [event(1, tool_call("c1")), event(2, pending)],
                 "claude"
               )
    end

    test "a failed call is an error with its output" do
      failed = tool_done("c1", %{status: "failed", rawOutput: "boom"})

      assert [%{status: :error, output: "boom"}] =
               Transcript.blocks_for_turn([event(1, tool_call("c1")), event(2, failed)], "claude")
    end

    test "an edit carries its diff lines" do
      call = tool_call("e1", %{kind: "edit", title: "Edit"})

      done =
        tool_done("e1", %{
          content: [
            %{type: "diff", path: "a.txt", oldText: "one\ntwo\nthree", newText: "one\n2\nthree"}
          ]
        })

      assert [%Block.Tool{detail: %Detail{kind: :edit, edits: [edit]}}] =
               Transcript.blocks_for_turn([event(1, call), event(2, done)], "claude")

      assert edit.path == "a.txt"
      assert edit.added == 1
      assert edit.removed == 1

      assert edit.lines == [
               %Edit.Line{kind: :ctx, text: "one"},
               %Edit.Line{kind: :del, text: "two"},
               %Edit.Line{kind: :add, text: "2"},
               %Edit.Line{kind: :ctx, text: "three"}
             ]
    end

    test "a line that is not ACP is raw; other JSON-RPC traffic is dropped" do
      response = Jason.encode!(%{jsonrpc: "2.0", id: 4, result: %{}})
      data = Enum.join(["plain stderr noise", response], "\n")

      assert [%Block.Raw{body: "plain stderr noise"}] =
               Transcript.blocks_for_turn([event(1, data)], "claude")
    end

    test "a legacy runtime's stdout is shown as text; an ACP runtime's is not" do
      events = [event(1, "hello from a shell", stream: "stdout")]

      assert [%Block.Text{body: "hello from a shell"}] =
               Transcript.blocks_for_turn(events, "legacy")

      assert [] == Transcript.blocks_for_turn(events, "claude-code")
    end

    test "stage events and empty chunks produce nothing" do
      events = [
        event(1, nil, kind: "stage", stage: "turn", state: "started"),
        event(2, text_chunk(""))
      ]

      assert [] == Transcript.blocks_for_turn(events, "claude")
    end
  end

  # A turn's `started` event as the feed serves it with `?prompts=true`: the
  # one event that carries what somebody asked for.
  defp opened(id, turn, prompt) do
    id
    |> event(nil, turn: turn, kind: "stage", stage: "turn", state: "started")
    |> Map.put("blocks", if(prompt, do: [%{"kind" => "prompt", "body" => prompt}], else: []))
  end

  describe "page/2" do
    test "turns are in the order they opened, with their prompts; orphan events trail" do
      events = [
        opened(1, "t1", "first"),
        event(2, text_chunk("reply"), turn: "t1"),
        event(3, nil, turn: "t1", kind: "stage", stage: "turn", state: "done"),
        opened(4, "t2", "second"),
        event(5, text_chunk("later"), turn: "t2"),
        event(6, text_chunk("new"), turn: nil)
      ]

      page = Transcript.page(events, "claude")
      assert Enum.map(page.turns, & &1.id) == ["t1", "t2", "pending"]
      assert page.last_event_id == 6

      [t1, t2, pending] = page.turns
      assert t1.prompt == "first"
      assert t1.settled?
      assert [%Block.Text{body: "reply"}] = t1.blocks
      # Newest first: the fold's order, and the reason a live turn does not
      # copy its whole event list per frame. See `Ravix.Tracks.Transcript.Turn`.
      assert Enum.map(t1.events, & &1.id) == [3, 2, 1]
      assert t2.prompt == "second"
      refute t2.settled?
      assert pending.prompt == nil
      assert [%{body: "new"}] = pending.blocks
    end

    test "a turn with nothing to show is not visible; lifecycle-only turns stay out of the page" do
      # An autonomous turn: Fountain serves its opening event with no prompt,
      # because nobody typed one, and it produced nothing.
      events = [opened(1, "t1", nil), opened(2, "t2", "say hi")]
      page = Transcript.page(events, "claude")
      assert Enum.map(Transcript.visible_turns(page), & &1.id) == ["t2"]
    end

    test "a track with no conversation is an empty page" do
      assert %{turns: [], last_event_id: nil} = Transcript.empty("claude")
    end
  end

  describe "add_event/2" do
    test "a live event lands in its turn and is not counted twice" do
      page = Transcript.page([opened(1, "t1", "hi")], "claude")
      page = Transcript.add_event(page, event(7, text_chunk("a")))
      page = Transcript.add_event(page, event(7, text_chunk("a")))
      page = Transcript.add_event(page, event(8, text_chunk("b")))
      assert [%{id: "t1", prompt: "hi", blocks: [%{body: "ab"}]}] = page.turns
      assert page.last_event_id == 8
    end

    test "a prompt that arrives on a copy of an event already here is still taken" do
      # The stream never carries prompts. If a page holds the bare opening
      # event and then sees the feed's copy of it, the copy's prompt counts
      # even though the event itself is a duplicate.
      page = Transcript.page([opened(1, "t1", nil)], "claude")
      assert Transcript.visible_turns(page) == []

      page = Transcript.add_event(page, opened(1, "t1", "hello"))
      assert [%{id: "t1", prompt: "hello", visible?: true}] = page.turns
      assert page.last_event_id == 1

      # And a later bare copy does not take it away again.
      page = Transcript.add_event(page, opened(1, "t1", nil))
      assert [%{prompt: "hello"}] = page.turns
    end

    test "out-of-order events still read in id order" do
      page = Transcript.page([opened(1, "t1", "hi")], "claude")

      # The blocks are folded incrementally while events arrive in order; one
      # that lands out of order has to put the turn back together.
      page = Transcript.add_event(page, event(9, text_chunk("c")))
      page = Transcript.add_event(page, event(7, text_chunk("a")))
      page = Transcript.add_event(page, event(8, text_chunk("b")))

      assert [%{prompt: "hi", blocks: [%{body: "abc"}]}] = page.turns
      assert page.last_event_id == 9
    end

    test "live?/2 is true only for a running, unsettled last turn" do
      page = Transcript.page([opened(1, "t1", "hi"), event(2, text_chunk("a"))], "claude")

      assert Transcript.live?(page, true)
      refute Transcript.live?(page, false)

      settled =
        Transcript.add_event(page, event(3, nil, kind: "stage", stage: "turn", state: "done"))

      refute Transcript.live?(settled, true)
    end
  end

  describe "app_turn_label/1" do
    test "a turn Ravix sent itself is one line, matched on the marker" do
      assert Transcript.app_turn_label(
               "[ravix] Open this track. Make its working directory, then stop.\n\ncd ..."
             ) ==
               "Open this track. Make its working directory, then stop."

      assert Transcript.app_turn_label("[ravix]\n") == "Ravix sent this machine an instruction."
      assert is_nil(Transcript.app_turn_label("please open a track"))
      assert is_nil(Transcript.app_turn_label(nil))
    end
  end

  describe "edit/3" do
    test "an appended line and a removed file are framed with one line of context" do
      assert %Edit{
               added: 1,
               removed: 0,
               lines: [%Edit.Line{kind: :ctx, text: "b"}, %Edit.Line{kind: :add, text: "c"}]
             } =
               Transcript.edit("f", "a\nb", "a\nb\nc")

      assert %Edit{
               added: 0,
               removed: 2,
               lines: [%Edit.Line{kind: :del, text: "a"}, %Edit.Line{kind: :del, text: "b"}]
             } =
               Transcript.edit("f", "a\nb", "")
    end
  end

  describe "a stage Fountain failed" do
    # The production deployment's first track: Sprites refused to build the
    # machine until the Fly organisation had a card, said so in a sentence with
    # a link in it, and the page showed the last good stage and then nothing
    # (#35).
    @reason ~s({:denied, {:http, 403, %{"error" => "Add a credit card to start using Sprites."}}})

    defp failed_stage(id, stage, reason),
      do: %{
        "id" => id,
        "turn_id" => nil,
        "kind" => "stage",
        "stage" => stage,
        "state" => "failed",
        "ts" => @ts,
        "data" => Jason.encode!(%{reason: reason})
      }

    test "becomes a block that says which stage, and why" do
      page =
        Transcript.empty("claude")
        |> Transcript.add_event(failed_stage(1, "provision", @reason))

      assert [turn] = Transcript.visible_turns(page)
      assert [%Block.Failure{stage: "provision", body: body}] = turn.blocks
      assert body =~ "Add a credit card"
    end

    test "is drawn even when Fountain gave no reason, because the failure is the news" do
      page =
        Transcript.empty("claude")
        |> Transcript.add_event(%{
          "id" => 1,
          "turn_id" => nil,
          "kind" => "stage",
          "stage" => "provision",
          "state" => "failed",
          "ts" => @ts,
          "data" => "{}"
        })

      assert [turn] = Transcript.visible_turns(page)
      assert [%Block.Failure{body: ""}] = turn.blocks
    end

    test "a stage that started or finished is still not a block" do
      page =
        Transcript.empty("claude")
        |> Transcript.add_event(%{
          "id" => 1,
          "turn_id" => nil,
          "kind" => "stage",
          "stage" => "provision",
          "state" => "started",
          "ts" => @ts,
          "data" => "{}"
        })

      assert Transcript.visible_turns(page) == []
    end

    test "failure_reason/1 survives data that is not the shape we expect" do
      reason = &Transcript.failure_reason(Event.from(&1))

      assert reason.(%{"data" => Jason.encode!(%{reason: " padded "})}) == "padded"

      # Not JSON at all: kept as it arrived rather than dropped.
      assert reason.(%{"data" => "plain words"}) == "plain words"
      assert reason.(%{"data" => "{}"}) == ""
      assert reason.(%{}) == ""
    end
  end
end
