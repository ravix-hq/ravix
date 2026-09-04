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
 * tool chips. What this file adds is everything about *reading* them, and one
 * editorial decision that is switchyard's own.
 *
 * The decision: turns switchyard sent itself are rendered differently from
 * turns a person sent. Opening a track, closing one, surveying the machine —
 * these are real turns on a real machine and hiding them would make the
 * transcript a lie about what the box has been doing. But they are also not
 * things anybody said, and dressed as a user message they read as if the app
 * had been typing in your name. So they are a dashed one-line note, and the
 * agent's reply to them is shown normally, because that part *is* the machine
 * doing your work and it is the most reassuring thing on the screen while a
 * worktree is being cut.
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { blocksForTurn, type Block } from "@managoat/fountain-app/acp";
import { splitAuthor } from "../../shared/author";
import type { Person, TurnRecord } from "../../shared/api";
import type { LogEvent } from "../../shared/fountain-types";
import { Chevron } from "../lib/icons";

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
  /** Everyone on the track, so an attributed turn can show a face. */
  people?: Person[];
  /** True while a turn is in flight, so the trailing indicator is honest. */
  running: boolean;
  /** Rendered above the first turn — the ribbon, the starters, an empty state. */
  head?: React.ReactNode;
}

/** Within this many pixels of the bottom still counts as reading the bottom. */
const SLACK = 80;

export function Transcript({ trackId, turns, events, runtime, running, head, people = [] }: TranscriptProps) {
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
          {grouped.map((turn) => (
            <Turn key={turn.id} turn={turn} runtime={runtime} people={people} />
          ))}
          {running ? (
            <div className="thinking-now">
              <span className="dots">
                <i />
                <i />
                <i />
              </span>
              Working
            </div>
          ) : null}
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

function Turn({ turn, runtime, people }: { turn: GroupedTurn; runtime: string; people: Person[] }) {
  const blocks = useMemo(() => blocksForTurn(turn.events, runtime), [turn.events, runtime]);
  const app = turn.prompt ? appTurnLabel(turn.prompt) : null;
  // A shared track prefixes each prompt with who sent it (`shared/author.ts`).
  // The label comes back off here rather than being rendered as part of what
  // somebody wrote — it was never their words, it was the app naming them.
  const { login, text } = turn.prompt && !app ? splitAuthor(turn.prompt) : { login: null, text: turn.prompt ?? "" };
  const who = login ? (people.find((p) => p.login === login) ?? { login, name: null, avatarUrl: null }) : null;

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
        <BlockView key={i} block={block} />
      ))}
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

function BlockView({ block }: { block: Block }) {
  const [open, setOpen] = useState(false);
  switch (block.kind) {
    case "text":
      return <div className="block-text">{block.body}</div>;
    case "thinking":
      return <div className="block-thinking">{block.body}</div>;
    case "tool":
      return (
        <div className="tool">
          <button type="button" className="tool-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
            <Chevron size={13} open={open} />
            <strong>{block.name}</strong>
            <span className="truncate">{block.summary}</span>
            <span className="spacer" />
            <ToolStatus status={block.status} />
          </button>
          {open && block.output ? <pre className="tool-out">{block.output}</pre> : null}
        </div>
      );
    case "raw":
      return <div className="block-text dim">{block.body}</div>;
  }
}

function ToolStatus({ status }: { status: "running" | "done" | "error" }) {
  if (status === "error") return <span className="chip bad">failed</span>;
  if (status === "running") return <span className="dot running" />;
  return <span className="dot ready" />;
}
