/**
 * The terminal, which is a shell and says so.
 *
 * `server/terminal.ts` gives this panel exactly one thing: a command in, a
 * result out, on the machine the track's worktree lives on. That is less than
 * a terminal emulator and more than a chat message, and both halves of that
 * matter to the person typing here.
 *
 * Less, because there is no tty. Sprites' exec is one HTTP request and one
 * response, so `vim` opens nothing, `top` returns when it is killed, and a
 * program that waits for input waits until the timeout. The note above the
 * prompt says this before somebody spends a minute finding it out.
 *
 * More, because these commands do not go through Fountain. They are not turns:
 * they skip the box's one-turn-at-a-time lock, so `git status` answers while
 * the agent is mid-edit. That is the whole reason this panel exists rather
 * than being a message that asks the agent to run `ls`.
 *
 * The one piece of state worth naming is `cwd`. Each exec is a fresh process,
 * so `cd ..` cannot survive on the machine — the server reports where the
 * shell ended up, this component remembers it, and the next command is sent
 * with it. The directory in the prompt is therefore real rather than
 * decorative, and it is what makes a sequence of commands feel like a session.
 */
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent } from "react";
import type { ExecResult, Track } from "../../shared/api";
import { api, ApiError } from "../lib/api";
import { Empty, NotConfigured } from "./Empty";
import { Machine, Terminal as TerminalIcon } from "../lib/icons";

/**
 * One command and whatever came back, which may be nothing yet.
 *
 * `result` and `error` both null means the command is still out, and that is
 * the only "running" flag the block needs — a separate boolean would be a
 * second source of truth for a state the other two fields already describe.
 * `cwd` is the directory the command was *typed* in, not the one it left the
 * shell in, so the echoed prompt keeps matching what the person saw.
 */
export interface ExecEntry {
  id: number;
  command: string;
  cwd: string;
  result: ExecResult | null;
  error: string | null;
}

/**
 * A command and its output, rendered once and used twice.
 *
 * The run panel shows the same thing the terminal shows, because it is the
 * same thing: a command, a directory, two streams and an exit code. Exporting
 * this rather than writing it again is not only less code — it means a fix to
 * how a non-zero exit reads happens in one place, which is the sort of detail
 * that otherwise drifts between two panels until they look unrelated.
 */
export function ExecBlock({ entry }: { entry: ExecEntry }) {
  const { result, error } = entry;
  return (
    <div className="term-block">
      <div className="term-cmd">
        <span className="ps1">{basename(entry.cwd)} $</span>
        {entry.command}
      </div>
      {result?.stdout ? <pre className="term-out">{trimTrailing(result.stdout)}</pre> : null}
      {result?.stderr ? <pre className="term-out err">{trimTrailing(result.stderr)}</pre> : null}
      {error ? <pre className="term-out err">{error}</pre> : null}
      {!result && !error ? <pre className="term-out">Running…</pre> : null}
      {result ? <Verdict result={result} /> : null}
    </div>
  );
}

/**
 * The last line of a block, printed only when it says something.
 *
 * A successful command that printed its own output does not need a footer
 * telling you it exited zero; a failing one badly needs to say so, because
 * plenty of tools fail silently on stdout. So this renders for a non-zero code
 * or a timeout and stays out of the way otherwise.
 */
function Verdict({ result }: { result: ExecResult }) {
  const seconds = (result.durationMs / 1000).toFixed(1);
  if (result.timedOut) return <div className="term-code">Timed out after {seconds}s and was killed.</div>;
  if (result.code !== 0) return <div className="term-code">Exited {result.code} · {seconds}s</div>;
  return null;
}

type Status = { available: boolean; why: "no_token" | "no_machine" | "no_sprite" | "unreachable" | null; cwd: string };

