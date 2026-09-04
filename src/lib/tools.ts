/**
 * What a tool call *was*, rather than that there was one.
 *
 * `blocksForTurn` (shared, `@managoat/fountain-app/acp`) flattens every call
 * to a name and a summary, because that is all a preview bubble in the rest of
 * the suite needs. A transcript somebody watches a machine work in needs the
 * rest: which of ACP's kinds it was, the arguments it was called with, the
 * files it named, and — for an edit — the actual before and after. Rendered
 * from name and summary alone, a turn that read four files, ran two commands
 * and rewrote a module is eight identical grey chips reading `execute
 * command=…`, and that sameness is the whole of why the panel feels generic
 * next to the agent's own output.
 *
 * So this is a *second pass over the same events*, not a fork of the parser:
 * the shared one still decides what blocks exist and in what order, and this
 * one joins detail onto them by `toolCallId`. Nothing here can change the
 * shape of the transcript, and the fifteen other apps on the shared parser are
 * untouched.
 */
import type { Block } from "@managoat/fountain-app/acp";
import type { LogEvent } from "../../shared/fountain-types";

/** ACP's own vocabulary. Anything unrecognised is `other` and renders as its title. */
export type ToolKind = "read" | "edit" | "delete" | "move" | "search" | "execute" | "fetch" | "think" | "other";

export interface DiffLine {
  kind: "add" | "del" | "ctx";
  text: string;
}

export interface FileEdit {
  path: string;
  lines: DiffLine[];
  added: number;
  removed: number;
}

export interface ToolDetail {
  kind: ToolKind;
  /** the call's arguments, as the adapter sent them */
  input: Record<string, unknown>;
  /** every file the call named, in the order it named them */
  paths: string[];
  edits: FileEdit[];
}

const KINDS = new Set<string>(["read", "edit", "delete", "move", "search", "execute", "fetch", "think", "other"]);

/**
 * One turn's tool calls, by id.
 *
 * Both frames are read. `tool_call` carries the kind and the arguments;
 * `tool_call_update` carries the result, and an adapter is free to put the
 * diff on either — so the two are merged rather than one being trusted.
 */
export function toolDetails(events: LogEvent[]): Map<string, ToolDetail> {
  const out = new Map<string, ToolDetail>();
  for (const ev of events) {
    if (ev.kind !== "output" || ev.stream !== "acp" || typeof ev.data !== "string") continue;
    for (const line of ev.data.split("\n")) {
      if (!line.trim()) continue;
      const update = updateOf(line);
      if (!update) continue;
      const which = str(update.sessionUpdate);
      if (which !== "tool_call" && which !== "tool_call_update") continue;
      const id = str(update.toolCallId);
      if (!id) continue;

      const detail = out.get(id) ?? { kind: "other" as ToolKind, input: {}, paths: [], edits: [] };
      const kind = str(update.kind);
      if (kind && KINDS.has(kind)) detail.kind = kind as ToolKind;
      const input = update.rawInput;
      if (isObj(input)) detail.input = { ...detail.input, ...input };
      for (const path of locations(update.locations)) if (!detail.paths.includes(path)) detail.paths.push(path);
      for (const edit of edits(update.content)) detail.edits.push(edit);
      out.set(id, detail);
    }
  }
  return out;
}

export interface ToolLine {
  kind: ToolKind;
  /** the verb, in the app's voice — "Ran", "Read", "Edited" */
  verb: string;
  /** what it was done to: a path, a command, a pattern. Rendered monospace. */
  target: string;
}

/**
 * A call as one line: verb, then the one argument that identifies it.
 *
 * The argument is picked per kind rather than by printing every key, which is
 * what makes the column of chips scannable — `Ran bun test`, `Read
 * server/tracks.ts`, `Searched blocksForTurn` read as a narrative of the turn;
 * `execute command=bun test cwd=/home/…` reads as a log file. Where the
 * adapter gave no arguments at all the tool's own title is used, because a
 * title is what an adapter that sends nothing else puts the command in.
 */
export function describeTool(block: Extract<Block, { kind: "tool" }>, detail: ToolDetail | undefined, workdir?: string | null): ToolLine {
  const input = detail?.input ?? {};
  const path = detail?.paths[0] ?? str(input.file_path) ?? str(input.path) ?? str(input.notebook_path);
  const rel = (p: string | null) => (p ? relative(p, workdir) : "");
  const title = block.name && block.name !== detail?.kind ? block.name : "";

  switch (detail?.kind) {
    case "execute":
      return { kind: "execute", verb: "Ran", target: str(input.command) ?? (title || block.summary) };
    case "read":
      return { kind: "read", verb: "Read", target: rel(path) || title };
    case "edit":
      return { kind: "edit", verb: detail.edits.length > 1 ? "Edited files" : "Edited", target: rel(path) || title };
    case "delete":
      return { kind: "delete", verb: "Deleted", target: rel(path) || title };
    case "move":
      return { kind: "move", verb: "Moved", target: rel(path) || title };
    case "search":
      return {
        kind: "search",
        verb: "Searched",
        target: str(input.pattern) ?? str(input.query) ?? str(input.regex) ?? (rel(path) || title),
      };
    case "fetch":
      return { kind: "fetch", verb: "Fetched", target: str(input.url) ?? title };
    case "think":
      return { kind: "think", verb: "Thought", target: "" };
    default:
      // An adapter this build has no kind for. Its own title is the best
      // description anybody has, and inventing a verb over it would be the
      // app claiming to know what happened.
      return { kind: "other", verb: title || "Tool", target: title ? block.summary : "" };
  }
}

