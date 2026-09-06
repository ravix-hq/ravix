import { expect, test } from "bun:test";
import type { CheckRun, ChecksReport } from "../../shared/api";
import { pullIndicator } from "./TrackPull";
const run = (conclusion: string | null, status = "completed"): CheckRun => ({ name: "CI", status, conclusion, url: null, startedAt: null, completedAt: null });
const report = (runs: CheckRun[] = []): ChecksReport => ({ ref: "branch", sha: "sha", pushed: true, runs, pull: { number: 42, title: "Change", author: null, headRef: "branch", baseRef: "main", draft: false, updatedAt: "", state: "open" } });
test("no PR has no indicator", () => expect(pullIndicator({ ...report(), pull: null })).toBeNull());
test("merged overrides failing CI, including a deleted branch", () => {
  const value = report([run("failure")]);
  value.pull!.state = "merged";
  value.pushed = false;
  expect(pullIndicator(value)).toEqual({ tone: "merged", label: "PR #42 · merged" });
});
test("closed remains red with passing CI", () => {
  const value = report([run("success")]); value.pull!.state = "closed";
  expect(pullIndicator(value)).toEqual({ tone: "failed", label: "PR #42 · closed · CI passed" });
});
test("draft and pending are described", () => {
  const value = report([run(null, "queued")]); value.pull!.draft = true;
  expect(pullIndicator(value)).toEqual({ tone: "unknown", label: "PR #42 · draft · CI pending" });
});
test.each([
  [[], "unknown"],
  [[run("success")], "passed"],
  [[run("success"), run(null, "in_progress")], "unknown"],
  [[run("failure"), run(null, "queued")], "failed"],
  [[run("cancelled")], "unknown"],
  [[run("skipped")], "unknown"],
  [[run("success"), run("skipped")], "passed"],
] as [CheckRun[], string][])("aggregates CI without treating missing results as success", (runs, tone) => {
  expect(pullIndicator(report(runs))?.tone).toBe(tone);
});
