/**
 * GitHub's opinion of this track's branch.
 *
 * The panel has three honest answers and they are not variations of each
 * other. A branch that has never been pushed has no checks *and no problem* —
 * it is the ordinary state of a track five minutes old, so it gets a sentence
 * about pushing rather than an empty list that looks like everything failed. A
 * pushed commit with no runs is a repository with no workflow for this branch,
 * which is also not a failure. Only the third case is a list of results.
 *
 * The pull request sits at the top because it is the thing the checks are
 * about: once there is one, the row is the link somebody actually wants, and
 * until there is one, opening it is the next thing they were going to do.
 */
import { useEffect, useState } from "react";
import type { Capabilities, CheckRun, ChecksReport, Project, PullRef, Track } from "../../shared/api";
import { api } from "../lib/api";
import { Branch, Check, External, GitHub, Pull } from "../lib/icons";
import { Empty, NotConfigured } from "./Empty";
import { describe, useSlow } from "./Files";

export function Checks({ track, project, capabilities }: { track: Track; project: Project; capabilities: Capabilities }) {
  // Deliberately before any hook: with no App there is nothing to ask GitHub
  // and nothing to ask it with, so the panel is a statement rather than a
  // request that will fail.
  if (!capabilities.github) {
    return (
      <NotConfigured icon={<GitHub size={19} />} title="Checks need the GitHub App" variable="GITHUB_APP_ID">
        Checks are the status of this branch on GitHub — the workflows that ran against the commit the machine pushed, and the
        pull request they belong to.
      </NotConfigured>
    );
  }
  return <Report track={track} project={project} />;
}

function Report({ track, project }: { track: Track; project: Project }) {
  const [report, setReport] = useState<ChecksReport | null>(null);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);
  const slow = useSlow(loading && !report);

  useEffect(() => {
    let live = true;
    setLoading(true);
    api.checks(track.id).then(
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
  }, [track.id, nonce]);

  const refresh = () => setNonce((n) => n + 1);

  if (error) {
    return (
      <div style={{ padding: "10px 12px" }}>
        <p className="error">{error.message}</p>
        <button type="button" className="ghost" onClick={refresh}>
          Try again
        </button>
      </div>
    );
  }

  if (!report) return slow ? <p className="fine" style={{ padding: "10px 12px" }}>Asking GitHub about this branch…</p> : null;

  return (
    <div>
      <PullHeader track={track} project={project} pull={report.pull} pushed={report.pushed} onOpened={refresh} />

      {!report.pushed ? (
        <Empty
          icon={<Branch size={19} />}
          title="Nothing pushed yet"
          because={
            <>
              GitHub has never seen <code>{track.branch}</code>; so far it only exists on the machine.
            </>
          }
        >
          Checks run on GitHub, not here, so they appear once this branch is pushed. Ask the agent in this track to push it.
        </Empty>
      ) : report.runs.length === 0 ? (
        <Empty
          icon={<Check size={19} />}
          title="No check runs"
          because={report.sha ? <>Asked about <code>{report.sha.slice(0, 7)}</code>, the tip of <code>{track.branch}</code>.</> : null}
          action={{ label: "Check again", onClick: refresh }}
        >
          GitHub has this commit but reports no check runs against it — which is what a repository with no workflow for this
          branch looks like.
        </Empty>
      ) : (
        <>
          <div className="row" style={{ padding: "8px 12px" }}>
            <span className="dim">{summary(report.runs)}</span>
            <span className="spacer" />
            <button type="button" className="ghost" onClick={refresh} disabled={loading}>
              Refresh
            </button>
          </div>
          {report.runs.map((run, i) => (
            <div className="check-row" key={`${run.name}-${i}`}>
              <span className={`chip ${tone(run)}`}>{label(run)}</span>
              <span className="name truncate" title={run.name}>
                {run.name}
              </span>
              {run.url ? (
                <a href={run.url} target="_blank" rel="noreferrer" title="Open on GitHub" style={{ marginLeft: "auto" }}>
                  <External size={13} />
                </a>
              ) : null}
            </div>
          ))}
        </>
      )}
    </div>
  );
}

/**
 * The pull request, or the offer to open one.
 *
 * The button is only worth showing once the branch is on GitHub — offering to
 * open a pull request for a branch that has never been pushed is offering an
 * error message. The pull it opens is authored by the App rather than by the
 * person reading this, which is the honest attribution: a machine wrote the
 * branch, and the review is the point.
 */
function PullHeader({
  track,
  project,
  pull,
  pushed,
  onOpened,
}: {
  track: Track;
  project: Project;
  pull: PullRef | null;
  pushed: boolean;
  onOpened: () => void;
}) {
  const [opening, setOpening] = useState(false);
  const [opened, setOpened] = useState<(PullRef & { url: string }) | null>(null);
  const [error, setError] = useState<string | null>(null);
  const shown = opened ?? pull;

  async function open() {
    setOpening(true);
    setError(null);
    try {
      const made = await api.openPull(track.id, { title: track.title });
      setOpened(made);
      onOpened();
    } catch (err) {
      setError(describe(err).message);
    } finally {
      setOpening(false);
    }
  }

  if (shown) {
    const url = opened?.url ?? (project.repo ? `https://github.com/${project.repo}/pull/${shown.number}` : null);
    return (
      <div className="check-row">
        <span className="chip accent">
          <Pull size={12} /> #{shown.number}
        </span>
        <span className="name truncate" title={shown.title}>
          {shown.title}
        </span>
        {shown.draft ? <span className="chip">Draft</span> : null}
        {url ? (
          <a href={url} target="_blank" rel="noreferrer" title="Open on GitHub" style={{ marginLeft: "auto" }}>
            <External size={13} />
          </a>
        ) : null}
      </div>
    );
  }

  if (!pushed) return null;

  return (
    <>
      <div className="check-row">
        <span className="name dim">No pull request for this branch.</span>
        <button type="button" className="ghost" style={{ marginLeft: "auto" }} onClick={() => void open()} disabled={opening}>
          {opening ? "Opening…" : "Open a draft pull request"}
        </button>
      </div>
      {error ? (
        <p className="error" style={{ padding: "8px 12px 0" }}>
          {error}
        </p>
      ) : null}
    </>
  );
}

// ── how a run reads ────────────────────────────────────────────────────

/**
 * A run that has not finished has no conclusion, and colouring it by the
 * conclusion it does not have yet would show a grey "skipped" chip on a job
 * that is running. Status first, then conclusion.
 */
function tone(run: CheckRun): string {
  if (run.status !== "completed") return "warn";
  switch (run.conclusion) {
    case "success":
      return "ok";
    case "failure":
    case "timed_out":
    case "action_required":
      return "bad";
    default:
      return "";
  }
}

function label(run: CheckRun): string {
  if (run.status === "queued") return "Queued";
  if (run.status !== "completed") return "Running";
  switch (run.conclusion) {
    case "success":
      return "Passed";
    case "failure":
      return "Failed";
    case "timed_out":
      return "Timed out";
    case "action_required":
      return "Action required";
    case "cancelled":
      return "Cancelled";
    case "neutral":
      return "Neutral";
    case "skipped":
      return "Skipped";
    default:
      return run.conclusion ?? "No result";
  }
}

function summary(runs: CheckRun[]): string {
  const failed = runs.filter((r) => tone(r) === "bad").length;
  const running = runs.filter((r) => r.status !== "completed").length;
  const parts = [runs.length === 1 ? "1 check" : `${runs.length} checks`];
  if (failed) parts.push(`${failed} failing`);
  if (running) parts.push(`${running} still running`);
  return parts.join(", ");
}