/**
 * The one-line receipt under a finished call — native's `⎿`, in words.
 *
 * Counted from what actually came back, never from what was asked for: a read
 * that returned nothing says so, and that is frequently the answer to why the
 * turn went the way it did.
 */
export function resultOf(block: Extract<Block, { kind: "tool" }>, detail: ToolDetail | undefined): string | null {
  if (block.status === "running") return null;
  if (block.status === "error") return "failed";
  const edits = detail?.edits ?? [];
  if (edits.length > 0) {
    const added = edits.reduce((n, e) => n + e.added, 0);
    const removed = edits.reduce((n, e) => n + e.removed, 0);
    const where = edits.length > 1 ? ` in ${edits.length} files` : "";
    return `+${added} −${removed}${where}`;
  }
  const body = block.output.trim();
  if (!body) return "no output";
  const lines = body.split("\n");
  if (lines.length === 1) return truncate(lines[0]!, 72);
  return `${lines.length} lines`;
}

/**
 * What the machine is doing *right now*, for the indicator under the last
 * turn.
 *
 * "Working" is true of every second of every turn and therefore says nothing.
 * The last block is what it is currently doing, and naming it is the whole
 * difference between watching a machine and watching a spinner.
 */
export function activityOf(blocks: Block[], details: Map<string, ToolDetail>, workdir?: string | null): string {
  for (let i = blocks.length - 1; i >= 0; i--) {
    const block = blocks[i]!;
    if (block.kind === "tool") {
      if (block.status !== "running") break;
      const line = describeTool(block, block.id ? details.get(block.id) : undefined, workdir);
      return line.target ? `${present(line.verb)} ${truncate(line.target, 48)}` : present(line.verb);
    }
    if (block.kind === "thinking") return "Thinking";
    if (block.kind === "text") return "Writing";
  }
  return "Working";
}

/** "Ran" → "Running". The chip is a receipt; the indicator is a live report. */
function present(verb: string): string {
  switch (verb) {
    case "Ran":
      return "Running";
    case "Read":
      return "Reading";
    case "Edited":
    case "Edited files":
      return "Editing";
    case "Deleted":
      return "Deleting";
    case "Moved":
      return "Moving";
    case "Searched":
      return "Searching";
    case "Fetched":
      return "Fetching";
    case "Thought":
      return "Thinking";
    default:
      return verb;
  }
}

/**
 * A path as it reads inside this track.
 *
 * Every path on the machine starts `/home/sprite/work/<slug>/`, and repeating
 * that on every chip pushes the part that differs off the end of the line.
 * The prefix is stripped only when it matches the track's own worktree —
 * a path somewhere else on the box is a fact worth showing in full.
 */
export function relative(path: string, workdir?: string | null): string {
  if (workdir && path.startsWith(`${workdir}/`)) return path.slice(workdir.length + 1);
  if (workdir && path === workdir) return ".";
  return path;
}

/**
 * An edit, as near a real diff as the adapter's before-and-after allows.
 *
 * ACP's `diff` content is two whole strings, so the shared lines at the top
 * and bottom are found by walking in from both ends. That is not a diff
 * algorithm and does not pretend to be one — an edit whose middle moved
 * renders as one replaced run rather than as the minimal edit script. It is
 * exact about what changed and only imprecise about how tightly it is framed,
 * which is the right way round for something read at a glance.
 */
function edits(content: unknown): FileEdit[] {
  if (!Array.isArray(content)) return [];
  const out: FileEdit[] = [];
  for (const item of content) {
    if (!isObj(item) || item.type !== "diff") continue;
    const path = str(item.path) ?? "";
    const before = str(item.oldText) ?? "";
    const after = str(item.newText) ?? "";
    out.push(edit(path, before, after));
  }
  return out;
}

/** Exported for the test, which is the only thing that should call it directly. */
export function edit(path: string, before: string, after: string): FileEdit {
  const old = before === "" ? [] : before.split("\n");
  const now = after === "" ? [] : after.split("\n");
  let head = 0;
  while (head < old.length && head < now.length && old[head] === now[head]) head++;
  let tail = 0;
  while (tail < old.length - head && tail < now.length - head && old[old.length - 1 - tail] === now[now.length - 1 - tail]) tail++;

  const lines: DiffLine[] = [];
  // One line of shared context either side. More is noise on a chip; none
  // makes a one-line change impossible to place.
  if (head > 0) lines.push({ kind: "ctx", text: old[head - 1]! });
  for (const text of old.slice(head, old.length - tail)) lines.push({ kind: "del", text });
  for (const text of now.slice(head, now.length - tail)) lines.push({ kind: "add", text });
  if (tail > 0) lines.push({ kind: "ctx", text: old[old.length - tail]! });

  return {
    path,
    lines,
    added: now.length - head - tail,
    removed: old.length - head - tail,
  };
}

type Json = Record<string, unknown>;

function updateOf(line: string): Json | null {
  let msg: unknown;
  try {
    msg = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isObj(msg) || msg.method !== "session/update") return null;
  const params = msg.params;
  if (!isObj(params)) return null;
  const update = params.update;
  return isObj(update) ? update : params;
}

function locations(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const loc of raw) {
    const path = isObj(loc) ? str(loc.path) : null;
    if (path) out.push(path);
  }
  return out;
}

function isObj(v: unknown): v is Json {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function str(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}

function truncate(s: string, max: number): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}
