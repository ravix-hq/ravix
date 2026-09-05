/**
 * The prompt contract: what switchyard asks the machine to do, and how the
 * machine reports back. Per-app on purpose — this and `protocol.ts` are the
 * two files the demo suite never shares, because they *are* the product.
 *
 * Switchyard's whole shape follows from one fact and one wish.
 *
 * The fact: a project is **one machine**. Fountain builds a sandbox from an
 * identity — `(user, agent, environment, vault)` by id — so a project that
 * keeps one agent, one environment and one vault gets one persistent box that
 * every conversation on it attaches to. Change any of those ids and the disk
 * is gone.
 *
 * The wish: several pieces of work at once, on that one machine, without them
 * treading on each other. Which is exactly what `git worktree` is for. So a
 * track is a worktree, and the agent must never be tempted to `cd` somewhere
 * else and start editing the shared clone.
 *
 * "Must never be tempted" is doing real work in that sentence. There is no
 * chroot here and no per-track permission — the isolation is a rule the agent
 * follows. So the rule is stated in three places that reinforce each other:
 * the system prompt (every turn), the track's opening turn (where the worktree
 * is actually made), and the header of every prompt switchyard sends itself.
 * Saying it once and hoping is how two tracks end up committing to the same
 * branch.
 */
import { STATE_DIR, WORKSPACE_ROOT, WORK_ROOT, workdirFor } from "./ids";

/** What the machine writes to say what it did. Read with `GET /api/sandboxes/:id/file`. */
export const RECEIPT_PATH = `${STATE_DIR}/tracks.json`;

/**
 * The system prompt for a project's agent.
 *
 * It is the only mechanism switchyard has for keeping tracks apart, so it
 * spends its length on that and on nothing else. Everything the app could
 * instead put in a per-turn preamble is here, because a system prompt is on
 * every turn including the ones a person types in a hurry.
 */
export function systemPrompt(input: { project: string; repoPath: string | null; defaultBranch: string | null }): string {
  const lines = [
    `You are the coding agent on the switchyard machine for the project "${input.project}".`,
    "",
    "## The one rule",
    "",
    `Every piece of work happens in its own git worktree under ${WORK_ROOT}. Each`,
    "conversation you are in — switchyard calls it a *track* — owns exactly one of those",
    "directories, and its first turn tells you which. That directory is your working",
    "directory for the whole of that conversation.",
    "",
    "Never edit, stage, commit or check out anything outside your own track's directory.",
    "In particular:",
    "",
  ];
  if (input.repoPath) {
    lines.push(
      `  - ${input.repoPath} is the shared clone. It is the source the worktrees come from.`,
      "    Read it if you must; do not modify it, do not commit in it, and never change",
      "    the branch it has checked out. Another track is using it.",
    );
  }
  lines.push(
    `  - Other directories under ${WORK_ROOT} belong to other tracks, running right now.`,
    "    Do not read from them to \"check something\" and never write to them.",
    "",
    "If a request would take you outside your track's directory, say so and ask, rather",
    "than doing it. A track that quietly edits another track's branch is the one failure",
    "this machine cannot recover from.",
    "",
    "## What is true of this machine",
    "",
    "It persists. The disk is the same one next time, for every track. It runs one turn",
    "at a time across all tracks, because it is one computer — if you are asked why a",
    "track is waiting, that is why.",
    "",
  );
  if (input.repoPath) {
    lines.push(
      `Git is configured for pushing: the remote carries a credential switchyard supplies`,
      "and re-mints before each turn, so `git push -u origin <your branch>` works. Push",
      "when the person asks and not before. Open pull requests with `gh` if it is present,",
      "otherwise say what you would open and let switchyard do it.",
      "",
    );
    if (input.defaultBranch) {
      lines.push(`The trunk is \`${input.defaultBranch}\`. Branch from it and merge back to it.`, "");
    }
  }
  lines.push(
    "## Live previews",
    "",
    "Switchyard can provide a track-scoped preview helper in the turn's instructions.",
    "When asked to configure or run a live preview, use that helper to save the app",
    "directory, startup command and readiness path, then start it and inspect status",
    "and logs. The command must use $PORT and fail on a port collision. Keep the",
    "preview on this track's working copy. Tell the user to use Open preview after",
    "readiness passes. Do not ask for their browser session or provider credentials.",
    "",
    "## How to answer",
    "",
    "Be concise. This is rendered in a terminal-shaped panel, not a document. Prefer",
    "doing the thing to describing the thing. No summaries of what you are about to do,",
    "no recap afterwards unless it is genuinely non-obvious.",
    "",
    `Turns whose first line starts with "[switchyard]" come from the app itself rather`,
    "than a person. Follow those exactly, including any strings they ask you to write",
    "back verbatim.",
  );
  return lines.join("\n");
}

