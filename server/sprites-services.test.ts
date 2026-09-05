import { expect, test } from "bun:test";
import { Sprites } from "./sprites";

test("managed services use private ports, bounded NDJSON operations, and expiring tasks", async () => {
  const calls: { path: string; method: string; body: unknown; argv: string[] }[] = [];
  const server = Bun.serve({ port: 0, async fetch(req) {
    expect(req.headers.get("authorization")).toBe("Bearer provider-token");
    const url = new URL(req.url);
    calls.push({ path: url.pathname + url.search, method: req.method, body: await req.json().catch(() => null), argv: url.searchParams.getAll("cmd") });
    if (url.pathname.endsWith("/exec")) return new Response(new Uint8Array([3, 0]));
    if (req.method === "GET") return Response.json({ name: "sy-test", state: { status: "running" } });
    return new Response('{"type":"started"}\n{"type":"complete"}\n');
  } });
  try {
    const sprites = new Sprites({ token: "provider-token", baseUrl: `http://localhost:${server.port}` });
    await sprites.defineService("sprite", "sy-test", "/work/one/app", "npm start", 20_123);
    expect(calls[0]!.method).toBe("PUT");
    expect(calls[0]!.body).toEqual({ cmd: "sh", args: ["-lc", "npm start"], dir: "/work/one/app", env: { PORT: "20123", HOST: "127.0.0.1" }, needs: [] });
    expect(calls[0]!.path).toContain("duration=1s");
    await sprites.serviceAction("sprite", "sy-test", "stop"); expect(calls[1]!.path).toContain("/stop");
    await sprites.serviceAction("sprite", "sy-test", "delete"); expect(calls[2]!.method).toBe("DELETE");
    await sprites.activity("sprite", "sy-test"); expect(calls[3]!.argv).toContain('{"expire":"2m"}');
    await sprites.activity("sprite", "sy-test", true); expect(calls[4]!.argv).toContain("DELETE");
    await sprites.serviceLogs("sprite", "sy-test"); expect(calls[5]!.argv).toEqual(["tail", "-c", "32000", "/.sprite/logs/services/sy-test.log"]);
  } finally { server.stop(true); }
});
