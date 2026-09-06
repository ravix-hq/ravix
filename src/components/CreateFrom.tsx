/** Quick creation from the default branch, with repository sources under Advanced. */
import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import type { BranchRef, IssueRef, Project, PullRef, Track, TrackOriginInfo } from "../../shared/api";
import { nameTrack } from "../../shared/names";
import { api } from "../lib/api";
import { Branch, Issue, Pull, Search, Sparkle } from "../lib/icons";
import { Dialog, ago } from "./Dialog";
import { Empty } from "./Empty";

type Tab = "branches" | "pulls" | "issues";

const TABS: { id: Tab; label: string }[] = [
  { id: "branches", label: "Branches" },
  { id: "pulls", label: "PRs" },
  { id: "issues", label: "Issues" },
];

/** One selectable line, flattened so the keyboard does not care which tab it came from. */
interface Row {
  key: string;
  icon: ReactNode;
  /** `#123`, for the fixed-width column that keeps titles aligned. */
  num: string | null;
  label: string;
  meta: ReactNode;
  /** Everything the filter searches, lowercased once rather than per keystroke. */
  hay: string;
  open: () => void;
}

export interface CreateFromProps {
  project: Project;
  tracks?: Track[];
  onOpen: (track: Track) => void;
  onClose: () => void;
}

