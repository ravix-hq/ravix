import { expect, test } from "bun:test";
import { decodeFrames, resolveCwd, shq } from "./sprites";

/** Sprites frames its exec output: 1 = stdout, 2 = stderr, 3 = exit code. */
function frame(id: number, text: string): number[] {
  return [id, ...new TextEncoder().encode(text)];
}

test("stdout and stderr stay separate, and the exit code arrives", () => {
  const raw = new Uint8Array([...frame(1, "out"), ...frame(2, "err"), 3, 3]);
  expect(decodeFrames(raw)).toEqual({ stdout: "out", stderr: "err", code: 3 });
});

test("a frame ends at the next id byte, so interleaved output reassembles in order", () => {
  const raw = new Uint8Array([...frame(1, "a"), ...frame(2, "E"), ...frame(1, "b"), 3, 0]);
  expect(decodeFrames(raw)).toEqual({ stdout: "ab", stderr: "E", code: 0 });
});

test("no exit frame reads as success rather than as a crash", () => {
  // A truncated response is not the same as a failing command, and reporting a
  // non-zero code for one would put a red exit line under working output.
  expect(decodeFrames(new Uint8Array(frame(1, "hello"))).code).toBe(0);
});

test("an empty body is not an error", () => {
  expect(decodeFrames(new Uint8Array([]))).toEqual({ stdout: "", stderr: "", code: 0 });
});

// ── the confinement, which is the whole security of the terminal ────────

const ROOT = "/home/sprite/work/kyoto";

test("a relative path resolves inside the track's worktree", () => {
  expect(resolveCwd(ROOT, "src")).toBe(`${ROOT}/src`);
  expect(resolveCwd(ROOT, "src/lib/..")).toBe(`${ROOT}/src`);
  expect(resolveCwd(ROOT, undefined)).toBe(ROOT);
});

test("escaping upward snaps back to the root instead of leaving the worktree", () => {
  // Without this the terminal is a way around the one rule the agent is told
  // three times to follow — including into another track's directory.
  expect(resolveCwd(ROOT, "..")).toBe(ROOT);
  expect(resolveCwd(ROOT, "../../..")).toBe(ROOT);
  expect(resolveCwd(ROOT, "/etc")).toBe(ROOT);
  expect(resolveCwd(ROOT, "/home/sprite/work/other")).toBe(ROOT);
  expect(resolveCwd(ROOT, "src/../../../../etc/passwd")).toBe(ROOT);
});

test("a sibling whose name merely starts with the root is not inside it", () => {
  // `/home/sprite/work/kyoto-2` is another track. String-prefix matching
  // without the separator would hand it over.
  expect(resolveCwd(ROOT, "/home/sprite/work/kyoto-2")).toBe(ROOT);
});

test("quoting survives the characters a shell would otherwise act on", () => {
  expect(shq("plain")).toBe("'plain'");
  expect(shq("it's")).toBe(`'it'\\''s'`);
  expect(shq("a; rm -rf /")).toBe("'a; rm -rf /'");
});
