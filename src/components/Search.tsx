/**
 * Every track in the yard, in one list.
 *
 * The sidebar is organised by project because that is how the machines are
 * organised, but nobody remembers which project a piece of work is under —
 * they remember what they were doing. So this is the other index: type three
 * letters of a title, a project or a branch and press Enter.
 *
 * It searches what is already loaded rather than asking the server. Tracks are
 * the shell's own state and are already streamed as they change, so a fetch
 * here would be a slower copy of something the app is holding.
 */
import { useEffect, useId, useMemo, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import type { Project, Track } from "../../shared/api";
import { Branch, Search as SearchIcon } from "../lib/icons";
import { Dialog } from "./Dialog";
import { Empty } from "./Empty";

export interface SearchProps {
  projects: Project[];
  tracksByProject: Record<string, Track[]>;
  onPick: (projectId: string, trackId: string) => void;
  onClose: () => void;
}

export function Search({ projects, tracksByProject, onPick, onClose }: SearchProps) {
  const [filter, setFilter] = useState("");
  const [at, setAt] = useState(0);
  const listId = useId();

  const rows = useMemo(() => {
    // Project order, then track order, both as the shell holds them: the
    // sidebar's order is the one people have already learned.
    const all = projects.flatMap((project) =>
      (tracksByProject[project.id] ?? []).map((track) => ({
        project,
        track,
        hay: `${track.title} ${project.name} ${track.branch}`.toLowerCase(),
      })),
    );
    const needle = filter.trim().toLowerCase();
    return needle ? all.filter((r) => r.hay.includes(needle)) : all;
  }, [projects, tracksByProject, filter]);

  useEffect(() => {
    setAt(0);
  }, [filter]);
  const cursor = rows.length ? Math.min(at, rows.length - 1) : 0;

  useEffect(() => {
    document.getElementById(`${listId}-${cursor}`)?.scrollIntoView({ block: "nearest" });
  }, [cursor, listId, rows.length]);

  function onKeyDown(event: ReactKeyboardEvent): void {
    if (!rows.length) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setAt((n) => (Math.min(n, rows.length - 1) + 1) % rows.length);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setAt((n) => (Math.min(n, rows.length - 1) + rows.length - 1) % rows.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const row = rows[cursor];
      if (row) onPick(row.project.id, row.track.id);
    }
  }

  return (
    <Dialog
      title="Go to track"
      onClose={onClose}
      footer={
        <>
          <span className="dimmer">
            <kbd>↑</kbd> <kbd>↓</kbd> to move, <kbd>⏎</kbd> to go
          </span>
          <span className="spacer" />
          <span className="dimmer">
            {rows.length} track{rows.length === 1 ? "" : "s"}
          </span>
        </>
      }
    >
      <div className="search-line" onKeyDown={onKeyDown}>
        <SearchIcon />
        <input
          autoFocus
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Search tracks by title, project or branch"
          aria-label="Search tracks"
          role="combobox"
          aria-expanded
          aria-controls={listId}
          aria-activedescendant={rows.length ? `${listId}-${cursor}` : undefined}
          autoComplete="off"
        />
      </div>

      {/* The empty state sits outside the listbox: a list whose only child is
          a paragraph still announces as a list with one item in it. */}
      <div className="dialog-body flush">
        {rows.length === 0 ? (
          <Empty icon={<Branch size={20} />} title="Nothing matches">
            {filter.trim()
              ? `No track's title, project or branch contains "${filter.trim()}".`
              : "There are no tracks open yet. Open one from a project and it will show up here."}
          </Empty>
        ) : (
          <div id={listId} role="listbox" aria-label="Tracks">
            {rows.map((row, i) => (
              <button
                key={row.track.id}
                id={`${listId}-${i}`}
                type="button"
                role="option"
                aria-selected={i === cursor}
                tabIndex={-1}
                className={`pick-row${i === cursor ? " on" : ""}`}
                onMouseEnter={() => setAt(i)}
                onClick={() => onPick(row.project.id, row.track.id)}
              >
                <span className={`dot ${row.track.status}`} aria-hidden="true" />
                <span className="truncate">{row.track.title}</span>
                <span className="dim truncate">{row.project.name}</span>
                <span className="meta">
                  {/* The dot is colour, and colour alone is not a status. A
                      track that is running, still opening or failed says so in
                      words; "ready" is the quiet default and needs none. */}
                  {row.track.status !== "ready" ? <span>{row.track.status}</span> : null}
                  <span className="mono truncate">{row.track.branch}</span>
                  {i === cursor ? (
                    <span>
                      Go <kbd>⏎</kbd>
                    </span>
                  ) : null}
                </span>
              </button>
            ))}
          </div>
        )}
      </div>
    </Dialog>
  );
}
