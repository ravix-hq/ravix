import { describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { Transcript } from "./Transcript";
import type { LogEvent } from "../../shared/fountain-types";

/**
 * Render smoke over the whole join: turns, events, the shared parser, the
 * detail pass and the markdown renderer, in the arrangement the browser
 * actually mounts. The unit tests either side of this one can both pass while
 * the wiring between them is wrong.
 */

let seq = 0;
const acp = (update: Record<string, unknown>): LogEvent => ({
  id: ++seq,
  kind: "output",
  stream: "acp",
  data: JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update } }),
  stage: null,
  state: null,
  turn_id: "t1",
  ts: "2026-09-04T12:00:00Z",
});

const EVENTS: LogEvent[] = [
  acp({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Where is the parser" } }),
  acp({
    sessionUpdate: "tool_call",
    toolCallId: "a",
    kind: "read",
    title: "Read",
    locations: [{ path: "/home/sprite/work/antwerp/src/lib/md.ts" }],
  }),
  acp({
    sessionUpdate: "tool_call_update",
    toolCallId: "a",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "one\ntwo" } }],
  }),
  acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "## Done\n\n- rendered `md.ts`\n- ran **tests**" } }),
];

const props = {
  trackId: "trk_1",
  turns: [{ id: "t1", prompt: "render the reply", origin: "user", status: "completed", insertedAt: "2026-09-04T12:00:00Z" }],
  events: EVENTS,
  runtime: "claude",
  workdir: "/home/sprite/work/antwerp",
  running: false,
};

describe("Transcript", () => {
  test("renders the reply as markdown, not as a wall of text", () => {
    const html = renderToString(<Transcript {...props} />);
    expect(html).toContain("<h2>Done</h2>");
    expect(html).toContain("<code>md.ts</code>");
    expect(html).toContain("<strong>tests</strong>");
    // The literal markdown must not survive into the page.
    expect(html).not.toContain("## Done");
  });

  test("a call says what it did to what, relative to the worktree", () => {
    const html = renderToString(<Transcript {...props} />);
    expect(html).toContain("Read");
    expect(html).toContain("src/lib/md.ts");
    expect(html).toContain("2 lines");
    expect(html).not.toContain("/home/sprite/work/antwerp/src/lib/md.ts");
  });

  test("reasoning folds away once it is over", () => {
    const html = renderToString(<Transcript {...props} />);
    expect(html).toContain("Thought");
    expect(html).not.toContain("Where is the parser");
  });

  test("a live turn carries a caret and names what is happening", () => {
    const running = [...EVENTS.slice(0, 2)];
    const html = renderToString(<Transcript {...props} events={running} running />);
    expect(html).toContain("Reading src/lib/md.ts");
    // Reasoning still being written stays open.
    expect(html).toContain("Where is the parser");
  });

  test("the caret sits on the block currently being written", () => {
    const html = renderToString(<Transcript {...props} running />);
    expect(html).toContain("block-text md live");
    expect(html).toContain("Writing");
  });

  test("a finished turn has no indicator at all", () => {
    expect(renderToString(<Transcript {...props} />)).not.toContain("thinking-now");
  });
});
