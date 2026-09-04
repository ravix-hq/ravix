import { afterEach, expect, test } from "bun:test";
import { PRESENCE_TIMINGS, beat, leave, present, resetPresence } from "./presence";

/**
 * Presence is two clocks with opposite requirements, and every test here is
 * about one of them being wrong in the direction that matters:
 *
 *   a watcher who vanishes too eagerly is a colleague who disappeared while
 *   still reading;
 *   a typist who lingers is "Ana is typing…" over an empty chair, which is the
 *   one indicator people actually wait on.
 */

const { WATCH_TTL_MS, TYPING_TTL_MS } = PRESENCE_TIMINGS;
const nobody = new Set<string>();

afterEach(() => resetPresence());

function ana(typing = false) {
  return beat({
    trackId: "t1",
    projectId: "p1",
    userId: "u-ana",
    login: "ana",
    name: "Ana",
    avatarUrl: null,
    typing,
    audience: nobody,
  });
}

function bo(typing = false) {
  return beat({
    trackId: "t1",
    projectId: "p1",
    userId: "u-bo",
    login: "bo",
    name: "Bo",
    avatarUrl: null,
    typing,
    audience: nobody,
  });
}

test("a beat puts somebody in the room", () => {
  expect(ana().map((p) => p.login)).toEqual(["ana"]);
  expect(present("t1").map((p) => p.login)).toEqual(["ana"]);
});

test("an empty track has nobody in it", () => {
  expect(present("never-touched")).toEqual([]);
});

test("two people are both there, in a stable order", () => {
  bo();
  ana();
  // Sorted by login rather than by arrival, so the row does not reshuffle
  // every time somebody's heartbeat lands.
  expect(present("t1").map((p) => p.login)).toEqual(["ana", "bo"]);
});

test("watching outlives a gap and then lapses", () => {
  ana();
  expect(present("t1", Date.now() + WATCH_TTL_MS - 1_000)).toHaveLength(1);
  expect(present("t1", Date.now() + WATCH_TTL_MS + 1)).toHaveLength(0);
});

test("typing expires long before watching does", () => {
  ana(true);
  const t = Date.now();
  expect(present("t1", t)[0]?.typing).toBe(true);
  // Three seconds later they are still in the room and no longer mid-sentence.
  const after = present("t1", t + TYPING_TTL_MS + 1);
  expect(after[0]?.typing).toBe(false);
  expect(after).toHaveLength(1);
  expect(TYPING_TTL_MS).toBeLessThan(WATCH_TTL_MS);
});

test("a plain heartbeat does not cancel a typing pulse", () => {
  // The composer pings on a timer *and* on keystrokes. If the slower one
  // arriving second cleared the flag, the indicator would blink off between
  // words — which is exactly when it should be on.
  ana(true);
  ana(false);
  expect(present("t1")[0]?.typing).toBe(true);
});

test("a typing pulse refreshes the window rather than extending it forever", () => {
  ana(true);
  const first = Date.now();
  ana(true);
  // Still typing shortly after the second pulse, and stopped shortly after
  // that — the window is from the last pulse, not from the first.
  expect(present("t1", first + TYPING_TTL_MS - 500)[0]?.typing).toBe(true);
  expect(present("t1", first + TYPING_TTL_MS * 2 + 1)[0]?.typing).toBe(false);
});

test("leaving is immediate, and only removes the one who left", () => {
  ana();
  bo();
  leave("t1", "u-ana", "p1", nobody);
  expect(present("t1").map((p) => p.login)).toEqual(["bo"]);
});

test("leaving a track you are not in changes nothing", () => {
  ana();
  leave("t1", "u-nobody", "p1", nobody);
  expect(present("t1").map((p) => p.login)).toEqual(["ana"]);
});

test("presence is per track, not per project", () => {
  ana();
  beat({ trackId: "t2", projectId: "p1", userId: "u-bo", login: "bo", name: null, avatarUrl: null, typing: false, audience: nobody });
  expect(present("t1").map((p) => p.login)).toEqual(["ana"]);
  expect(present("t2").map((p) => p.login)).toEqual(["bo"]);
});

test("nothing is remembered across a restart", () => {
  ana();
  resetPresence();
  // Presence that survived would be a list of people who are not there.
  expect(present("t1")).toEqual([]);
});
