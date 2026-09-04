import { expect, test } from "bun:test";
import { splitAuthor, withAuthor } from "./author";

test("a label round-trips", () => {
  expect(splitAuthor(withAuthor("ana", "fix the flaky test"))).toEqual({ login: "ana", text: "fix the flaky test" });
});

test("an unlabelled prompt is left exactly as typed", () => {
  // Every solo track in the fleet goes through this path, so it must not so
  // much as trim.
  expect(splitAuthor("  fix the thing  ")).toEqual({ login: null, text: "  fix the thing  " });
});

test("something that merely looks like a label is not one", () => {
  // Somebody quoting the format, or writing prose that starts with a bracket.
  for (const prompt of ["[from ana] hi", "[from @] hi", "[from @a b] hi", "[fromm @ana] hi", "prefix [from @ana] hi"]) {
    expect(splitAuthor(prompt).login).toBeNull();
  }
});

test("a login that GitHub would allow survives", () => {
  expect(splitAuthor(withAuthor("a-very-long-hyphenated-name", "x")).login).toBe("a-very-long-hyphenated-name");
});

test("a prompt that itself contains a label keeps its own text", () => {
  // Only the leading label is a label; one in the body is the person's words.
  const { login, text } = splitAuthor(withAuthor("ana", "look at [from @bo] in the log"));
  expect(login).toBe("ana");
  expect(text).toBe("look at [from @bo] in the log");
});
