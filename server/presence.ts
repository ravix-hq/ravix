/**
 * Who is looking at a track right now, and who is mid-sentence.
 *
 * Two facts with the same shape and very different lifetimes, which is the
 * whole design here:
 *
 *   **Watching** lasts 45 seconds and is refreshed by a heartbeat. It has to
 *   outlive a slow tab, a laptop lid, a garbage-collected timer — so it is
 *   generous, and the cost of being generous is that somebody who closed their
 *   laptop lingers for up to three quarters of a minute. That is the right
 *   trade: a name that hangs about briefly is a much smaller lie than a name
 *   that vanishes while its owner is still reading.
 *
 *   **Typing** lasts 3 seconds and is refreshed by keystrokes. It has to be
 *   *ungenerous* for exactly the opposite reason: "Ana is typing…" left up
 *   after Ana wandered off is worse than no indicator at all, because it is
 *   the one signal people wait on before sending something themselves.
 *
 * In process and in one map, which is fine on the single replica a SQLite
 * volume already forces. Nothing here is persisted, and nothing should be:
 * presence that survived a restart would be a list of people who are not
 * there.
 */
import type { Presence } from "../shared/api";
import { publish } from "./hub";

const WATCH_TTL_MS = 45_000;
const TYPING_TTL_MS = 3_000;
/** How often lapses are noticed. Half the typing window, so it never overshoots by much. */
const SWEEP_MS = 1_500;

interface Watcher {
  userId: string;
  login: string;
  name: string | null;
  avatarUrl: string | null;
  projectId: string;
  watchingUntil: number;
  typingUntil: number;
}

/**
 * One track's room: who is in it, and who may be told about it.
 *
 * The audience is held here rather than re-derived, because the sweeper — the
 * only thing that notices somebody lapsing — runs on a timer with no request
 * behind it, and a database read per track per tick to answer "who may know"
 * is a poor trade for a frame nobody asked for. It is refreshed on every beat,
 * so an invitation takes effect on the inviter's next heartbeat at the latest.
 */
interface Room {
  watchers: Map<string, Watcher>;
  projectId: string;
  audience: ReadonlySet<string>;
}

/** trackId → room. */
const tracks = new Map<string, Room>();

/**
 * A heartbeat from one browser.
 *
 * `typing` is a pulse rather than a state: the browser says "still typing" and
 * the server gives that three seconds, instead of the browser having to
 * remember to say "stopped". A browser that crashes mid-word therefore stops
 * claiming to be typing without having to apologise for it, which a
 * start/stop protocol could not manage.
 */
export function beat(input: {
  trackId: string;
  projectId: string;
  userId: string;
  login: string;
  name: string | null;
  avatarUrl: string | null;
  typing: boolean;
  audience: ReadonlySet<string>;
}): Presence[] {
  const now = Date.now();
  const room: Room = tracks.get(input.trackId) ?? { watchers: new Map(), projectId: input.projectId, audience: input.audience };
  room.projectId = input.projectId;
  room.audience = input.audience;
  const existing = room.watchers.get(input.userId);
  room.watchers.set(input.userId, {
    userId: input.userId,
    login: input.login,
    name: input.name,
    avatarUrl: input.avatarUrl,
    projectId: input.projectId,
    watchingUntil: now + WATCH_TTL_MS,
    // A heartbeat that is not a typing pulse must not cancel one that is:
    // the composer pings on a timer and on keystrokes independently, and the
    // slower of the two arriving second would blink the indicator off.
    typingUntil: input.typing ? now + TYPING_TTL_MS : (existing?.typingUntil ?? 0),
  });
  tracks.set(input.trackId, room);

  const here = present(input.trackId, now);
  // Published every beat rather than only on change: a beat is at most one
  // per browser per twenty seconds, and comparing sets to save a frame that
  // small is more code than it saves.
  publish(input.projectId, { event: "here", data: { trackId: input.trackId, present: here } }, input.audience);
  ensureSweeper();
  return here;
}

/** Who is on a track now, watchers first typing or not, self included. */
export function present(trackId: string, now = Date.now()): Presence[] {
  const room = tracks.get(trackId);
  if (!room) return [];
  const out: Presence[] = [];
  for (const w of room.watchers.values()) {
    if (w.watchingUntil <= now) continue;
    out.push({ login: w.login, name: w.name, avatarUrl: w.avatarUrl, typing: w.typingUntil > now });
  }
  return out.sort((a, b) => a.login.localeCompare(b.login));
}

/**
 * Somebody closing a track, rather than lapsing out of it.
 *
 * Worth having as well as the lease: leaving a track is the one moment we
 * genuinely know, and forty-five seconds of a ghost in the corner of somebody
 * else's screen is exactly the kind of small wrongness that makes a presence
 * feature feel broken.
 */
export function leave(trackId: string, userId: string, projectId: string, audience: ReadonlySet<string>): void {
  const room = tracks.get(trackId);
  if (!room?.watchers.delete(userId)) return;
  if (room.watchers.size === 0) tracks.delete(trackId);
  publish(projectId, { event: "here", data: { trackId, present: present(trackId) } }, audience);
}

/**
 * The one timer, started on first use and stopped when nobody is anywhere.
 *
 * A lapse is the only presence change that arrives with no request attached,
 * so something has to go looking for it. It publishes only when a room's
 * membership or typing state actually changed, because the alternative is a
 * frame every second and a half to every open browser forever.
 */
let sweeper: ReturnType<typeof setInterval> | null = null;
const lastPublished = new Map<string, string>();

function ensureSweeper(): void {
  if (sweeper) return;
  sweeper = setInterval(() => {
    const now = Date.now();
    if (tracks.size === 0) {
      clearInterval(sweeper!);
      sweeper = null;
      lastPublished.clear();
      return;
    }
    for (const [trackId, room] of [...tracks]) {
      for (const [userId, w] of [...room.watchers]) if (w.watchingUntil <= now) room.watchers.delete(userId);
      const { projectId, audience } = room;
      if (room.watchers.size === 0) tracks.delete(trackId);

      const here = present(trackId, now);
      const fingerprint = here.map((p) => `${p.login}${p.typing ? "!" : ""}`).join(",");
      if (lastPublished.get(trackId) === fingerprint) continue;
      if (fingerprint) lastPublished.set(trackId, fingerprint);
      else lastPublished.delete(trackId);
      publish(projectId, { event: "here", data: { trackId, present: here } }, audience);
    }
  }, SWEEP_MS);
  // Never hold the process open for a presence timer.
  sweeper.unref?.();
}

/** For tests: forget everybody. */
export function resetPresence(): void {
  tracks.clear();
  lastPublished.clear();
  if (sweeper) {
    clearInterval(sweeper);
    sweeper = null;
  }
}

export const PRESENCE_TIMINGS = { WATCH_TTL_MS, TYPING_TTL_MS, SWEEP_MS };
