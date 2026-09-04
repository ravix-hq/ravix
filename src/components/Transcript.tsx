/**
 * The scrollback.
 *
 * Two sources, joined on `turn_id`, and the join is the whole of this file's
 * structure. Fountain keeps *turns* — what somebody asked for — separately
 * from the *event log*, which is the bytes the machine produced answering. A
 * transcript built from the events alone renders an agent talking to itself;
 * one built from the turns alone renders questions with no answers.
 *
 * `blocksForTurn` — shared with the rest of this suite, and a port of the
 * server's own ACP parser — turns one turn's events into text, thinking and
 * tool chips. `lib/tools.ts` reads the same events a second time for the
 * detail a chip drops. What this file adds is everything about *reading*
 * them, and two editorial decisions that are switchyard's own.
 *
 * The first: turns switchyard sent itself are rendered differently from turns
 * a person sent. Opening a track, closing one, surveying the machine — these
 * are real turns on a real machine and hiding them would make the transcript a
 * lie about what the box has been doing. But they are also not things anybody
 * said, and dressed as a user message they read as if the app had been typing
 * in your name. So they are a dashed one-line note, and the agent's reply to
 * them is shown normally, because that part *is* the machine doing your work
 * and it is the most reassuring thing on the screen while a worktree is being
 * cut.
 *
 * The second: what the agent writes is *markdown*, and what it does is a
 * sequence of distinguishable actions. Rendered as pre-wrapped text and a
 * column of identical grey chips, a turn that read four files and rewrote a
 * module looks exactly like a turn that answered a question — which is the
 * reason a transcript over a real agent can still feel generic. So the reply
 * is rendered (`lib/md.ts`, escape-first, streaming-tolerant), a call says
 * what it did to what, an edit shows the lines it changed, and while the turn
 * is live the last block carries a caret and the indicator underneath names
 * the thing currently happening rather than saying "Working".
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { blocksForTurn, type Block } from "@managoat/fountain-app/acp";
import { splitAuthor } from "../../shared/author";
import type { Person, TurnRecord } from "../../shared/api";
import type { LogEvent } from "../../shared/fountain-types";
import { renderMarkdown } from "../lib/md";
import { activityOf, describeTool, resultOf, toolDetails, type ToolDetail, type ToolKind } from "../lib/tools";
import { Chevron, File as FileIcon, Globe, Pencil, Search, Sparkle, Terminal, Wrench, X } from "../lib/icons";

export interface TranscriptProps {
  /**
   * Which track is on screen. Changing it means the reader is somewhere new,
   * so the panel goes back to the bottom whatever they had scrolled to in the
   * track they came from.
   */
  trackId: string;
  turns: TurnRecord[];
  events: LogEvent[];
  runtime: string;
  /** The track's worktree, so a path on a chip is shown relative to it. */
  workdir?: string | null;
  /** Everyone on the track, so an attributed turn can show a face. */
  people?: Person[];
  /** True while a turn is in flight, so the trailing indicator is honest. */
  running: boolean;
  /** Rendered above the first turn — the ribbon, the starters, an empty state. */
  head?: React.ReactNode;
}

/** Within this many pixels of the bottom still counts as reading the bottom. */
const SLACK = 80;

