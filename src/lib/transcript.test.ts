import { expect, test } from "bun:test";
import { mergeEvents, mergeTurns } from "./transcript";
import type { LogEvent } from "../../shared/fountain-types";

const event = (id: number) => ({ id, turn_id: "turn", data: String(id) } as LogEvent);

test("a late snapshot preserves live replies and orders overlapping replay", () => {
  const live = mergeEvents([], [event(3), event(2)]);
  const replay = mergeEvents(live, [event(1), event(2)]);
  expect(replay.map(e => e.id)).toEqual([1, 2, 3]);
  expect(mergeEvents(replay, [event(2), event(4)]).map(e => e.id)).toEqual([1, 2, 3, 4]);
});

test("a stale turn refresh cannot remove newer prompts", () => {
  const turn = (id: string, insertedAt: string) => ({ id, insertedAt, prompt: id, status: "completed", origin: "user" });
  const first = turn("first", "2026-09-06T00:00:01Z");
  const second = turn("second", "2026-09-06T00:00:02Z");
  expect(mergeTurns([second], [first]).map(t => t.id)).toEqual(["first", "second"]);
  expect(mergeTurns([first, second], [first])).toHaveLength(2);
});
