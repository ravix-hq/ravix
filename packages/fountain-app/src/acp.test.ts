import { describe, expect, test } from "bun:test";
import { assistantText, blocksForTurn } from "./acp";
import type { LogEvent } from "./types";

function acp(update: unknown, id = 1): LogEvent {
  return {
    id,
    kind: "output",
    stream: "acp",
    data: JSON.stringify({
      jsonrpc: "2.0",
      method: "session/update",
      params: { sessionId: "s", update },
    }),
    stage: null,
    state: null,
    turn_id: "t",
    ts: "2026-08-18T00:00:00Z",
  };
}

const chunk = (text: string, id = 1) =>
  acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }, id);

describe("blocksForTurn", () => {
  test("concatenates message chunks into one text block", () => {
    const blocks = blocksForTurn([chunk("Hel", 1), chunk("lo", 2)], "claude");
    expect(blocks).toEqual([{ kind: "text", body: "Hello", startedAt: "2026-08-18T00:00:00Z", endedAt: "2026-08-18T00:00:00Z" }]);
    expect(assistantText([chunk("Hel", 1), chunk("lo", 2)], "claude")).toBe("Hello");
  });
  test("a text block is stamped with its first and last chunk's arrival", () => {
    const events = [
      { ...chunk("Hel", 1), ts: "2026-08-18T00:00:00Z" },
      { ...chunk("lo", 2), ts: "2026-08-18T00:00:03Z" },
      { ...chunk(" there", 3), ts: "2026-08-18T00:00:05Z" },
    ];
    expect(blocksForTurn(events, "claude")).toEqual([
      { kind: "text", body: "Hello there", startedAt: "2026-08-18T00:00:00Z", endedAt: "2026-08-18T00:00:05Z" },
    ]);
  });

  test("pairs a tool call with its terminal update and ignores in-flight ones", () => {
    const events = [
      acp(
        {
          sessionUpdate: "tool_call",
          toolCallId: "c1",
          title: "Read file",
          locations: [{ path: "lib/a.ex" }],
        },
        1,
      ),
      acp({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "in_progress" }, 2),
      acp(
        {
          sessionUpdate: "tool_call_update",
          toolCallId: "c1",
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "defmodule A" } }],
        },
        3,
      ),
    ];
    expect(blocksForTurn(events, "claude")).toEqual([
      {
        kind: "tool",
        id: "c1",
        name: "Read file",
        summary: "lib/a.ex",
        status: "done",
        output: "defmodule A",
        startedAt: "2026-08-18T00:00:00Z",
        endedAt: "2026-08-18T00:00:00Z",
      },
    ]);
  });

  test("a failed tool is an error; thoughts are separate from text", () => {
    const events = [
      acp({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "hmm" } }, 1),
      acp({ sessionUpdate: "tool_call", toolCallId: "c2", kind: "execute", rawInput: { cmd: "ls" } }, 2),
      acp({ sessionUpdate: "tool_call_update", toolCallId: "c2", status: "failed", rawOutput: "no" }, 3),
      chunk("done", 4),
    ];
    expect(blocksForTurn(events, "claude")).toEqual([
      { kind: "thinking", body: "hmm", startedAt: "2026-08-18T00:00:00Z", endedAt: "2026-08-18T00:00:00Z" },
      {
        kind: "tool",
        id: "c2",
        name: "execute",
        summary: "cmd=ls",
        status: "error",
        output: "no",
        startedAt: "2026-08-18T00:00:00Z",
        endedAt: "2026-08-18T00:00:00Z",
      },
      { kind: "text", body: "done", startedAt: "2026-08-18T00:00:00Z", endedAt: "2026-08-18T00:00:00Z" },
    ]);
  });

  test("drops user echoes, plans and other JSON-RPC traffic; keeps garbage as raw", () => {
    const events = [
      acp({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "me" } }, 1),
      acp({ sessionUpdate: "plan", entries: [] }, 2),
      { ...chunk("x", 3), data: '{"jsonrpc":"2.0","id":1,"result":{}}' },
      { ...chunk("x", 4), data: "not json at all" },
    ];
    expect(blocksForTurn(events, "claude")).toEqual([{ kind: "raw", body: "not json at all" }]);
  });

  test("legacy stdout of a non-ACP runtime shows as text; stage events are ignored", () => {
    const events: LogEvent[] = [
      { ...chunk("", 1), stream: "stdout", data: "plain gemini line" },
      { ...chunk("", 2), kind: "stage", stream: null, data: null, stage: "turn", state: "done" },
    ];
    expect(blocksForTurn(events, "gemini")).toEqual([{ kind: "text", body: "plain gemini line", startedAt: "2026-08-18T00:00:00Z", endedAt: "2026-08-18T00:00:00Z" }]);
    expect(blocksForTurn(events, "claude")).toEqual([]);
  });
});
