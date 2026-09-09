import { describe, expect, test } from "bun:test";
import { SseParser } from "./sse";

describe("SseParser", () => {
  test("parses id/event/data records and ignores heartbeats", () => {
    const p = new SseParser();
    const msgs = p.push(
      ': heartbeat\n\nid: 41\nevent: output\ndata: {"kind":"output"}\n\n',
    );
    expect(msgs).toEqual([{ id: "41", event: "output", data: '{"kind":"output"}' }]);
  });

  test("holds a partial record across pushes", () => {
    const p = new SseParser();
    expect(p.push("id: 1\nevent: stage\nda")).toEqual([]);
    expect(p.push("ta: x\n\n")).toEqual([{ id: "1", event: "stage", data: "x" }]);
  });

  test("joins multi-line data and defaults the event name", () => {
    const p = new SseParser();
    expect(p.push("data: a\ndata: b\n\n")).toEqual([{ id: null, event: "message", data: "a\nb" }]);
  });

  test("a synthetic event without an id still comes through", () => {
    const p = new SseParser();
    expect(p.push('event: team\ndata: {"reason":"changed"}\n\n')).toEqual([
      { id: null, event: "team", data: '{"reason":"changed"}' },
    ]);
  });
});
