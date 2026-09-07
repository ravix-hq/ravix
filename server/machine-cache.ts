/**
 * One Fountain call per burst, not one per request.
 *
 * A project's machine is derived from its conversations rather than stored
 * (see `machineOf` in `tracks.ts` for why), and the derivation used to run on
 * every request that needed it: the file, diff and listing routes, the
 * terminal, the vitals readout every twenty seconds per viewer, the preview
 * reconciler every fifteen, the shared browser, the native runner. Each one
 * listed the agent's conversations afresh. Across the deployed apps that was
 * part of ~50,000 conversation-list calls an hour against production and a
 * four-day database-pool incident (2026-09-07).
 *
 * So the list is memoised, briefly, per Fountain client and project:
 *
 *   - **Short.** `TTL_MS` is a few seconds — enough that one screen's burst of
 *     requests costs one call, short enough that nothing on screen is stale
 *     for long.
 *   - **Coalesced.** Concurrent misses share one in-flight promise.
 *   - **Invalidated on the writes that change the answer.** Opening a track
 *     (which may provision the machine), closing one, rebuilding or destroying
 *     the project: each calls `forgetProject`.
 *   - **Refreshed by whoever needs it fresh.** The sidebar's status dot must
 *     not lag a turn ending, so `tracks.list`/`show` read live and write the
 *     result through; everything that only needs the machine's identity reads
 *     from the memo.
 *
 * The sprite behind a sandbox never changes for a given sandbox id, so that
 * lookup is memoised for longer; a "not a sprite" answer only briefly, since a
 * sandbox mid-provisioning may not have one yet.
 */
import type { ConversationSummary, Fountain } from "./fountain";

/** How long a conversation list stands before it is re-read. */
export const TTL_MS = 5_000;
/** How long a sandbox's sprite name stands. It does not change. */
export const SPRITE_TTL_MS = 60_000;

interface Entry<T> {
  value: Promise<T>;
  expiresAt: number;
}

const entries = new Map<string, Entry<unknown>>();

/**
 * Which client an entry was read on. Tests build a Fountain per case, and a
 * memo keyed on the project alone would hand one test another's answer; in
 * production there is one client and one id.
 */
const clientIds = new WeakMap<object, number>();
let nextClientId = 1;

function clientId(fountain: object): number {
  let id = clientIds.get(fountain);
  if (!id) {
    id = nextClientId++;
    clientIds.set(fountain, id);
  }
  return id;
}

function memo<T>(key: string, load: () => Promise<T>, ttlFor: (value: T) => number, nowMs: number): Promise<T> {
  const hit = entries.get(key);
  if (hit && hit.expiresAt > nowMs) return hit.value as Promise<T>;
  // Until the load settles it is held for the base TTL so concurrent misses
  // share it; the value then decides how long it stands.
  const value = load();
  const entry: Entry<T> = { value, expiresAt: nowMs + TTL_MS };
  entries.set(key, entry);
  value.then(
    (v) => {
      if (entries.get(key) === entry) entry.expiresAt = nowMs + ttlFor(v);
    },
    () => {
      // A failure is nobody's answer: the next caller retries.
      if (entries.get(key) === entry) entries.delete(key);
    },
  );
  return value;
}

const listKey = (fountain: Fountain, project: { id: string; agentId: string }) => `${clientId(fountain)}:conversations:${project.id}:${project.agentId}`;

/**
 * The project's agent's conversations — from the memo while fresh, unless
 * `fresh` is set, in which case Fountain is asked and the memo refreshed.
 */
export function liveConversations(
  fountain: Fountain,
  project: { id: string; agentId: string },
  opts: { fresh?: boolean; nowMs?: number } = {},
): Promise<ConversationSummary[]> {
  const now = opts.nowMs ?? Date.now();
  const key = listKey(fountain, project);
  if (opts.fresh) entries.delete(key);
  return memo(key, () => fountain.listConversations(project.agentId), () => TTL_MS, now);
}

/** The sprite behind one sandbox, or null when it is not on Sprites. */
export function spriteName(fountain: Fountain, sandboxId: string, load: () => Promise<string | null>, nowMs = Date.now()): Promise<string | null> {
  return memo(`${clientId(fountain)}:sprite:${sandboxId}`, load, (name) => (name ? SPRITE_TTL_MS : TTL_MS), nowMs);
}

/** Forget what was derived for one project, on every client. */
export function forgetProject(projectId: string): void {
  const marker = `:conversations:${projectId}:`;
  for (const key of entries.keys()) if (key.includes(marker)) entries.delete(key);
}

/** For tests: forget everything. */
export function resetMachineCache(): void {
  entries.clear();
}
