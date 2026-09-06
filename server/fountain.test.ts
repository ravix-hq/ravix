import { expect, test } from "bun:test";
import { Fountain, FountainHttpError } from "./fountain";

test("history follows cursors and preserves replies beyond the first thousand events", async () => {
  const cursors: (string | null)[] = [];
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const after = new URL(req.url).searchParams.get("after");
      cursors.push(after);
      return Response.json(after === null
        ? { data: Array.from({ length: 1000 }, (_, i) => ({ id: i + 1 })), meta: { has_more: true, next_cursor: 1000 } }
        : { data: [{ id: 1001, turn_id: "reply" }], meta: { has_more: false, next_cursor: null } });
    },
  });
  try {
    const events = await new Fountain(server.url.toString(), "test").events("conversation");
    expect(cursors).toEqual([null, "1000"]);
    expect(events).toHaveLength(1001);
    expect(events.at(-1)?.turn_id).toBe("reply");
  } finally { server.stop(true); }
});

test("a failed later page fails history instead of returning a partial transcript", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      return new URL(req.url).searchParams.has("after")
        ? Response.json({ error: "unavailable" }, { status: 503 })
        : Response.json({ data: [{ id: 1 }], meta: { has_more: true, next_cursor: 1 } });
    },
  });
  try {
    await expect(new Fountain(server.url.toString(), "test").events("conversation")).rejects.toBeInstanceOf(FountainHttpError);
  } finally { server.stop(true); }
});

test("a repeated pagination cursor does not loop forever", async () => {
  const server = Bun.serve({
    port: 0,
    fetch: () => Response.json({ data: [{ id: 1 }], meta: { has_more: true, next_cursor: 1 } }),
  });
  try {
    await expect(new Fountain(server.url.toString(), "test").events("conversation")).rejects.toThrow("did not advance");
  } finally { server.stop(true); }
});
