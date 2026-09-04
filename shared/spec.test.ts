import { expect, test } from "bun:test";
import { closeTrackPrompt, openTrackPrompt, starters, systemPrompt } from "./spec";

/**
 * These are tests of a *prompt*, which is an unusual thing to assert on. They
 * exist because the isolation between tracks is not enforced by the platform —
 * there is no chroot and no per-track permission. It is a rule the agent
 * follows, stated in the system prompt. So the sentences below are load-bearing
 * in the way a permission check would be in another app, and losing one in an
 * edit should fail a build rather than be discovered by two tracks committing
 * to the same branch.
 */

const withRepo = { project: "fountain", repoPath: "/workspace/fountain", defaultBranch: "main" };

test("the system prompt names the worktree rule, the shared clone and the neighbours", () => {
  const p = systemPrompt(withRepo);
  expect(p).toContain("/home/sprite/work");
  expect(p).toContain("Never edit, stage, commit or check out anything outside your own track's directory");
  // The shared clone is the thing a confused agent reaches for first.
  expect(p).toContain("/workspace/fountain is the shared clone");
  expect(p).toContain("never change");
  // And the other tracks are the thing it reaches for second.
  expect(p).toContain("belong to other tracks");
});

test("a project with no repository still gets the rule, without inventing a clone", () => {
  const p = systemPrompt({ project: "Scratch", repoPath: null, defaultBranch: null });
  expect(p).toContain("Never edit, stage, commit or check out anything outside your own track's directory");
  expect(p).not.toContain("shared clone");
  expect(p).not.toContain("git push");
});

test("the app's own turns are marked, so the transcript can render them as notes", () => {
  expect(openTrackPrompt({ slug: "kyoto", branch: "j/kyoto", repoPath: null, origin: { kind: "blank", base: null } })).toStartWith(
    "[switchyard]",
  );
  expect(closeTrackPrompt({ slug: "kyoto", repoPath: null, force: false })).toStartWith("[switchyard]");
  expect(systemPrompt(withRepo)).toContain('"[switchyard]"');
});

test("a blank track cuts a branch; a pull request checks out the one it is already for", () => {
  const blank = openTrackPrompt({
    slug: "kyoto",
    branch: "jhgaylor/kyoto",
    repoPath: "/workspace/fountain",
    origin: { kind: "blank", base: "main" },
  });
  expect(blank).toContain("git worktree add /home/sprite/work/kyoto -b jhgaylor/kyoto origin/main");

  const pr = openTrackPrompt({
    slug: "pr-1569",
    branch: "conversations-reapply",
    repoPath: "/workspace/fountain",
    origin: { kind: "pr", base: "conversations-reapply", number: 1569, title: "Conversations: reapply agent" },
  });
  // Cutting a *new* branch for an existing PR would put the work somewhere the
  // pull request cannot see it.
  expect(pr).toContain("git fetch origin pull/1569/head:conversations-reapply");
});

test("every branch of the opening turn has a fallback, because a worktree add is allowed to fail", () => {
  // No commits yet, or a directory left behind by a badly closed track. A track
  // that dies here is a track a person cannot use at all.
  for (const origin of [
    { kind: "blank" as const, base: "main" },
    { kind: "branch" as const, base: "feature/x" },
    { kind: "pr" as const, base: "feature/x", number: 12 },
  ]) {
    const p = openTrackPrompt({ slug: "s", branch: "b", repoPath: "/workspace/r", origin });
    expect(p).toContain("||");
  }
});

test("closing removes the worktree through git, and leaves the branch alone", () => {
  const p = closeTrackPrompt({ slug: "kyoto", repoPath: "/workspace/fountain", force: false });
  // `rm -rf` leaves the clone's administrative record behind, after which the
  // next track with the same name is refused for a reason nobody can see.
  expect(p).toContain("git worktree remove /home/sprite/work/kyoto");
  expect(p).toContain("git worktree prune");
  expect(p).toContain("Leave the branch alone");
  expect(p).not.toContain("branch -D");

  const forced = closeTrackPrompt({ slug: "kyoto", repoPath: "/workspace/fountain", force: true });
  expect(forced).toContain("git worktree remove --force");
});

test("the starters differ for a machine with no repository", () => {
  expect(starters({ hasRepo: true }).map((s) => s.label)).toContain("Review recent PRs");
  expect(starters({ hasRepo: false }).map((s) => s.label)).not.toContain("Review recent PRs");
  // A chip is a prompt, so pressing one must be indistinguishable from typing.
  for (const s of [...starters({ hasRepo: true }), ...starters({ hasRepo: false })]) {
    expect(s.prompt.length).toBeGreaterThan(s.label.length);
  }
});