export interface TrackOrigin {
  /** How this track was started, in the words the header will use. */
  kind: "branch" | "pr" | "issue" | "blank";
  /** The base ref to branch from: `main`, `origin/feature/x`, a PR head ref. */
  base: string | null;
  /** A PR number or issue number, when there is one. */
  number?: number | null;
  /** The PR/issue title, for the opening turn's context. */
  title?: string | null;
}

/**
 * A track's opening turn: cut the worktree, then say where you are.
 *
 * This is a real turn rather than something the server does over exec, and
 * that is deliberate on two counts. It works on a Fountain with no Sprites
 * token, which is the configuration switchyard must always run in. And the
 * first thing a person sees in a new track is the machine actually making
 * their branch, in the scrollback, which is the product.
 *
 * The fallbacks matter more than they look. A repository with no commits has
 * no ref to branch from; a directory left behind by a track that was closed
 * badly will refuse the add. Both are ordinary, and a track that dies at
 * `git worktree add` is a track a person cannot use at all — so it degrades
 * to a plain directory and says which one it got.
 */
export function openTrackPrompt(input: {
  slug: string;
  branch: string;
  repoPath: string | null;
  origin: TrackOrigin;
}): string {
  const dir = workdirFor(input.slug);
  const lines = [
    "[switchyard] Open this track. Make its working directory, then stop.",
    "",
  ];

  if (!input.repoPath) {
    lines.push(
      `This project has no repository yet, so the track is a plain directory:`,
      "",
      `  mkdir -p ${dir} && cd ${dir}`,
      "",
      "Reply with exactly one line: the working directory. Nothing else.",
    );
    return lines.join("\n");
  }

  const base = input.origin.base;
  lines.push(
    `The shared clone is ${input.repoPath}. Give this track its own worktree so it can`,
    "hold a branch without disturbing the tracks already running:",
    "",
    `  cd ${input.repoPath}`,
    "  git fetch origin --prune",
  );

  if (input.origin.kind === "pr" && input.origin.number != null) {
    lines.push(
      "",
      `This track continues pull request #${input.origin.number}. Check out its head rather than`,
      "cutting a new branch — the work belongs on the branch the PR is already for:",
      "",
      `  git fetch origin pull/${input.origin.number}/head:${input.branch} 2>/dev/null \\`,
      `    && git worktree add ${dir} ${input.branch} \\`,
      `    || git worktree add ${dir} -b ${input.branch} ${base ? `origin/${base}` : "HEAD"}`,
    );
  } else if (input.origin.kind === "branch" && base) {
    lines.push(
      "",
      `This track continues the existing branch \`${base}\`:`,
      "",
      `  git worktree add ${dir} -b ${input.branch} origin/${base} 2>/dev/null \\`,
      `    || git worktree add ${dir} ${base} 2>/dev/null \\`,
      `    || git worktree add ${dir} -b ${input.branch}`,
    );
  } else {
    lines.push(
      "",
      `Cut a new branch \`${input.branch}\`${base ? ` from \`origin/${base}\`` : ""}:`,
      "",
      `  git worktree add ${dir} -b ${input.branch}${base ? ` origin/${base}` : ""} 2>/dev/null \\`,
      `    || git worktree add ${dir} -b ${input.branch} \\`,
      `    || mkdir -p ${dir}`,
    );
  }

  lines.push(
    "",
    `Then \`cd ${dir}\` — that is your working directory for every turn in this track.`,
  );

  if (input.origin.kind === "issue" && input.origin.number != null) {
    lines.push(
      "",
      `This track exists to work on issue #${input.origin.number}${input.origin.title ? `, "${input.origin.title}"` : ""}. Do not start`,
      "on it yet; the person will say what they want first.",
    );
  }

  lines.push(
    "",
    "Reply with exactly one line: the working directory and the branch it is on, or a",
    "plain directory and why the worktree could not be made. No preamble, no summary,",
    "no next steps, no offer to begin.",
  );
  return lines.join("\n");
}

