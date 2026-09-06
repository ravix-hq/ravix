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

/**
 * A long track opens on its end, not on its beginning. The first commit is a
 * page of the newest turns and nothing above them, which is what makes the
 * bottom of the conversation the first thing on the screen however many turns
 * are behind it; the rest is laid in above once there is a scroller to measure
 * against, which is why it is not visible here.
 */
describe("Transcript window", () => {
  test("empty lifecycle turns do not add gaps or displace messages from the opening page", () => {
    const empty = Array.from({ length: 100 }, (_, i) => ({
      ...props.turns[0]!, id: `empty-${i}`, prompt: i % 2 ? null : "",
    }));
    const events: LogEvent[] = empty.map((t, i) => ({
      id: 1000 + i, kind: "stage", stage: "turn", state: "completed",
      stream: null, data: null, turn_id: t.id, ts: "2026-09-04T12:00:00Z",
    }));
    const html = renderToString(<Transcript {...props} turns={[...props.turns, ...empty]}
      events={[...EVENTS, ...events]} head={<div>ribbon</div>} />);
    expect(html).toContain("render the reply");
    expect(html).toContain("ribbon");
    expect(html.match(/class="turn"/g)).toHaveLength(1);
  });

  test("events without a turn ID share one group and retain every output", () => {
    const events = ["First", " second"].map((text) => ({
      ...acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
      turn_id: null,
    }));
    const html = renderToString(<Transcript {...props} turns={[]} events={events} />);
    expect(html).toContain("First second");
    expect(html.match(/class="turn"/g)).toHaveLength(1);
  });

  test("whitespace-only output blocks do not create gaps around tool calls", () => {
    const blank = () => acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "\n\n   " } });
    const html = renderToString(<Transcript {...props} events={[blank(), EVENTS[1]!, blank()]} />);
    expect(html).toContain("src/lib/md.ts");
    expect(html).not.toContain('class="block-text md"');
  });

  const many = Array.from({ length: 40 }, (_, i) => ({
    id: `t${i}`,
    prompt: `turn number ${i}`,
    origin: "user",
    status: "completed",
    insertedAt: "2026-09-04T12:00:00Z",
  }));

  test("opens on the last page of a long track", () => {
    const html = renderToString(<Transcript {...props} turns={many} events={[]} head={<div>ribbon</div>} />);
    expect(html).toContain("turn number 39");
    expect(html).toContain("turn number 35");
    expect(html).not.toContain("turn number 0<");
    expect(html).not.toContain("turn number 20");
  });

  test("the ribbon waits for the top of the track rather than heading the window", () => {
    const long = renderToString(<Transcript {...props} turns={many} events={[]} head={<div>ribbon</div>} />);
    expect(long).not.toContain("ribbon");
    const short = renderToString(<Transcript {...props} turns={many.slice(0, 3)} events={[]} head={<div>ribbon</div>} />);
    expect(short).toContain("ribbon");
    expect(short).toContain("turn number 0");
  });
});

test("replayed prompts and reply chunks render in chronological order", () => {
  const first = { ...props.turns[0]!, id: "first", prompt: "First question", insertedAt: "2026-09-04T12:00:00Z" };
  const second = { ...first, id: "second", prompt: "Second question", insertedAt: "2026-09-04T12:01:00Z" };
  const reply = (id: number, turn_id: string, text: string) => ({
    ...acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
    id, turn_id,
  });
  const html = renderToString(<Transcript {...props} turns={[second, first]} events={[
    reply(3, "second", "Second answer"),
    reply(2, "first", " answer"),
    reply(1, "first", "First"),
  ]} />);
  const positions = ["First question", "First answer", "Second question", "Second answer"].map(text => html.indexOf(text));
  expect(positions.every(position => position >= 0)).toBe(true);
  expect(positions).toEqual([...positions].sort((a, b) => a - b));
});

test("unattributed events are rendered once in one pending group", () => {
  const events = EVENTS.map(event => ({ ...event, turn_id: null }));
  const html = renderToString(<Transcript {...props} turns={[]} events={events} />);
  expect(html.match(/<h2>Done<\/h2>/g)).toHaveLength(1);
});
