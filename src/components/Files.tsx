/**
 * The track's worktree, as an editor shows one: a tree you expand in place,
 * and the file you picked in front of it.
 *
 * Rooted at `track.workdir` rather than at the machine's `/`, because a track
 * *is* a directory — the server confines every path to it anyway, so a tree
 * that offered to walk out of the worktree would only be offering to be
 * refused. Directories stay open once opened and siblings stay visible: a
 * panel that replaces its listing on every step can tell you what is in a
 * directory but never where you are, which is the thing a tree is for.
 *
 * Nothing here writes. Fountain has no way to change a machine from outside,
 * so the way to change a file is to ask for it in the track.
 */
import { useCallback, useEffect, useState } from "react";
import type { FileContent, FileEntry, Track } from "../../shared/api";
import { ApiError, api } from "../lib/api";
import { Chevron, File as FileMark, Folder, Machine } from "../lib/icons";
import { Empty } from "./Empty";

// ── two things the three inspector panels share ────────────────────────

/**
 * Whether a load has been slow enough to be worth admitting to.
 *
 * Most of these calls come back in well under a frame's worth of attention,
 * and a spinner that appears and vanishes inside 150ms reads as a flicker
 * rather than as progress — it makes a fast app look unwell. So the panels
 * show nothing at all until this says otherwise.
 */
export function useSlow(loading: boolean, after = 150): boolean {
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    if (!loading) {
      setSlow(false);
      return;
    }
    const timer = setTimeout(() => setSlow(true), after);
    return () => clearTimeout(timer);
  }, [loading, after]);
  return slow;
}

/**
 * Anything thrown by `api`, as something with a code and a sentence.
 *
 * Every failure the server produces arrives as an `ApiError` whose message was
 * written to be read by a person, so the panels print it verbatim. The one
 * thing that is not an `ApiError` is `fetch` itself giving up — no server, no
 * network — and that deserves its own sentence rather than a stack trace.
 *
 * This and `useSlow` live in the first panel that needed them rather than in a
 * module of their own: a hook and a four-line shim do not earn a file, and
 * putting them in `Inspector.tsx` would make the panel and its tabs import
 * each other.
 */
export function describe(err: unknown): { code: string; message: string } {
  if (err instanceof ApiError) return { code: err.code, message: err.message };
  return { code: "unreachable", message: "The server did not answer. Check your connection and try again." };
}

// ── the panel ──────────────────────────────────────────────────────────

interface Dir {
  entries: FileEntry[];
  truncated: boolean;
}

export function Files({ track }: { track: Track }) {
  const root = track.workdir;
  const [dirs, setDirs] = useState<Record<string, Dir>>({});
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState<Record<string, boolean>>({});
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [file, setFile] = useState<FileContent | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);

  const load = useCallback(
    async (path: string) => {
      setBusy((m) => ({ ...m, [path]: true }));
      try {
        const listing = await api.files(track.id, path);
        setDirs((m) => ({ ...m, [path]: { entries: sorted(listing.entries), truncated: listing.truncated } }));
        setError(null);
      } catch (err) {
        setError(describe(err));
      } finally {
        setBusy((m) => ({ ...m, [path]: false }));
      }
    },
    [track.id],
  );

  // The worktree root opens open. A tree that starts closed makes you click
  // once before it has told you anything, and there is only ever one root.
  useEffect(() => {
    setDirs({});
    setOpen({ [root]: true });
    setBusy({});
    setError(null);
    setSelected(null);
    setFile(null);
    setFileError(null);
    void load(root);
  }, [root, load]);

  const slow = useSlow(!!busy[root] && !dirs[root]);

  function toggle(path: string) {
    const next = !open[path];
    setOpen((m) => ({ ...m, [path]: next }));
    if (next && !dirs[path]) void load(path);
  }

  async function show(path: string) {
    setSelected(path);
    setFileError(null);
    setFile(null);
    try {
      setFile(await api.file(track.id, path));
    } catch (err) {
      setFileError(describe(err).message);
    }
  }

  // The machine is the one failure worth its own surface: it is not an error
  // the person made, it is a machine that has not finished starting, and the
  // panel comes back on its own once it has.
  if (error?.code === "no_machine") {
    return (
      <Empty icon={<Machine size={19} />} title="No machine yet" because={error.message}>
        A track's files live on the project's machine. Open a track to bring one up, or wait for the one that is already
        starting.
      </Empty>
    );
  }

  // A worktree that does not exist yet is the ordinary first ten seconds of a
  // track, not a failure — the opening turn is still cutting it. Fountain
  // answers `path_not_found` with no message of its own, which is how the raw
  // code ended up rendered as the panel's whole content.
  if (error?.code === "path_not_found" || error?.code === "github_not_found") {
    return (
      <Empty icon={<Folder size={19} />} title={track.status === "opening" ? "Not cut yet" : "That directory is gone"}>
        {track.status === "opening" ? (
          <>
            The machine is still making <code>{root}</code>. It appears here the moment the opening turn lands — you can
            watch it happen in the transcript.
          </>
        ) : (
          <>
            <code>{root}</code> is not on the machine. It may have been removed by hand, or lost with a rebuild; closing
            this track and starting another gives you a fresh worktree.
          </>
        )}
      </Empty>
    );
  }

  if (file || fileError) {
    return (
      <div className="file-view">
        <header>
          <button
            type="button"
            className="ghost"
            onClick={() => {
              setFile(null);
              setFileError(null);
              setSelected(null);
            }}
          >
            <Chevron size={13} style={{ transform: "rotate(180deg)" }} /> Files
          </button>
          <span className="truncate dim">{relative(root, selected ?? "")}</span>
          {file ? <span className="dimmer">{bytes(file.size)}</span> : null}
        </header>
        {fileError ? <p className="error" style={{ padding: "10px 12px" }}>{fileError}</p> : null}
        {file && !isText(file.encoding) ? (
          <p className="fine" style={{ padding: "10px 12px" }}>
            This file is not text — the machine sent it as <code>{file.encoding}</code>, {bytes(file.size)} of it. Showing the
            bytes as characters would be a lie about what is in it, so the panel does not.
          </p>
        ) : null}
        {file && isText(file.encoding) ? <pre className="file-body">{file.content}</pre> : null}
        {file?.truncated ? <p className="fine" style={{ padding: "0 12px 10px" }}>The server stopped reading part way through this file. What is above is the beginning of it.</p> : null}
      </div>
    );
  }

  return (
    <div className="tree">
      {error ? <p className="error" style={{ padding: "4px 8px" }}>{error.message}</p> : null}
      {slow ? <p className="fine" style={{ padding: "4px 8px" }}>Reading the worktree…</p> : null}
      <Node
        path={root}
        name={root.split("/").filter(Boolean).pop() ?? "/"}
        depth={0}
        dirs={dirs}
        open={open}
        busy={busy}
        selected={selected}
        onToggle={toggle}
        onOpen={(p) => void show(p)}
      />
    </div>
  );
}