/**
 * The turn that closes a track: take the worktree away.
 *
 * `git worktree remove` rather than `rm -rf`, because the shared clone keeps
 * an administrative record of every worktree it cut and a directory deleted
 * from underneath it leaves that record behind — after which the *next* track
 * with the same name is refused.
 *
 * The branch is left alone unless somebody ticks the box. That default is the
 * important half: closing a track is a tab shut, and a gesture that quietly
 * deleted a branch — pushed, reviewed, possibly someone else's open pull
 * request — would be the most expensive undo in the app. When the box *is*
 * ticked it goes properly, locally and on the remote, because a branch deleted
 * in one place and left in the other is the worst of both.
 */
export function closeTrackPrompt(input: { slug: string; repoPath: string | null; force: boolean; deleteBranch?: string | null }): string {
  const dir = workdirFor(input.slug);
  if (!input.repoPath) {
    return [
      "[switchyard] Close this track. Remove its working directory, then stop.",
      "",
      `  rm -rf ${dir}`,
      "",
      "Reply with one line saying whether it went.",
    ].join("\n");
  }
  return [
    "[switchyard] Close this track. Remove its worktree, then stop.",
    "",
    `  cd ${input.repoPath}`,
    `  git worktree remove ${input.force ? "--force " : ""}${dir}`,
    "  git worktree prune",
    "",
    input.deleteBranch
      ? `Then delete the branch \`${input.deleteBranch}\` — this close was asked for with the branch, so:\n\n  git branch -D ${input.deleteBranch}\n  git push origin --delete ${input.deleteBranch} 2>/dev/null || true\n\nThe push may fail because the branch was never pushed; that is fine and not worth reporting as an error.`
      : "Leave the branch alone — it may be pushed, and it is not this turn's business.",
    input.force
      ? "This is a forced close: uncommitted changes in that worktree are being discarded on purpose."
      : "If the worktree has uncommitted changes, stop and say so instead of forcing it.",
    "",
    "Reply with one line saying what happened.",
  ].join("\n");
}

/**
 * Ask the machine what its tracks actually look like.
 *
 * Switchyard's database says which tracks it *believes* exist. This asks the
 * box, and the two disagreeing is ordinary rather than exceptional: a rebuild,
 * a worktree a person removed by hand in the terminal, a branch pushed and
 * deleted. The panel shows what the machine said, not what the row claimed.
 */
export function surveyPrompt(): string {
  return [
    "[switchyard] Report what is on this machine. Change nothing.",
    "",
    `  cd ${WORKSPACE_ROOT} 2>/dev/null && ls -1`,
    "  git --git-dir=*/.git worktree list 2>/dev/null || true",
    "",
    `Then write ${RECEIPT_PATH} (mkdir -p ${STATE_DIR} first). JSON, exactly this shape:`,
    "",
    "  {",
    '    "surveyed_at": "<ISO 8601 UTC, now>",',
    '    "repos": ["<absolute path of each clone under /workspace>"],',
    '    "worktrees": [{"path": "<absolute>", "branch": "<branch or null>", "dirty": <true|false>}]',
    "  }",
    "",
    "Then reply with one line per worktree: its path and branch. Nothing else.",
  ].join("\n");
}

/**
 * The suggestion chips under an empty track.
 *
 * They are prompts rather than features: each one is a thing a person would
 * have typed, so pressing one is indistinguishable from typing it. Which is
 * why they are here in the contract file and not in a component — changing
 * what a chip says changes what the agent is asked.
 */
export function starters(input: { hasRepo: boolean }): { label: string; prompt: string }[] {
  if (!input.hasRepo) {
    return [
      { label: "What is on this machine?", prompt: "Show me what is installed on this machine and what you can do here." },
      { label: "Set up a project", prompt: "Help me start a project in this directory. Ask me what I want before scaffolding anything." },
    ];
  }
  return [
    { label: "Set up live preview", prompt: "Set up a live preview for this track. Inspect the app, configure its startup command and readiness path with the Switchyard preview helper, start it, and fix any startup issues until it is Ready." },
    { label: "Review recent PRs", prompt: "Look at the pull requests merged into this repository in the last two weeks and tell me what changed, in the order that matters." },
    { label: "Improve agent instructions", prompt: "Read this repository's agent instructions (CLAUDE.md, AGENTS.md, .cursorrules — whichever exist) and suggest concrete improvements based on what the code actually looks like. Show me a diff before writing anything." },
    { label: "Fix a TODO", prompt: "Find the most worthwhile TODO or FIXME in this repository, explain why it is the one worth doing, and fix it." },
    { label: "Explain the architecture", prompt: "Walk me through how this repository is put together — the entry points, the boundaries, and anything a newcomer would get wrong." },
  ];
}