export function CreateFrom({ project, tracks = [], onOpen, onClose }: CreateFromProps) {
  const [advanced, setAdvanced] = useState(false);
  const [name, setName] = useState(() => nameTrack(tracks.flatMap((track) => [track.title, track.slug])));
  const starting = useRef(false);
  const nameId = useId();
  const [tab, setTab] = useState<Tab>("branches");
  const [branches, setBranches] = useState<BranchRef[] | null>(null);
  const [pulls, setPulls] = useState<PullRef[] | null>(null);
  const [issues, setIssues] = useState<IssueRef[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [at, setAt] = useState(0);
  const [opening, setOpening] = useState<string | null>(null);
  const listId = useId();

  const loaded = tab === "branches" ? branches : tab === "pulls" ? pulls : issues;

  useEffect(() => {
    // A project with no repository has nothing to list — the server answers
    // 409 rather than an empty array, which is the honest answer and a bad
    // thing to show somebody as an error they cannot fix.
    if (!advanced || !project.repo || loaded) return;
    let live = true;
    setLoading(true);
    setError(null);
    const request =
      tab === "branches" ? api.branches(project.id) : tab === "pulls" ? api.pulls(project.id) : api.issues(project.id);
    request.then(
      (data) => {
        if (!live) return;
        setLoading(false);
        if (tab === "branches") setBranches(data as BranchRef[]);
        else if (tab === "pulls") setPulls(data as PullRef[]);
        else setIssues(data as IssueRef[]);
      },
      (err: unknown) => {
        if (!live) return;
        setLoading(false);
        setError(err instanceof Error ? err.message : "Could not read that repository.");
      },
    );
    return () => {
      live = false;
    };
  }, [advanced, tab, project.id, project.repo, loaded]);

  async function start(key: string, body: { title?: string; origin: Partial<TrackOriginInfo> }): Promise<void> {
    if (starting.current) return;
    starting.current = true;
    setOpening(key);
    setError(null);
    try {
      onOpen(await api.openTrack(project.id, body));
    } catch (err) {
      starting.current = false;
      setOpening(null);
      setError(err instanceof Error ? err.message : "Could not open that track.");
    }
  }

  const rows = useMemo<Row[]>(() => {
    const out: Row[] = [];
    if (tab === "branches") {
      // First, because a track that starts from nothing is the one thing here
      // that never needs GitHub to answer — including when GitHub just failed.
      out.push({
        key: "blank",
        icon: <Sparkle />,
        num: null,
        label: "Blank track",
        meta: <span>{project.defaultBranch ? `cut from ${project.defaultBranch}` : "an empty worktree"}</span>,
        hay: "blank track empty new",
        open: () => void start("blank", { origin: { kind: "blank" } }),
      });
      for (const branch of branches ?? []) {
        out.push({
          key: `branch:${branch.name}`,
          icon: <Branch />,
          num: null,
          label: branch.name,
          meta: (
            <>
              {branch.isDefault ? <span className="chip">default</span> : null}
              <span className="mono">{branch.sha.slice(0, 7)}</span>
            </>
          ),
          hay: branch.name.toLowerCase(),
          open: () =>
            void start(`branch:${branch.name}`, { title: branch.name, origin: { kind: "branch", base: branch.name } }),
        });
      }
    } else if (tab === "pulls") {
      for (const pull of pulls ?? []) {
        out.push({
          key: `pr:${pull.number}`,
          icon: <Pull />,
          num: `#${pull.number}`,
          label: pull.title,
          meta: (
            <>
              {pull.draft ? <span className="chip">draft</span> : null}
              <span className="mono">{pull.headRef}</span>
              <span>{ago(pull.updatedAt)}</span>
            </>
          ),
          hay: `${pull.title} ${pull.number} ${pull.author ?? ""} ${pull.headRef}`.toLowerCase(),
          open: () =>
            void start(`pr:${pull.number}`, {
              title: pull.title,
              // The head branch, not a new one: a track on a pull request is
              // work continued on the branch that pull request is already for.
              origin: { kind: "pr", base: pull.headRef, number: pull.number, title: pull.title },
            }),
        });
      }
    } else {
      for (const issue of issues ?? []) {
        out.push({
          key: `issue:${issue.number}`,
          icon: <Issue />,
          num: `#${issue.number}`,
          label: issue.title,
          meta: (
            <>
              {issue.labels.slice(0, 2).map((l) => (
                <span key={l} className="chip">
                  {l}
                </span>
              ))}
              {issue.author ? <span>{issue.author}</span> : null}
              <span>{ago(issue.updatedAt)}</span>
            </>
          ),
          hay: `${issue.title} ${issue.number} ${issue.author ?? ""}`.toLowerCase(),
          // No base: an issue names work, not a branch, so the track is cut
          // from the default branch like a blank one and carries the number.
          open: () =>
            void start(`issue:${issue.number}`, {
              title: issue.title,
              origin: { kind: "issue", number: issue.number, title: issue.title },
            }),
        });
      }
    }
    const needle = filter.trim().toLowerCase();
    return needle ? out.filter((r) => r.hay.includes(needle)) : out;
  }, [tab, branches, pulls, issues, filter, project.defaultBranch, opening]);

  // The selection follows the list rather than the other way round: filtering
  // to three rows must not leave the highlight on the fortieth.
  useEffect(() => {
    setAt(0);
  }, [tab, filter]);
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
      rows[cursor]?.open();
    }
  }

  return (
    <Dialog
      title="New track"
      onClose={onClose}
      footer={
        <>
          <span className="dimmer">
            {advanced ? <><kbd>↑</kbd> <kbd>↓</kbd> to move, <kbd>⏎</kbd> to open</> : <><kbd>⏎</kbd> to create</>}
          </span>
          <span className="spacer" />
          <span className="dimmer">{project.repo ?? "no repository"}</span>
        </>
      }
    >
      <form onSubmit={(event) => {
        event.preventDefault();
        if (name.trim()) void start("new", { title: name.trim(), origin: { kind: "blank" } });
      }}>
        <div className="dialog-body">
          <div className="field">
            <label htmlFor={nameId}>Track name</label>
            <input id={nameId} autoFocus value={name} maxLength={200} required
              disabled={!!opening} onFocus={(event) => event.currentTarget.select()}
              onChange={(event) => setName(event.target.value)} autoComplete="off" />
            <span className="hint">{project.repo
              ? `New worktree from ${project.defaultBranch || "the default branch"}.`
              : "Start a blank track."}</span>
          </div>
          {error ? <p className="fine error" role="alert">{error}</p> : null}
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <button type="button" className="btn" aria-expanded={advanced}
              disabled={!!opening} onClick={() => setAdvanced(!advanced)}>
              {advanced ? "Hide advanced" : "Advanced"}
            </button>
            <span className="spacer" />
            <button type="submit" className="btn primary" disabled={!!opening || !name.trim()}>
              {opening === "new" ? "Creating…" : "Create track"}
            </button>
          </div>
        </div>
      </form>
      {advanced ? <>
      <div className="tabs" role="group" aria-label="Where to start from">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            className={`tab${tab === t.id ? " on" : ""}`}
            aria-pressed={tab === t.id}
            disabled={!!opening || (t.id !== "branches" && !project.repo)}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="search-line" onKeyDown={onKeyDown}>
        <Search />
        <input
          autoFocus
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Filter by title, number or author"
          aria-label="Filter"
          role="combobox"
          aria-expanded
          aria-controls={listId}
          aria-activedescendant={rows.length ? `${listId}-${cursor}` : undefined}
          autoComplete="off"
        />
      </div>

      {/* The listbox holds options and nothing else — notices and empty states
          sit beside it, because a screen reader announcing "3 items" over a
          list containing a paragraph is counting the paragraph. */}
      <div className="dialog-body flush">
        {!project.repo && tab === "branches" ? (
          <p className="fine">This project has no repository, so a blank track is the only way in.</p>
        ) : null}
        {loading && !rows.length ? (
          <Empty icon={<Branch size={20} />} title="Reading the repository">
            Asking GitHub as the installation, which is what decides whether this repository is visible at all.
          </Empty>
        ) : null}
        {!loading && !rows.length ? (
          <Empty icon={<Branch size={20} />} title="Nothing matches">
            {filter.trim() ? `No ${tab === "pulls" ? "pull request" : tab === "issues" ? "issue" : "branch"} matches "${filter.trim()}".` : "There is nothing open here to start from."}
          </Empty>
        ) : null}
        <div id={listId} role="listbox" aria-label="Where to start from">
          {rows.map((row, i) => (
            <button
              key={row.key}
              id={`${listId}-${i}`}
              type="button"
              role="option"
              aria-selected={i === cursor}
              tabIndex={-1}
              className={`pick-row${i === cursor ? " on" : ""}`}
              disabled={!!opening}
              // Hovering moves the selection rather than lighting a second row:
              // one highlight means Enter is never ambiguous.
              onMouseEnter={() => setAt(i)}
              onClick={() => row.open()}
            >
              <span className="ico">{row.icon}</span>
              {row.num ? <span className="pick-num">{row.num}</span> : null}
              <span className="truncate">{row.label}</span>
              <span className="meta">
                {opening === row.key ? (
                  <span className="chip accent">Opening…</span>
                ) : (
                  <>
                    {row.meta}
                    {i === cursor ? (
                      <span>
                        Select <kbd>⏎</kbd>
                      </span>
                    ) : null}
                  </>
                )}
              </span>
            </button>
          ))}
        </div>
      </div>
      </> : null}
    </Dialog>
  );
}