function Node({
  path,
  name,
  depth,
  dirs,
  open,
  busy,
  selected,
  onToggle,
  onOpen,
}: {
  path: string;
  name: string;
  depth: number;
  dirs: Record<string, Dir>;
  open: Record<string, boolean>;
  busy: Record<string, boolean>;
  selected: string | null;
  onToggle: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  const isOpen = !!open[path];
  const loaded = dirs[path];
  const pad = (d: number) => ({ paddingLeft: d * 12 + 8 });

  return (
    <>
      <button type="button" className="tree-row" style={pad(depth)} onClick={() => onToggle(path)} title={path}>
        <span className="ico">
          <Chevron size={12} open={isOpen} />
        </span>
        <span className="ico">
          <Folder size={13} />
        </span>
        <span className="truncate">{name}</span>
        {busy[path] ? <span className="size">…</span> : null}
      </button>

      {isOpen && loaded
        ? loaded.entries.map((entry) => {
            const child = join(path, entry.name);
            if (entry.type === "directory") {
              return (
                <Node
                  key={child}
                  path={child}
                  name={entry.name}
                  depth={depth + 1}
                  dirs={dirs}
                  open={open}
                  busy={busy}
                  selected={selected}
                  onToggle={onToggle}
                  onOpen={onOpen}
                />
              );
            }
            // Sockets, devices and dangling symlinks list, because they are
            // genuinely there, but they are not files to open and the row says
            // so instead of failing when you click it.
            const openable = entry.type === "file";
            const trailing = entry.size !== null ? bytes(entry.size) : openable ? "" : entry.type;
            return (
              <button
                key={child}
                type="button"
                className={`tree-row${selected === child ? " on" : ""}`}
                style={pad(depth + 1)}
                disabled={!openable}
                onClick={() => onOpen(child)}
                title={openable ? child : `${child} — ${entry.type}`}
              >
                <span className="ico" />
                <span className="ico">
                  <FileMark size={13} />
                </span>
                <span className="truncate">{entry.name}</span>
                <span className="size">{trailing}</span>
              </button>
            );
          })
        : null}

      {isOpen && loaded?.entries.length === 0 ? (
        <div className="tree-row" style={pad(depth + 1)}>
          <span className="dimmer">empty</span>
        </div>
      ) : null}

      {isOpen && loaded?.truncated ? (
        <div className="tree-row" style={pad(depth + 1)}>
          <span className="dimmer">…the server stopped listing here</span>
        </div>
      ) : null}
    </>
  );
}

// ── small things ───────────────────────────────────────────────────────

/**
 * Directories first, then by name.
 *
 * Not the order the machine returns, which is whatever the filesystem felt
 * like: a tree is read by scanning down it, and scanning is only possible when
 * the folders are one block at the top.
 */
function sorted(entries: FileEntry[]): FileEntry[] {
  return [...entries].sort((a, b) => {
    const dirs = Number(b.type === "directory") - Number(a.type === "directory");
    return dirs || a.name.localeCompare(b.name);
  });
}

function join(dir: string, name: string): string {
  return dir.endsWith("/") ? `${dir}${name}` : `${dir}/${name}`;
}

function relative(root: string, path: string): string {
  return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : path;
}

/**
 * Fountain sends `utf8` for text and `base64` for everything else. The
 * normalising is defensive rather than known-necessary: getting it wrong in
 * that direction would call a perfectly readable file binary.
 */
function isText(encoding: string): boolean {
  return encoding.toLowerCase().replace(/-/g, "") === "utf8";
}

function bytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
