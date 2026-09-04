import { expect, test } from "bun:test";
import { nameTrack, YARDS } from "./names";
import { slugify } from "./ids";

test("every yard survives being a directory, a branch and a channel id", () => {
  // A track's name is all three at once. A name that slugified to something
  // shorter, empty or colliding would be found as a broken worktree rather
  // than as a naming problem.
  const slugs = YARDS.map((y) => slugify(y));
  expect(slugs.every((s) => s.length > 1)).toBe(true);
  expect(slugs.every((s) => /^[a-z][a-z0-9-]*[a-z0-9]$/.test(s))).toBe(true);
  expect(new Set(slugs).size).toBe(YARDS.length);
});

test("there are enough names that a project does not repeat itself in a day", () => {
  expect(YARDS.length).toBeGreaterThan(40);
});

test("a fresh project gets a real name rather than a placeholder", () => {
  const name = nameTrack([]);
  expect(YARDS).toContain(name);
  expect(name).not.toBe("Untitled");
});

test("a name in use is skipped, whichever one the dice picked", () => {
  // Start the walk exactly on the taken name: the point is that it moves on
  // rather than suffixing a name that is right there beside forty free ones.
  const taken = [slugify(YARDS[0]!)];
  const picked = nameTrack(taken, () => 0);
  expect(picked).toBe(YARDS[1]!);
});

test("closed tracks still spend their name", () => {
  // Passed in by the caller as every track ever, not just the live ones —
  // the branch on GitHub outlives the row.
  const all = YARDS.slice(0, 3).map((y) => slugify(y));
  const picked = nameTrack(all, () => 0);
  expect(all).not.toContain(slugify(picked));
});

test("a project that has used every name suffixes rather than refusing", () => {
  const everything = YARDS.map((y) => slugify(y));
  const picked = nameTrack(everything, () => 0);
  expect(picked).toBe(`${YARDS[0]} 2`);
  // And again, so track fifty-two is not track fifty-one.
  expect(nameTrack([...everything, slugify(picked)], () => 0)).toBe(`${YARDS[0]} 3`);
});

test("the taken list is compared as slugs, not as typed", () => {
  // The sidebar shows "Crewe" and the machine holds "crewe". Comparing the
  // display form would hand out a second Crewe on the first rename.
  expect(nameTrack([YARDS[0]!], () => 0)).toBe(YARDS[1]!);
  expect(nameTrack([YARDS[0]!.toUpperCase()], () => 0)).toBe(YARDS[1]!);
});

test("a random start spreads names across the list", () => {
  // Not a distribution test — just that the first name is not always the same
  // one, which is what a fixed start would give every project in the fleet.
  const seen = new Set<string>();
  for (let i = 0; i < YARDS.length; i++) seen.add(nameTrack([], () => i / YARDS.length));
  expect(seen.size).toBeGreaterThan(YARDS.length / 2);
});
