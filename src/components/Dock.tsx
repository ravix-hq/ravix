/**
 * The dock: Setup, Run, Terminal, Machine stats, under the track you are reading.
 *
 * Conductor puts these tools under the conversation rather than beside it, and
 * the arrangement is doing real work. All four are about the *machine* — how
 * its disk was built, what you run on it, what you type at it — while
 * everything above is about the conversation, and everything to the right is
 * about the files. Splitting the screen that way means you never have to
 * choose between reading what the agent did and checking whether the tests
 * pass; both are on screen.
 *
 * Collapsing matters for the same reason. On a laptop the dock is a quarter of
 * the height, and most of the time you want that quarter back — but a dock
 * that vanishes entirely is a dock people forget exists, so it collapses to
 * its tab strip. The strip is both the reminder and the way back, and clicking
 * a tab while collapsed opens it, because that is unmistakably what somebody
 * clicking a tab meant.
 *
 * Which tab, and whether it is open, live in `localStorage` rather than in the
 * URL or on the server. It is a fact about this screen in this browser: a
 * person who works with the terminal open wants it open on every track, and
 * the answer should survive a reload without following them onto a laptop
 * where the window is a different shape.
 */
import { useEffect, useState } from "react";
import type { Capabilities, Project, Track } from "../../shared/api";
import { Chevron } from "../lib/icons";
import { Run } from "./Run";
import { Setup } from "./Setup";
import { Terminal } from "./Terminal";
import { Vitals } from "./Vitals";

type DockTab = "setup" | "run" | "terminal" | "machine";

const TABS: { key: DockTab; label: string }[] = [
  { key: "setup", label: "Setup" },
  { key: "run", label: "Run" },
  { key: "terminal", label: "Terminal" },
  { key: "machine", label: "Machine stats" },
];

const STORAGE_KEY = "switchyard.dock";

interface DockPrefs {
  open: boolean;
  tab: DockTab;
}

export function Dock({ track, project, capabilities }: { track: Track; project: Project; capabilities: Capabilities }) {
  const [prefs, setPrefs] = useState<DockPrefs>(readPrefs);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
    } catch {
      // Storage can be unavailable or full. The dock still works for this
      // session; it just forgets, which is the mildest possible failure.
    }
  }, [prefs]);

  const { open, tab } = prefs;

  return (
    <div className={open ? "dock open" : "dock"}>
      <div className="dock-tabs">
        <button
          type="button"
          className="ghost"
          aria-expanded={open}
          title={open ? "Collapse the dock" : "Expand the dock"}
          onClick={() => setPrefs((p) => ({ ...p, open: !p.open }))}
        >
          <Chevron open={open} />
        </button>
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            className={open && tab === t.key ? "tab on" : "tab"}
            aria-current={open && tab === t.key}
            // Selecting a tab is also how you reopen a collapsed dock, and
            // clicking the tab that is already showing closes it again — the
            // same gesture a docked panel has in every editor this borrows from.
            onClick={() => setPrefs((p) => (p.open && p.tab === t.key ? { ...p, open: false } : { open: true, tab: t.key }))}
          >
            {t.label}
          </button>
        ))}
      </div>
      {open ? (
        <div className="dock-body">
          {/* Keyed by track so the terminal's scrollback and working directory
              belong to one worktree. Carrying them across a track switch would
              show output from a directory the prompt no longer points at. */}
          {tab === "setup" ? <Setup key={project.id} project={project} /> : null}
          {tab === "run" ? <Run key={track.id} track={track} project={project} capabilities={capabilities} /> : null}
          {tab === "terminal" ? <Terminal key={track.id} track={track} /> : null}
          {tab === "machine" ? <Vitals key={track.id} track={track} /> : null}
        </div>
      ) : null}
    </div>
  );
}

function readPrefs(): DockPrefs {
  const fallback: DockPrefs = { open: false, tab: "terminal" };
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<DockPrefs>;
    const tab = TABS.some((t) => t.key === parsed.tab) ? (parsed.tab as DockTab) : fallback.tab;
    return { open: parsed.open === true, tab };
  } catch {
    // A half-written value from an older build, or storage that throws on
    // read. Either way the dock opens in its default shape.
    return fallback;
  }
}
