import { describe, expect, test } from "bun:test";
import { blocksForTurn, type Block } from "@managoat/fountain-app/acp";
import { activityOf, describeTool, edit, resultOf, toolDetails } from "./tools";
import type { LogEvent } from "../../shared/fountain-types";

/**
 * The detail pass reads the same ndjson the shared parser reads, so the
 * fixtures here are real `session/update` lines and the assertions are made
 * against blocks that came out of `blocksForTurn` — a test that built its own
 * blocks would pass while the join by `toolCallId` was broken.
 */

let seq = 0;
const line = (update: Record<string, unknown>): LogEvent => ({
  id: ++seq,
  kind: "output",
  stream: "acp",
  data: JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update } }),
  stage: null,
  state: null,
  turn_id: "t1",
  ts: "2026-09-04T12:00:00Z",
});

const toolsOf = (events: LogEvent[]) => {
  const blocks = blocksForTurn(events, "claude");
  const details = toolDetails(events);
  return { blocks, details, first: blocks.find((b): b is Extract<Block, { kind: "tool" }> => b.kind === "tool")! };
};

describe("describeTool", () => {
  test("a command reads as the command", () => {
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", title: "Bash", rawInput: { command: "bun test" } }),
    ];
    const { first, details } = toolsOf(events);
    expect(describeTool(first, details.get("a"))).toEqual({ kind: "execute", verb: "Ran", target: "bun test" });
  });

  test("a read is named by its file, relative to the worktree", () => {
    const events = [
      line({
        sessionUpdate: "tool_call",
        toolCallId: "a",
        kind: "read",
        title: "Read",
        locations: [{ path: "/home/sprite/work/antwerp/server/app.ts" }],
      }),
    ];
    const { first, details } = toolsOf(events);
    expect(describeTool(first, details.get("a"), "/home/sprite/work/antwerp").target).toBe("server/app.ts");
    // Somewhere else on the box is a fact worth showing in full.
    expect(describeTool(first, details.get("a"), "/home/sprite/work/other").target).toBe("/home/sprite/work/antwerp/server/app.ts");
  });

  test("an adapter that sends only a title keeps its title", () => {
    // The shape the mock sends, and the shape a runtime this build has no
    // vocabulary for sends. Inventing a verb over it would be the app
    // claiming to know what happened.
    const events = [line({ sessionUpdate: "tool_call", toolCallId: "a", title: "git worktree add /home/sprite/work/x" })];
    const { first, details } = toolsOf(events);
    expect(describeTool(first, details.get("a"))).toEqual({
      kind: "other",
      verb: "git worktree add /home/sprite/work/x",
      target: "",
    });
  });

  test("a kind with no arguments falls back to the title", () => {
    // The mock's shape, and therefore the whole of the offline demo: an
    // adapter that puts the command in the title and sends no `rawInput`.
    const events = [line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", title: "git worktree add /home/sprite/work/x" })];
    const { first, details } = toolsOf(events);
    expect(describeTool(first, details.get("a"))).toEqual({
      kind: "execute",
      verb: "Ran",
      target: "git worktree add /home/sprite/work/x",
    });
  });

  test("kind survives arriving on the update rather than the call", () => {
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", title: "Grep" }),
      line({ sessionUpdate: "tool_call_update", toolCallId: "a", kind: "search", rawInput: { pattern: "blocksForTurn" }, status: "completed" }),
    ];
    const { first, details } = toolsOf(events);
    expect(describeTool(first, details.get("a"))).toEqual({ kind: "search", verb: "Searched", target: "blocksForTurn" });
  });
});

describe("resultOf", () => {
  test("counts what came back, not what was asked for", () => {
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", rawInput: { command: "ls" } }),
      line({
        sessionUpdate: "tool_call_update",
        toolCallId: "a",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "one\ntwo\nthree" } }],
      }),
    ];
    const { first, details } = toolsOf(events);
    expect(resultOf(first, details.get("a"))).toBe("3 lines");
  });

  test("a call still in flight has no receipt", () => {
    const events = [line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", rawInput: { command: "ls" } })];
    const { first, details } = toolsOf(events);
    expect(resultOf(first, details.get("a"))).toBeNull();
  });

  test("an edit is counted in lines changed", () => {
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "edit", locations: [{ path: "/w/a.ts" }] }),
      line({
        sessionUpdate: "tool_call_update",
        toolCallId: "a",
        status: "completed",
        content: [{ type: "diff", path: "/w/a.ts", oldText: "one\ntwo\nthree", newText: "one\nTWO\nTOO\nthree" }],
      }),
    ];
    const { first, details } = toolsOf(events);
    expect(resultOf(first, details.get("a"))).toBe("+2 −1");
  });

  test("a failure says so", () => {
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", rawInput: { command: "false" } }),
      line({ sessionUpdate: "tool_call_update", toolCallId: "a", status: "failed" }),
    ];
    const { first, details } = toolsOf(events);
    expect(resultOf(first, details.get("a"))).toBe("failed");
  });
});

describe("edit", () => {
  test("frames the change in the lines that did not change", () => {
    const e = edit("a.ts", "keep\nold\ntail", "keep\nnew\ntail");
    expect(e.lines).toEqual([
      { kind: "ctx", text: "keep" },
      { kind: "del", text: "old" },
      { kind: "add", text: "new" },
      { kind: "ctx", text: "tail" },
    ]);
    expect([e.added, e.removed]).toEqual([1, 1]);
  });

  test("a new file is all additions", () => {
    const e = edit("a.ts", "", "one\ntwo");
    expect(e.lines.map((l) => l.kind)).toEqual(["add", "add"]);
    expect([e.added, e.removed]).toEqual([2, 0]);
  });
});

describe("activityOf", () => {
  test("names the call in flight, in the present tense", () => {
    const events = [
      line({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Looking." } }),
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", rawInput: { command: "bun test" } }),
    ];
    const { blocks, details } = toolsOf(events);
    expect(activityOf(blocks, details)).toBe("Running bun test");
  });

  test("falls back to what kind of block is last", () => {
    const writing = toolsOf([line({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } })]);
    expect(activityOf(writing.blocks, writing.details)).toBe("Writing");

    const thinking = toolsOf([line({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "hmm" } })]);
    expect(activityOf(thinking.blocks, thinking.details)).toBe("Thinking");

    expect(activityOf([], new Map())).toBe("Working");
  });

  test("a settled call is not an activity", () => {
    // The turn is still running — the agent is between calls, not inside one.
    const events = [
      line({ sessionUpdate: "tool_call", toolCallId: "a", kind: "execute", rawInput: { command: "ls" } }),
      line({ sessionUpdate: "tool_call_update", toolCallId: "a", status: "completed" }),
    ];
    const { blocks, details } = toolsOf(events);
    expect(activityOf(blocks, details)).toBe("Working");
  });
});
