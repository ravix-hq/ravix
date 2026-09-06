/**
 * Names, and the fact that a name here is load-bearing in four places at once.
 *
 * A track's slug is its directory on the machine, the tail of its branch, the
 * tail of its `channel_id`, and the thing a person reads in the sidebar. One
 * function makes it so the four cannot drift, and `parseChannel` is the
 * inverse — the server derives a track's identity from Fountain's own record
 * rather than trusting a row in its database to still be right.
 */

/** Every conversation switchyard owns starts with this. */
export const CHANNEL_PREFIX = "switchyard";

/** Where a project's repositories are cloned. Fountain's convention. */
export const WORKSPACE_ROOT = "/workspace";

/** Where a track's worktree lives. One directory per track, under here. */
export const WORK_ROOT = "/home/sprite/work";

/** Switchyard's corner of the machine — receipts, notes, nothing a person edits. */
export const STATE_DIR = "/home/sprite/.switchyard";

/**
 * A slug fit for a directory, a git branch and a URL at the same time.
 *
 * Git refuses a fair amount that a directory would take (`..`, a trailing
 * `.lock`, a leading dot), so the strict rule wins for all four uses rather
 * than each place having its own idea of what is legal.
 */
export function slugify(input: string, fallback = "track"): string {
  const base = input
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    .slice(0, 40)
    .replace(/-+$/, "");
  return base || fallback;
}

/** `switchyard:<project>` — the project's own conversations, if it ever has one. */
export function projectChannel(projectId: string): string {
  return `${CHANNEL_PREFIX}:${projectId}`;
}

/**
 * `switchyard:<project>:<track>@r<rev>` — a track's conversation.
 *
 * The revision is the project's settings revision at the moment the track
 * opened. Fountain injects secrets, MCP servers and skills when a session
 * starts, so a track that opened before a change is genuinely running older
 * settings; carrying the number in the id it already has means nothing is
 * stored to work that out and nothing can get it wrong. Paddock's trick,
 * unchanged.
 */
export function trackChannel(projectId: string, trackSlug: string, rev: number): string {
  return `${CHANNEL_PREFIX}:${projectId}:${trackSlug}@r${rev}`;
}

export interface ParsedChannel {
  projectId: string;
  trackSlug: string;
  rev: number;
}

/** The inverse. Null for anything that is not one of ours. */
export function parseChannel(channelId: string | null | undefined): ParsedChannel | null {
  if (!channelId) return null;
  const m = /^switchyard:([^:@]+):([^:@]+)@r(\d+)$/.exec(channelId);
  if (!m) return null;
  return { projectId: m[1]!, trackSlug: m[2]!, rev: Number(m[3]) };
}

/** Is this conversation part of the given project, whatever its revision? */
export function isProjectChannel(channelId: string | null | undefined, projectId: string): boolean {
  return parseChannel(channelId)?.projectId === projectId;
}

/** A track's working directory: `/home/sprite/work/<slug>`. */
export function workdirFor(slug: string): string {
  return `${WORK_ROOT}/${slug}`;
}

/**
 * A track's branch.
 *
 * Namespaced under the person who asked for it, the way a human would name a
 * branch they intend to push: `jhgaylor/kyoto-<track-id>`. The login comes from GitHub,
 * so it is the same name that will appear on the pull request.
 */
export function branchFor(login: string, slug: string, trackId: string): string {
  // Names can outlive the local branch and even the project database on GitHub.
  return `${slugify(login, "sy")}/${slug}-${trackId}`;
}

/** `/workspace/<name>` for `owner/name`. */
export function mountPathFor(repoFullName: string): string {
  const name = repoFullName.split("/").pop() ?? repoFullName;
  return `${WORKSPACE_ROOT}/${name}`;
}
