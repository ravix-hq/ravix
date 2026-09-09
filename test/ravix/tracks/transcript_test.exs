defmodule Ravix.Tracks.TranscriptTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Transcript

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

      assert [%{kind: :text, body: "Hello", started_at: @ts, ended_at: @later}] =
               Transcript.blocks_for_turn(events, "claude")
    end

    test "several lines in one event are parsed in order, and thinking is its own block" do
      data = Enum.join([thought("hm"), text_chunk("ok")], "\n")

      assert [%{kind: :thinking, body: "hm"}, %{kind: :text, body: "ok"}] =
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

      assert [tool] =
               Transcript.blocks_for_turn([event(1, call), event(2, done, ts: @later)], "claude")

      assert tool.kind == :tool
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

      assert [%{detail: %{kind: :edit, edits: [edit]}}] =
               Transcript.blocks_for_turn([event(1, call), event(2, done)], "claude")

      assert edit.path == "a.txt"
      assert edit.added == 1
      assert edit.removed == 1

      assert edit.lines == [
               %{kind: :ctx, text: "one"},
               %{kind: :del, text: "two"},
               %{kind: :add, text: "2"},
               %{kind: :ctx, text: "three"}
             ]
    end

    test "a line that is not ACP is raw; other JSON-RPC traffic is dropped" do
      response = Jason.encode!(%{jsonrpc: "2.0", id: 4, result: %{}})
      data = Enum.join(["plain stderr noise", response], "\n")

      assert [%{kind: :raw, body: "plain stderr noise"}] =
               Transcript.blocks_for_turn([event(1, data)], "claude")
    end

    test "a legacy runtime's stdout is shown as text; an ACP runtime's is not" do
      events = [event(1, "hello from a shell", stream: "stdout")]

      assert [%{kind: :text, body: "hello from a shell"}] =
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

  describe "page/3" do
    test "turns keep their order and their events; orphan events form a trailing group" do
      turns = [
        %{
          "id" => "t2",
          "prompt" => "second",
          "inserted_at" => "2026-09-09T10:01:00Z",
          "origin" => "user",
          "status" => "done"
        },
        %{"id" => "t1", "prompt" => "first", "inserted_at" => "2026-09-09T10:00:00Z"}
      ]

      events = [
        event(3, text_chunk("later"), turn: "t2"),
        event(1, text_chunk("reply"), turn: "t1"),
        event(2, nil, turn: "t1", kind: "stage", stage: "turn", state: "done"),
        event(4, text_chunk("new"), turn: nil)
      ]

      page = Transcript.page(turns, events, "claude")
      assert Enum.map(page.turns, & &1.id) == ["t1", "t2", "pending"]
      assert page.last_event_id == 4

      [t1, t2, pending] = page.turns
      assert t1.prompt == "first"
      assert t1.settled?
      assert [%{kind: :text, body: "reply"}] = t1.blocks
      assert Enum.map(t1.events, & &1["id"]) == [1, 2]
      assert t2.origin == "user"
      refute t2.settled?
      assert pending.prompt == nil
      assert [%{body: "new"}] = pending.blocks
    end

    test "a turn with nothing to show is not visible; lifecycle-only turns stay out of the page" do
      turns = [%{"id" => "t1", "prompt" => "  "}, %{"id" => "t2", "prompt" => "say hi"}]
      events = [event(1, nil, turn: "t1", kind: "stage", stage: "turn", state: "started")]
      page = Transcript.page(turns, events, "claude")
      assert Enum.map(Transcript.visible_turns(page), & &1.id) == ["t2"]
    end

    test "a track with no conversation is an empty page" do
      assert %{turns: [], last_event_id: nil} = Transcript.empty("claude")
    end
  end

  describe "add_event/2 and add_turns/2" do
    test "a live event lands in its turn and is not counted twice" do
      page = Transcript.page([%{"id" => "t1", "prompt" => "hi"}], [], "claude")
      page = Transcript.add_event(page, event(7, text_chunk("a")))
      page = Transcript.add_event(page, event(7, text_chunk("a")))
      page = Transcript.add_event(page, event(8, text_chunk("b")))
      assert [%{id: "t1", blocks: [%{body: "ab"}]}] = page.turns
      assert page.last_event_id == 8
    end

    test "events for a turn Fountain has not recorded yet get their prompt when the turns arrive" do
      page = Transcript.page([], [event(1, text_chunk("x"), turn: "t9")], "claude")
      assert [%{id: "t9", prompt: nil}] = page.turns

      page =
        Transcript.add_turns(page, [
          %{"id" => "t9", "prompt" => "do x", "inserted_at" => "2026-09-09T10:00:00Z"}
        ])

      assert [%{id: "t9", prompt: "do x", blocks: [%{body: "x"}]}] = page.turns
    end

    test "live?/2 is true only for a running, unsettled last turn" do
      page =
        Transcript.page(
          [%{"id" => "t1", "prompt" => "hi"}],
          [event(1, text_chunk("a"))],
          "claude"
        )

      assert Transcript.live?(page, true)
      refute Transcript.live?(page, false)

      settled =
        Transcript.add_event(page, event(2, nil, kind: "stage", stage: "turn", state: "done"))

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
      assert %{added: 1, removed: 0, lines: [%{kind: :ctx, text: "b"}, %{kind: :add, text: "c"}]} =
               Transcript.edit("f", "a\nb", "a\nb\nc")

      assert %{added: 0, removed: 2, lines: [%{kind: :del, text: "a"}, %{kind: :del, text: "b"}]} =
               Transcript.edit("f", "a\nb", "")
    end
  end
end
