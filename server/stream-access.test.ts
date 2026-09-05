import { expect, test } from "bun:test";
import { watchStream } from "./stream-access";

test("closing a real HTTP viewer cancels upstream without crashing the server", async () => {
  let cancelled = 0;
  const server = Bun.serve({ port: 0, idleTimeout: 0, fetch(req) {
    if (new URL(req.url).pathname === "/healthz") return new Response("alive");
    const upstream = new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("data: ready\n\n")); }, cancel() { cancelled++; } }));
    const access = watchStream("p", "u", req.signal, () => true);
    return new Response(access.forward(upstream), { headers: { "content-type": "text/event-stream" } });
  } });
  try {
    for (let i = 0; i < 3; i++) {
      const abort = new AbortController();
      const response = await fetch(`http://localhost:${server.port}/stream`, { signal: abort.signal });
      const reader = response.body!.getReader();
      expect((await reader.read()).value!.length).toBeGreaterThan(0);
      abort.abort(); await reader.cancel().catch(() => {});
    }
    await Bun.sleep(20);
    expect(await fetch(`http://localhost:${server.port}/healthz`).then(r => r.text())).toBe("alive");
    expect(cancelled).toBe(3);
  } finally { server.stop(true); }
});
