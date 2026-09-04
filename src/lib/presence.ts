/**
 * The browser's half of the two clocks in `server/presence.ts`.
 *
 * That file decides the lifetimes and this one has to live inside them, so the
 * two numbers below are derived from its two rather than chosen: a beat every
 * twenty seconds against a forty-five second watch lease survives one dropped
 * request without the watcher blinking out, and a typing pulse every second and
 * a half against a three second typing lease does the same for the indicator
 * while somebody is still mid-word.
 *
 * Neither clock ever says "stopped". Watching ends by a beat not arriving, or
 * by the explicit goodbye below; typing ends by the pulses stopping. A browser
 * that is closed mid-sentence therefore leaves nothing behind to retract, which
 * is the whole reason the server took a pulse instead of a state.
 */
import { useCallback, useEffect, useRef } from "react";
import type { Presence } from "../../shared/api";
import { api } from "./api";

const BEAT_MS = 20_000;
const PULSE_MS = 1_500;

/**
 * Say we have gone, by a route that outlives the page.
 *
 * A request started from an unload handler is cancelled along with the
 * document, so on a closing tab the server would only find out when the lease
 * lapsed — the forty-five seconds of ghost the goodbye exists to avoid.
 * `sendBeacon` hands the request to the browser to deliver afterwards. Where
 * there is no beacon to be had we fall back to the ordinary call, which is
 * exactly right for the common case of switching tracks with the tab still
 * open, and is the lease's problem in the rare one where it is not.
 */
function goodbye(trackId: string): void {
  const body = JSON.stringify({ leaving: true });
  const beacon = navigator.sendBeacon?.(`/api/tracks/${trackId}/presence`, new Blob([body], { type: "application/json" }));
  if (beacon) return;
  void api.presence(trackId, { leaving: true }).catch(() => undefined);
}

/**
 * Hold a track open, and return the pulse its composer beats on.
 *
 * Mounted once per open track and never for the others: a heartbeat for a
 * track nobody is looking at is a name in somebody else's header that belongs
 * to a person who is somewhere else entirely.
 *
 * Every failure here is swallowed. Presence is the least important thing on
 * the screen, and a toast about a heartbeat is a worse outcome than a face
 * that lapses and comes back on the next beat.
 */
export function useHeartbeat(trackId: string): () => void {
  const pulsed = useRef(0);

  useEffect(() => {
    // The pulse throttle belongs to a track, not to the hook: carrying it
    // across a switch would eat the first pulse on the track just opened.
    pulsed.current = 0;

    const beat = () => void api.presence(trackId).catch(() => undefined);
    beat();
    const timer = setInterval(beat, BEAT_MS);

    // The unmount below never runs when a tab is closed or navigated away
    // from, which is the case the goodbye is most worth having. A tab that
    // comes back from the browser's cache re-announces itself on its next
    // beat, so saying goodbye slightly too eagerly costs nothing.
    const leaving = () => goodbye(trackId);
    window.addEventListener("pagehide", leaving);

    return () => {
      clearInterval(timer);
      window.removeEventListener("pagehide", leaving);
      leaving();
    };
  }, [trackId]);

  return useCallback(() => {
    const now = Date.now();
    if (now - pulsed.current < PULSE_MS) return;
    pulsed.current = now;
    void api.presence(trackId, { typing: true }).catch(() => undefined);
  }, [trackId]);
}

/** Everyone present except the person reading, who knows where they are. */
export function others(present: Presence[], viewerLogin: string): Presence[] {
  const me = viewerLogin.toLowerCase();
  return present.filter((p) => p.login.toLowerCase() !== me);
}

/**
 * "@dana is", "@dana and @eli are", "3 people are" — a subject and a verb that
 * agrees with it, for the two sentences presence has to say.
 *
 * Names stop at two because a header three logins wide is no longer a glance,
 * and because the third name is never the one you were looking for anyway.
 */
export function subject(logins: string[]): string {
  const [first, second] = logins;
  if (!first) return "";
  if (!second) return `@${first} is`;
  if (logins.length === 2) return `@${first} and @${second} are`;
  return `${logins.length} people are`;
}
