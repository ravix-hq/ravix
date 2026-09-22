/**
 * The four facts the local mock shares with the app.
 *
 * `lib/ravix/ids.ex` and `lib/ravix/spec.ex` own these; this file is a copy
 * kept for `mock/server.ts`, which runs under bun and cannot call Elixir.
 * `test/ravix/mock_contract_test.exs` reads this file and fails if either
 * side moves, so the copy cannot go quietly stale.
 *
 * Nothing else belongs here. The prompt contract, the slug rules and the
 * channel builders live in Elixir, because that is what is deployed; a
 * second copy of them in TypeScript is a second thing to be wrong.
 */

/** `Ravix.Ids.workspace_root/0` — where a project's repositories are cloned. */
export const WORKSPACE_ROOT = "/workspace";

/** `Ravix.Ids.work_root/0` — where a track's worktree lives. */
export const WORK_ROOT = "/home/sprite/work";

/** `Ravix.Spec.receipt_path/0` — what the machine writes to say what it did. */
export const RECEIPT_PATH = "/home/sprite/.ravix/tracks.json";

/** `Ravix.Ids.channel_pattern/0` — the shape of a track's `channel_id`. */
export const CHANNEL_PATTERN = /^ravix:([^:@]+):([^:@]+)@r(\d+)(?::([^:@]+))?$/;

export interface ParsedChannel {
  projectId: string;
  trackSlug: string;
  rev: number;
  threadId?: string;
}

/** `Ravix.Ids.parse_channel/1`. Null for anything that is not one of ours. */
export function parseChannel(channelId: string | null | undefined): ParsedChannel | null {
  if (!channelId) return null;
  const m = CHANNEL_PATTERN.exec(channelId);
  if (!m) return null;
  return { projectId: m[1]!, trackSlug: m[2]!, rev: Number(m[3]), ...(m[4] ? { threadId: m[4] } : {}) };
}
