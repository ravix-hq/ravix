import { useEffect, useState } from "react";
import type { ChecksReport, Track } from "../../shared/api";
import { api } from "../lib/api";
import { Pull } from "../lib/icons";

export function pullIndicator(report: ChecksReport) {
  const pull = report.pull;
  if (!pull) return null;
  const state = pull.state ?? "open";
  const prefix = `PR #${pull.number} · ${state === "open" && pull.draft ? "draft" : state}`;
  if (state === "merged") return { tone: "merged", label: prefix };
  const failed = report.runs.some(run => run.status === "completed" && ["failure", "timed_out", "action_required", "startup_failure"].includes(run.conclusion ?? ""));
  const pending = report.runs.some(run => run.status !== "completed");
  const passed = report.runs.length > 0 && report.runs.every(run => run.status === "completed" && ["success", "neutral", "skipped"].includes(run.conclusion ?? "")) && report.runs.some(run => run.conclusion === "success");
  const ci = failed ? "CI failed" : pending ? "CI pending" : passed ? "CI passed" : report.runs.length ? "CI has no passing result" : "No CI results";
  return { tone: state === "closed" || failed ? "failed" : passed ? "passed" : "unknown", label: `${prefix} · ${ci}` };
}

/** Refresh while visible, and after a turn or a return to the tab. */
export function TrackPull({ track }: { track: Track }) {
  const [result, setResult] = useState<{ report: ChecksReport | null; failed: boolean }>({ report: null, failed: false });
  useEffect(() => {
    let live = true;
    let pending = false;
    const refresh = async () => {
      if (pending || document.hidden) return;
      pending = true;
      try {
        const report = await api.checks(track.id);
        if (live) setResult({ report, failed: false });
      } catch {
        if (live) setResult(previous => ({ ...previous, failed: true }));
      } finally {
        pending = false;
      }
    };
    void refresh();
    const interval = window.setInterval(() => void refresh(), 5 * 60_000);
    document.addEventListener("visibilitychange", refresh);
    return () => { live = false; window.clearInterval(interval); document.removeEventListener("visibilitychange", refresh); };
  }, [track.id, track.branch, track.status]);

  const indicator = result.failed
    ? { tone: "unknown", label: "PR / CI status unavailable" }
    : result.report ? pullIndicator(result.report) : null;
  if (!indicator) return null;
  return <span className={`track-pull ${indicator.tone}`} role="img" aria-label={indicator.label} title={indicator.label}><Pull size={15} /></span>;
}