export function Terminal({ track }: { track: Track }) {
  const [status, setStatus] = useState<Status | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [entries, setEntries] = useState<ExecEntry[]>([]);
  const [cwd, setCwd] = useState(track.workdir);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);

  // Command history, oldest first, with `cursor` counting back from the end.
  // Null means "typing something new", which is what distinguishes pressing
  // down past the newest entry from having never pressed up at all.
  const history = useRef<string[]>([]);
  const [cursor, setCursor] = useState<number | null>(null);

  const scroller = useRef<HTMLDivElement | null>(null);
  const input = useRef<HTMLInputElement | null>(null);
  // Whether the view is following new output. Set from the scroll position
  // rather than from a click, because reading back through a long build's
  // output and being yanked to the bottom by its last line is the specific
  // annoyance this exists to prevent.
  const following = useRef(true);
  const nextId = useRef(1);

  const load = useCallback(() => {
    setStatusError(null);
    setStatus(null);
    api
      .execStatus(track.id)
      .then((s) => {
        setStatus(s);
        setCwd(s.cwd);
      })
      .catch((err: unknown) => setStatusError(err instanceof ApiError ? err.message : "Could not ask the machine whether it is up."));
  }, [track.id]);

  useEffect(load, [load]);

  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && following.current) el.scrollTop = el.scrollHeight;
  }, [entries]);

  async function run(command: string) {
    const id = nextId.current++;
    const at = cwd;
    history.current = [...history.current.filter((c) => c !== command), command].slice(-200);
    setCursor(null);
    setEntries((prev) => [...prev, { id, command, cwd: at, result: null, error: null }]);
    setDraft("");
    setBusy(true);
    // A command that fails to *reach* the machine is a different thing from a
    // command that ran and failed, and the block distinguishes them: this path
    // fills `error`, the machine's own failure fills `result.stderr`.
    try {
      const result = await api.exec(track.id, command, at);
      setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, result } : e)));
      setCwd(result.cwd);
    } catch (err) {
      const message = err instanceof ApiError ? err.message : "The machine did not answer.";
      setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, error: message } : e)));
    } finally {
      setBusy(false);
      input.current?.focus();
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter") {
      const command = draft.trim();
      if (command && !busy) void run(command);
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "l") {
      e.preventDefault();
      setEntries([]);
      return;
    }
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      const list = history.current;
      if (!list.length) return;
      e.preventDefault();
      const next =
        e.key === "ArrowUp"
          ? Math.min((cursor ?? -1) + 1, list.length - 1)
          : (cursor ?? -1) - 1;
      if (next < 0) {
        setCursor(null);
        setDraft("");
        return;
      }
      setCursor(next);
      setDraft(list[list.length - 1 - next] ?? "");
    }
  }

  if (statusError) {
    return (
      <Empty icon={<Machine size={20} />} title="Could not reach the terminal" action={{ label: "Try again", onClick: load }}>
        {statusError}
      </Empty>
    );
  }

  if (!status) return <div className="empty dim">Checking the machine…</div>;

  if (status.why === "no_token") {
    return (
      <NotConfigured icon={<TerminalIcon size={20} />} title="Terminal" variable="SPRITES_TOKEN">
        With a Sprites token, this panel runs commands directly on the machine your worktree is on — out of band from the
        agent's turns, so you can look around while it is still working.
      </NotConfigured>
    );
  }

  if (status.why === "no_machine") {
    return (
      <Empty icon={<Machine size={20} />} title="No machine yet" because="The machine is built when a project first needs one.">
        This project has nothing running to type at. Open a track and the machine appears with it.
      </Empty>
    );
  }

  if (status.why === "no_sprite") {
    return (
      <Empty icon={<Machine size={20} />} title="No direct access to this machine" because="The sandbox did not name a sprite.">
        This sandbox is not running on Sprites, so switchyard cannot open a shell on it. Everything else about the track
        works; ask the agent to run the command instead.
      </Empty>
    );
  }

  if (!status.available) {
    return (
      <Empty
        icon={<Machine size={20} />}
        title="The machine did not answer"
        because="It may be suspended, and it wakes on the next thing that needs it."
        action={{ label: "Try again", onClick: load }}
      >
        Switchyard knows which machine this track is on but could not reach it just now.
      </Empty>
    );
  }

  return (
    <div className="term">
      <div
        className="term-scroll"
        ref={scroller}
        onScroll={(e) => {
          const el = e.currentTarget;
          following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
        }}
        onClick={() => input.current?.focus()}
      >
        {entries.map((entry) => (
          <ExecBlock key={entry.id} entry={entry} />
        ))}
      </div>
      <div className="dim" style={{ padding: "6px 10px 0", fontSize: 11.5 }}>
        One command at a time and no tty, so <code>vim</code> and <code>top</code> will not work, and this runs beside the
        agent rather than as a turn.
      </div>
      <div className="term-input">
        <span className="ps1">{basename(cwd)} $</span>
        <input
          ref={input}
          value={draft}
          spellCheck={false}
          autoComplete="off"
          autoCapitalize="off"
          disabled={busy}
          placeholder={busy ? "Waiting for the machine…" : "git status"}
          aria-label="Command"
          style={{ flex: 1, minWidth: 0 }}
          onChange={(e) => {
            setDraft(e.target.value);
            setCursor(null);
          }}
          onKeyDown={onKeyDown}
        />
        <button type="button" className="ghost" onClick={() => setEntries([])} disabled={!entries.length} title="Clear (Ctrl+L)">
          Clear
        </button>
      </div>
    </div>
  );
}

/**
 * The last segment of a path, for the prompt.
 *
 * Shells print the whole path or a `~`-relative one; neither fits in a strip
 * this narrow, and the part that changes as you move around is the last
 * segment anyway. The root keeps its slash so `/` does not render as nothing.
 */
function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  if (!trimmed) return "/";
  return trimmed.slice(trimmed.lastIndexOf("/") + 1) || "/";
}

/** Command output almost always ends in a newline, and `pre` would show it as a blank line. */
function trimTrailing(text: string): string {
  return text.replace(/\n+$/, "");
}
