import { expect, test } from "bun:test";
import { branchFor, mountPathFor, parseChannel, slugify, trackChannel, workdirFor } from "./ids";

test("a slug is legal as a directory, a branch and a URL at once", () => {
  expect(slugify("Fix the flaky test")).toBe("fix-the-flaky-test");
  expect(slugify("feat(api): add /v2 endpoint")).toBe("feat-api-add-v2-endpoint");
  // Git refuses a leading dot and a trailing `.lock`; the strict rule wins for
  // all four uses rather than each place having its own idea of what is legal.
  expect(slugify(".hidden")).toBe("hidden");
  expect(slugify("branch.lock")).toBe("branch-lock");
  expect(slugify("---")).toBe("track");
  expect(slugify("", "fallback")).toBe("fallback");
});

test("a slug never ends in a separator, however it was truncated", () => {
  const long = slugify("a".repeat(30) + " " + "b".repeat(30));
  expect(long.length).toBeLessThanOrEqual(40);
  expect(long.endsWith("-")).toBe(false);
});

test("a channel id round-trips", () => {
  const channel = trackChannel("proj-1", "kyoto", 7);
  expect(channel).toBe("switchyard:proj-1:kyoto@r7");
  expect(parseChannel(channel)).toEqual({ projectId: "proj-1", trackSlug: "kyoto", rev: 7 });
});

test("a channel id that is not ours parses to null rather than to a wrong answer", () => {
  // The proxy-free design means the only thing standing between a project's
  // tracks and another project's is this parse, so a near-miss must not
  // resolve.
  expect(parseChannel("paddock:t2@r7")).toBeNull();
  expect(parseChannel("switchyard:proj-1:kyoto")).toBeNull();
  expect(parseChannel("switchyard:proj-1@r7")).toBeNull();
  expect(parseChannel(null)).toBeNull();
  expect(parseChannel("")).toBeNull();
});

test("a branch is namespaced under the person who asked for it", () => {
  expect(branchFor("jhgaylor", "kyoto", "track-1")).toBe("jhgaylor/kyoto-track-1");
  expect(branchFor("Some.User", "kyoto", "track-1")).toBe("some-user/kyoto-track-1");
});

test("a repository lands where Fountain's own bundled skill looks first", () => {
  expect(mountPathFor("BinaryBourbon/fountain")).toBe("/workspace/fountain");
  expect(mountPathFor("fountain")).toBe("/workspace/fountain");
});

test("a track's directory is under the work root", () => {
  expect(workdirFor("kyoto")).toBe("/home/sprite/work/kyoto");
});

test("reusing a track name gives a different branch even after its old branch is deleted", () => {
  expect(branchFor("jhgaylor", "antwerp", "track-1")).not.toBe(branchFor("jhgaylor", "antwerp", "track-2"));
});
