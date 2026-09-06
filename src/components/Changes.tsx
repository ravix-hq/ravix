/**
 * What the agent has actually done to the worktree, which is the one question
 * a person asks of a track they did not watch.
 *
 * The server has already counted the diff per file, so the list of changed
 * files is there before a single hunk is parsed and the panel can render its
 * shape immediately. The hunks are cut out of the raw unified diff on demand,
 * once, and only for the files somebody opened — a thousand-line diff is a
 * cheap string to hold and an expensive one to turn into a thousand DOM nodes.
 *
 * The load itself is a hook rather than something this component owns, because
 * the tab strip above it shows the number of changed files and cannot get that
 * number from a component it has not mounted. See `Inspector`.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import type { DiffFile, DiffReport } from "../../shared/api";
import { api } from "../lib/api";
import { Chevron, Machine, Sparkle } from "../lib/icons";
import { Empty } from "./Empty";
import { describe, useSlow } from "./Files";

export interface DiffLoad {
  report: DiffReport | null;
  error: { code: string; message: string } | null;
  loading: boolean;
  reload: () => void;
  wake: () => void;
}

export function useDiff(trackId: string): DiffLoad {
  const [report, setReport] = useState<DiffReport | null>(null);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [request, setRequest] = useState({ nonce: 0, wake: false, trackId });

  const consumedWake = useRef(0);

  useEffect(() => {
    // A track can be switched while its diff is in flight, and the answer to
    // the old question must not be shown against the new track.
    let live = true;
    setLoading(true);
    setError(null);
    const shouldWake = request.trackId === trackId && request.wake && consumedWake.current !== request.nonce;
    if (shouldWake) consumedWake.current = request.nonce;
    api.diff(trackId, shouldWake).then(
      (next) => {
        if (!live) return;
        setReport(next);
        setError(null);
        setLoading(false);
      },
      (err) => {
        if (!live) return;
        setReport(null);
        setError(describe(err));
        setLoading(false);
      },
    );
    return () => {
      live = false;
    };
  }, [trackId, request]);

  return { report, error, loading,
    reload: () => setRequest((r) => ({ nonce: r.nonce + 1, wake: false, trackId })),
    wake: () => setRequest((r) => ({ nonce: r.nonce + 1, wake: true, trackId })),
  };
}

export function Changes({ diff }: { diff: DiffLoad }) {
  const { report, error, loading, reload, wake } = diff;
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const slow = useSlow(loading && !report);
  const hunks = useMemo(() => splitDiff(report?.diff ?? ""), [report?.diff]);

  if (error?.code === "no_machine") {
    return (
      <Empty icon={<Machine size={19} />} title="No machine yet" because={error.message}>
        The diff is <code>git diff</code> run in this track's worktree, and there is no machine to run it on yet. Open a track
        to bring one up, or wait for the one that is starting.
      </Empty>
    );
  }

  if (error?.code === "machine_asleep" || error?.code === "machine_starting") {
    return <Empty icon={<Machine size={19} />} title={error.code === "machine_asleep" ? "Wake the machine to see changes" : "The machine is starting"}
      action={{ label: error.code === "machine_asleep" ? "Wake with agent" : "Try again", onClick: error.code === "machine_asleep" ? wake : reload }}>
      {error.message}
    </Empty>;
  }

  if (error) {
    return (
      <div style={{ padding: "10px 12px" }}>
        <p className="error">{error.message}</p>
        <button type="button" className="ghost" onClick={reload}>
          Try again
        </button>
      </div>
    );
  }

  if (!report) return slow ? <p className="fine" style={{ padding: "10px 12px" }}>Running git diff on the machine…</p> : null;

  if (report.files.length === 0) {
    return (
      <Empty
        icon={<Sparkle size={19} />}
        title="The worktree is clean"
        because={
          <>
            <code>git diff</code> in <code>{report.repoRoot}</code> came back empty.
          </>
        }
        action={{ label: "Check again", onClick: reload }}
      >
        Nothing has been changed on this branch yet. Files the agent writes show up here as it works, one row each.
      </Empty>
    );
  }

  return (
    <div className="diff">
      <div className="row" style={{ padding: "8px 10px" }}>
        <span className="dim">{count(report.files)}</span>
        <span className="spacer" />
        <button type="button" className="ghost" onClick={reload} disabled={loading}>
          Refresh
        </button>
      </div>

      {report.files.map((file) => {
        const isOpen = !!open[file.path];
        const lines = hunks.get(file.path);
        return (
          <div className="diff-file" key={file.path}>
            <button
              type="button"
              className="diff-file-head"
              onClick={() => setOpen((m) => ({ ...m, [file.path]: !m[file.path] }))}
              title={file.path}
            >
              <Chevron size={13} open={isOpen} />
              <span className="truncate">{file.path}</span>
              {file.status === "modified" ? null : <span className="dimmer">{file.status}</span>}
              <span className="diff-stat">
                <span className="add">+{file.added}</span>
                <span className="del">-{file.removed}</span>
              </span>
            </button>

            {isOpen && lines ? (
              <pre className="diff-hunk">
                {lines.map((line, i) => (
                  <span key={i} className={`diff-line ${classOf(line)}`}>
                    {line}
                    {"\n"}
                  </span>
                ))}
              </pre>
            ) : null}

            {isOpen && !lines ? (
              <p className="fine" style={{ padding: "6px 10px" }}>
                The diff was cut off before this file, so its lines are not here. The counts above come from the part that did
                arrive.
              </p>
            ) : null}
          </div>
        );
      })}

      {report.truncated ? (
        <p className="fine" style={{ padding: "8px 10px" }}>
          The machine stopped sending part way through this diff. Everything above is real; there may be more below it.
        </p>
      ) : null}
    </div>
  );
}

// ── reading a unified diff ─────────────────────────────────────────────

/**
 * The raw diff, cut into one array of lines per file.
 *
 * Everything before the first `@@` of a file is git's preamble — the mode, the
 * index hashes, the `---`/`+++` pair — and none of it tells a reader anything
 * the row above the hunk has not already said. A section with no `@@` at all
 * is kept whole, because that is what a binary file's "differ" line looks like
 * and dropping it would show an expanded file with nothing in it.
 */
function splitDiff(raw: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let lines: string[] | null = null;
  let started = false;

  for (const line of raw.split("\n")) {
    const header = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
    if (header) {
      lines = [];
      started = false;
      out.set(header[2]!, lines);
      continue;
    }
    if (!lines) continue;
    if (line.startsWith("@@")) started = true;
    if (started || !isPreamble(line)) lines.push(line);
  }

  // Trailing newline in the payload, not a line of the last file.
  for (const [path, body] of out) {
    if (body.at(-1) === "") out.set(path, body.slice(0, -1));
  }
  return out;
}

function isPreamble(line: string): boolean {
  return (
    line.startsWith("index ") ||
    line.startsWith("--- ") ||
    line.startsWith("+++ ") ||
    line.startsWith("old mode") ||
    line.startsWith("new mode") ||
    line.startsWith("new file") ||
    line.startsWith("deleted file") ||
    line.startsWith("similarity index") ||
    line.startsWith("rename ")
  );
}

function classOf(line: string): string {
  if (line.startsWith("@@")) return "meta";
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "del";
  if (line.startsWith("\\")) return "meta";
  return "";
}

function count(files: DiffFile[]): string {
  const added = files.reduce((n, f) => n + f.added, 0);
  const removed = files.reduce((n, f) => n + f.removed, 0);
  const what = files.length === 1 ? "1 file" : `${files.length} files`;
  return `${what} changed, +${added} -${removed}`;
}
