/**
 * Run: one command you keep, per project.
 *
 * This is the terminal with the typing taken out. Almost every project has a
 * single command you run twenty times a day — `npm test`, `cargo check`, `make
 * lint` — and the cost of a terminal is not the keystrokes, it is remembering
 * which of the four spellings this repository uses. So the command is stored
 * and the button is one click.
 *
 * Two decisions are worth stating rather than inferring.
 *
 * The command is remembered in this browser, not on the server. It is a
 * preference about how *you* work on a project, it changes ten times in the
 * first hour and never again, and putting it in the project's settings would
 * make it a shared fact that bumps the settings revision — which marks every
 * open track stale — every time somebody tries a different flag.
 *
 * And it always runs in the track's own worktree, passed explicitly rather
 * than left to default. The terminal beside it wanders with `cd`; a run
 * command that inherited that would silently start testing whatever directory
 * you last looked at, which is a bug you would blame on the tests.
 */
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { Capabilities, Project, Track } from "../../shared/api";
import { api, ApiError } from "../lib/api";
import { NotConfigured } from "./Empty";
import { Play } from "../lib/icons";
import { ExecBlock, type ExecEntry } from "./Terminal";

export function Run({ track, project, capabilities }: { track: Track; project: Project; capabilities: Capabilities }) {
  const storageKey = `switchyard.run.${project.id}`;
  // Read straight out of storage on first render rather than in an effect: an
  // input that shows empty for one frame and then fills in is the kind of
  // flicker people learn to distrust in a panel that also runs commands.
  const [command, setCommand] = useState(() => read(storageKey));
  const [entries, setEntries] = useState<ExecEntry[]>([]);
  const [busy, setBusy] = useState(false);
  const scroller = useRef<HTMLDivElement | null>(null);
  const nextId = useRef(1);

  useLayoutEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [entries]);

  const remember = useCallback(
    (value: string) => {
      setCommand(value);
      try {
        if (value.trim()) localStorage.setItem(storageKey, value);
        else localStorage.removeItem(storageKey);
      } catch {
        // Private browsing, a full quota, a locked-down profile. Losing the
        // remembered command is a smaller problem than a panel that throws.
      }
    },
    [storageKey],
  );

  async function run() {
    const line = command.trim();
    if (!line || busy) return;
    const id = nextId.current++;
    setEntries((prev) => [...prev, { id, command: line, cwd: track.workdir, result: null, error: null }]);
    setBusy(true);
    try {
      const result = await api.exec(track.id, line, track.workdir);
      setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, result } : e)));
    } catch (err) {
      const message = err instanceof ApiError ? err.message : "The machine did not answer.";
      setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, error: message } : e)));
    } finally {
      setBusy(false);
    }
  }

  if (!capabilities.exec) {
    return (
      <NotConfigured icon={<Play size={20} />} title="Run command" variable="SPRITES_TOKEN">
        With a Sprites token, this keeps one command per project and runs it on the machine in this track's worktree,
        beside the agent rather than as a turn.
      </NotConfigured>
    );
  }

  return (
    <div className="term">
      <div className="term-scroll" ref={scroller}>
        {entries.length ? (
          entries.map((entry) => <ExecBlock key={entry.id} entry={entry} />)
        ) : (
          <p className="dim" style={{ margin: 0 }}>
            The command is kept for this project in this browser and runs in <code>{track.workdir}</code>, whatever the
            terminal's directory happens to be.
          </p>
        )}
      </div>
      <div className="term-input">
        <span className="ps1">run</span>
        <input
          value={command}
          spellCheck={false}
          autoComplete="off"
          autoCapitalize="off"
          placeholder="npm test"
          aria-label="Run command"
          style={{ flex: 1, minWidth: 0 }}
          onChange={(e) => remember(e.target.value)}
          onKeyDown={(e) => {
            if (e.key !== "Enter") return;
            e.preventDefault();
            void run();
          }}
        />
        <button type="button" className="primary" onClick={() => void run()} disabled={busy || !command.trim()}>
          {busy ? "Running…" : "Run"}
        </button>
      </div>
    </div>
  );
}

function read(key: string): string {
  try {
    return localStorage.getItem(key) ?? "";
  } catch {
    return "";
  }
}