export function Transcript({ trackId, turns, events, runtime, running, head, workdir, people = [] }: TranscriptProps) {
  const scroller = useRef<HTMLDivElement | null>(null);
  const content = useRef<HTMLDivElement | null>(null);
  const pinned = useRef(true);

  const grouped = useMemo(() => group(turns, events), [turns, events]);

  // Follow the bottom, but only while the reader is already there. Yanking
  // somebody back down mid-scroll is the single most irritating thing a live
  // transcript can do, and it happens on every chunk.
  //
  // A ResizeObserver rather than an effect on the render, because most of what
  // makes this panel taller does not arrive with a React render: an avatar
  // decoding, the ribbon gaining a line once the header lands, a font. Each of
  // those grows the content *after* the effect that would have chased it has
  // already run, which is exactly the first second of opening a track — the
  // moment the transcript most needs to be at the bottom and least reliably
  // was. Observing the scroller too keeps the bottom while the window or the
  // composer changes size.
  useEffect(() => {
    const el = scroller.current;
    const inner = content.current;
    if (!el || !inner) return;
    const stick = () => {
      if (pinned.current) el.scrollTop = el.scrollHeight;
    };
    stick();
    const observer = new ResizeObserver(stick);
    observer.observe(inner);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // A new track starts pinned. Whether the reader had scrolled up to read
  // something is a fact about the track they left, and carrying it across is
  // how you open a chat onto the middle of a conversation you have not read.
  useLayoutEffect(() => {
    pinned.current = true;
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [trackId]);

  const last = grouped.length - 1;
  // Is the group at the bottom the turn being taken *now*? Between sending a
  // prompt and the first frame coming back there is a second where the track
  // is running and the newest group is still the last finished turn — long
  // enough to put a caret on something the agent said a minute ago and to
  // report what it was doing then as what it is doing now. A turn Fountain has
  // closed carries its own `stage: turn` event saying so, so the question is
  // answered from the log rather than guessed at from timing.
  const writing = running && !settled(grouped[last]);

  return (
    <div
      // `log` bottom-anchors the content. A transcript shorter than its
      // viewport otherwise sits at the top under the ribbon with a field of
      // empty space between the last thing said and the box you reply in,
      // which reads as the scroll having failed rather than as there being
      // little to show.
      className="scroll log"
      ref={scroller}
      onScroll={(e) => {
        const el = e.currentTarget;
        pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < SLACK;
      }}
    >
      <div ref={content}>
        {head}
        <div className="transcript">
          {grouped.map((turn, i) => (
            <Turn
              key={turn.id}
              turn={turn}
              runtime={runtime}
              people={people}
              workdir={workdir}
              // Only the turn at the bottom can be the one being written, and
              // only then is a caret or a live indicator true.
              live={writing && i === last}
            />
          ))}
          {running && !writing ? <Working since={null} what="Working" /> : null}
        </div>
      </div>
    </div>
  );
}

interface GroupedTurn {
  id: string;
  prompt: string | null;
  events: LogEvent[];
}

/**
 * Turns and events into one ordered list.
 *
 * Turn order comes from the turns list, because that is the order they were
 * asked in and it survives an event log that arrives out of order or with a
 * gap in it. Events whose `turn_id` matches no turn — which happens for the
 * first few frames of a turn Fountain has not finished recording — are kept in
 * a trailing group rather than dropped, so the very first thing a new track
 * shows is not an empty panel.
 */
function group(turns: TurnRecord[], events: LogEvent[]): GroupedTurn[] {
  const byTurn = new Map<string, GroupedTurn>();
  const order: string[] = [];
  for (const t of turns) {
    byTurn.set(t.id, { id: t.id, prompt: t.prompt, events: [] });
    order.push(t.id);
  }
  for (const ev of events) {
    const id = ev.turn_id ?? "";
    let turn = byTurn.get(id);
    if (!turn) {
      turn = { id: id || "pending", prompt: null, events: [] };
      byTurn.set(turn.id, turn);
      order.push(turn.id);
    }
    turn.events.push(ev);
  }
  return order.map((id) => byTurn.get(id)!).filter((t) => t.prompt !== null || t.events.length > 0);
}

function Turn({
  turn,
  runtime,
  people,
  workdir,
  live,
}: {
  turn: GroupedTurn;
  runtime: string;
  people: Person[];
  workdir?: string | null;
  live: boolean;
}) {
  // Keyed on how many events this turn has rather than on the array, which
  // `group` rebuilds on every frame that arrives. Without it, one chunk
  // landing on the last turn re-parses every turn in the track — work that
  // grows with the length of the conversation and is spent, every time, on
  // producing exactly the blocks that were already on screen.
  const key = `${turn.events.length}:${turn.events[turn.events.length - 1]?.id ?? ""}`;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const blocks = useMemo(() => blocksForTurn(turn.events, runtime), [key, runtime]);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const details = useMemo(() => toolDetails(turn.events), [key]);

  const app = turn.prompt ? appTurnLabel(turn.prompt) : null;
  // A shared track prefixes each prompt with who sent it (`shared/author.ts`).
  // The label comes back off here rather than being rendered as part of what
  // somebody wrote — it was never their words, it was the app naming them.
  const { login, text } = turn.prompt && !app ? splitAuthor(turn.prompt) : { login: null, text: turn.prompt ?? "" };
  const who = login ? (people.find((p) => p.login === login) ?? { login, name: null, avatarUrl: null }) : null;
  const lastBlock = blocks.length - 1;

  return (
    <div className="turn">
      {app ? (
        <div className="turn-app">{app}</div>
      ) : turn.prompt ? (
        <div className="said">
          {who ? (
            <span className="said-who" title={who.name ? `${who.name} (@${who.login})` : `@${who.login}`}>
              {who.avatarUrl ? <img src={who.avatarUrl} alt="" /> : <span className="mono">{who.login.slice(0, 1).toUpperCase()}</span>}
              @{who.login}
            </span>
          ) : null}
          <div className="turn-you">{text}</div>
        </div>
      ) : null}
      {blocks.map((block, i) => (
        <BlockView
          key={i}
          block={block}
          detail={block.kind === "tool" && block.id ? details.get(block.id) : undefined}
          workdir={workdir}
          // The caret belongs to the block being written; reasoning stays open
          // for the whole turn it was part of. Folding it the instant a tool
          // call starts collapses the thing somebody is mid-sentence through
          // and moves everything under it up the screen.
          live={live && i === lastBlock}
          turnLive={live}
        />
      ))}
      {live ? <Working since={turn.events[0]?.ts ?? null} what={activityOf(blocks, details, workdir)} /> : null}
    </div>
  );
}

/**
 * A turn switchyard sent itself, as one line.
 *
 * Matched on the marker the prompt contract puts at the front of every one of
 * them (`shared/spec.ts`), so there is exactly one place that decides what an
 * app turn looks like and it is the same place that writes them.
 */
function appTurnLabel(prompt: string): string | null {
  if (!prompt.startsWith("[switchyard]")) return null;
  const first = prompt.slice("[switchyard]".length).split("\n")[0]!.trim();
  return first || "Switchyard sent this machine an instruction.";
}

function BlockView({
  block,
  detail,
  workdir,
  live,
  turnLive,
}: {
  block: Block;
  detail?: ToolDetail;
  workdir?: string | null;
  /** the block currently being written */
  live: boolean;
  /** anywhere in the turn currently being taken */
  turnLive: boolean;
}) {
  switch (block.kind) {
    case "text":
      return <Markdown body={block.body} live={live} />;
    case "thinking":
      return <Thinking block={block} live={turnLive} />;
    case "tool":
      return <Tool block={block} detail={detail} workdir={workdir} />;
    case "raw":
      return <div className="block-text dim">{block.body}</div>;
  }
}

/**
 * The reply, as the agent wrote it.
 *
 * `dangerouslySetInnerHTML` over a renderer that escapes before it does
 * anything else — see `lib/md.ts`. Memoised on the body because a live turn
 * re-renders this component on every chunk and re-parsing a reply that has not
 * changed is the cheapest thing here to not do.
 */
function Markdown({ body, live }: { body: string; live: boolean }) {
  const html = useMemo(() => renderMarkdown(body), [body]);
  return <div className={`block-text md${live ? " live" : ""}`} dangerouslySetInnerHTML={{ __html: html }} />;
}

/**
 * Reasoning, folded away once the turn it belonged to is over.
 *
 * Open for the whole of a live turn — watching a machine think is the most
 * legible thing it does — and a one-line summary afterwards, because on the
 * second read it is between you and what the agent decided.
 */
function Thinking({ block, live }: { block: Extract<Block, { kind: "thinking" }>; live: boolean }) {
  const [open, setOpen] = useState(false);
  const seconds = spanOf(block.startedAt, block.endedAt);
  if (live) return <div className="block-thinking">{block.body}</div>;
  return (
    <div className="thought">
      <button type="button" className="thought-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <Chevron size={13} open={open} />
        <Sparkle size={13} />
        <span>{seconds !== null && seconds >= 1 ? `Thought for ${seconds}s` : "Thought about this"}</span>
      </button>
      {open ? <div className="block-thinking">{block.body}</div> : null}
    </div>
  );
}

const TOOL_ICONS: Record<ToolKind, (p: { size?: number }) => React.ReactElement> = {
  read: FileIcon,
  edit: Pencil,
  delete: X,
  move: FileIcon,
  search: Search,
  execute: Terminal,
  fetch: Globe,
  think: Sparkle,
  other: Wrench,
};

/**
 * One call: what it did, to what, and how it went.
 *
 * A row rather than a card. Six of these in a turn is the normal case, and six
 * bordered boxes down the middle of a transcript is a table of contents for a
 * conversation nobody asked to index. The output stays folded — it is
 * evidence, not narrative — except for an edit, whose changed lines are the
 * one thing worth seeing without asking.
 */
function Tool({
  block,
  detail,
  workdir,
}: {
  block: Extract<Block, { kind: "tool" }>;
  detail?: ToolDetail;
  workdir?: string | null;
}) {
  const [open, setOpen] = useState(false);
  const line = describeTool(block, detail, workdir);
  const result = resultOf(block, detail);
  const Icon = TOOL_ICONS[line.kind];
  const expandable = block.status !== "running" && (block.output.trim() !== "" || (detail?.edits.length ?? 0) > 0);

  return (
    <div className={`tool${block.status === "error" ? " bad" : ""}`}>
      <button
        type="button"
        className="tool-head"
        onClick={() => expandable && setOpen((v) => !v)}
        aria-expanded={expandable ? open : undefined}
        disabled={!expandable}
      >
        <span className="tool-ico">
          {expandable ? <Chevron size={12} open={open} /> : <span className="tool-nib" />}
          <Icon size={13} />
        </span>
        <strong>{line.verb}</strong>
        {line.target ? <span className="tool-target truncate">{line.target}</span> : null}
        <span className="spacer" />
        {block.status === "running" ? <span className="dot running" /> : null}
        {result ? <span className={`tool-result${block.status === "error" ? " bad" : ""}`}>{result}</span> : null}
      </button>
      {open ? (
        <div className="tool-body">
          {detail?.edits.map((e, i) => (
            <div key={i} className="tool-diff">
              {detail.edits.length > 1 ? <div className="tool-diff-path">{e.path}</div> : null}
              <pre className="diff-hunk">
                {e.lines.map((l, j) => (
                  <span key={j} className={`diff-line ${l.kind === "ctx" ? "" : l.kind}`}>
                    {l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "}
                    {l.text}
                  </span>
                ))}
              </pre>
            </div>
          ))}
          {block.output.trim() ? <pre className="tool-out">{block.output}</pre> : null}
        </div>
      ) : null}
    </div>
  );
}

/**
 * The live indicator, under the turn being written.
 *
 * It names what is happening and counts, because the two questions somebody
 * has while watching a machine work are *what is it doing* and *has it hung*,
 * and a row of animated dots answers neither. The clock ticks off a timer
 * rather than off arriving chunks: a turn that has genuinely stalled is
 * exactly the one that stops re-rendering, which is when the number matters
 * most.
 */
function Working({ since, what }: { since: string | null; what: string }) {
  const seconds = useElapsed(since);
  return (
    <div className="thinking-now">
      <span className="dots">
        <i />
        <i />
        <i />
      </span>
      {what}
      {seconds !== null && seconds >= 2 ? <span className="mono dimmer"> {seconds}s</span> : null}
    </div>
  );
}

function useElapsed(since: string | null): number | null {
  const [, tick] = useState(0);
  useEffect(() => {
    if (!since) return;
    const timer = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(timer);
  }, [since]);
  if (!since) return null;
  const started = Date.parse(since);
  if (Number.isNaN(started)) return null;
  return Math.max(0, Math.round((Date.now() - started) / 1000));
}

/**
 * Has Fountain closed this turn?
 *
 * `stage: "turn"` in any state other than `started` is the end of one. A group
 * with no turn stage at all — the first frames of a turn Fountain has not
 * finished recording — is not settled, which is the answer that makes the
 * newest events on screen the live ones.
 */
function settled(turn: GroupedTurn | undefined): boolean {
  if (!turn) return true;
  return turn.events.some((e) => e.kind === "stage" && e.stage === "turn" && e.state !== "started");
}

/** Whole seconds between two log timestamps, or null if either is missing. */
function spanOf(from: string | null, to: string | null): number | null {
  if (!from || !to) return null;
  const a = Date.parse(from);
  const b = Date.parse(to);
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  return Math.max(0, Math.round((b - a) / 1000));
}
