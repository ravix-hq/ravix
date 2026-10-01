import { afterAll, beforeAll, expect, test } from "bun:test";
import { createServer } from "node:net";

// The Sprites mock behind the browser suite (`previews.ts`). Each sprite has
// its own ports, as a real one does; the mock runs every sprite's services as
// processes on this one host, and used to start each on its $PORT as given,
// so two tracks given 20000 on two sprites fought for one host port. A later
// preview then failed with "Port 20000 is already in use" while the earlier
// one answered its readiness probe in its place (RAV-40 follow-up).
let base = "";
const auth = { authorization: "Bearer sprites_mock", "content-type": "application/json" };

beforeAll(async () => {
  const port = await new Promise<number>(resolve => {
    const probe = createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as { port: number };
      probe.close(() => resolve(port));
    });
  });
  process.env.MOCK_SPRITES_PORT = String(port);
  await import("./previews");
  base = `http://127.0.0.1:${port}`;
});

afterAll(async () => {
  for (const sprite of ["sprite-a", "sprite-b"])
    await fetch(`${base}/v1/sprites/${sprite}/services/preview`, { method: "DELETE", headers: auth });
});

const define = (sprite: string, dir: string) =>
  fetch(`${base}/v1/sprites/${sprite}/services/preview`, {
    method: "PUT", headers: auth,
    body: JSON.stringify({ cmd: "sh", args: ["-lc", "npm run dev"], dir, env: { PORT: "20000", HOST: "127.0.0.1" }, needs: [] }),
  });

// GET / through the sprite's private tunnel, as Ravix's readiness probe does.
function throughTunnel(sprite: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base.replace("http", "ws")}/v1/sprites/${sprite}/proxy`, { headers: auth } as unknown as string[]);
    let body = "";
    ws.binaryType = "arraybuffer";
    ws.onopen = () => ws.send(JSON.stringify({ host: "127.0.0.1", port: 20000 }));
    ws.onmessage = event => {
      if (typeof event.data === "string") {
        if (JSON.parse(event.data).status === "connected")
          ws.send("GET / HTTP/1.1\r\nHost: preview.localhost\r\nConnection: close\r\n\r\n");
      } else body += new TextDecoder().decode(event.data);
    };
    ws.onclose = () => (body ? resolve(body) : reject(new Error(`no answer from ${sprite}`)));
    ws.onerror = () => reject(new Error(`tunnel to ${sprite} failed`));
  });
}

async function eventually(fn: () => Promise<string>, tries = 100): Promise<string> {
  try { return await fn(); } catch (error) {
    if (tries === 0) throw error;
    await Bun.sleep(100);
    return eventually(fn, tries - 1);
  }
}

test("two sprites each run their own service on the same $PORT, each reached through its own tunnel", async () => {
  expect((await define("sprite-a", "/work/track-a")).ok).toBe(true);
  expect((await define("sprite-b", "/work/track-b")).ok).toBe(true);

  const a = await eventually(() => throughTunnel("sprite-a"));
  const b = await eventually(() => throughTunnel("sprite-b"));
  expect(a).toContain("/work/track-a");
  expect(a).not.toContain("/work/track-b");
  expect(b).toContain("/work/track-b");

  // Neither logged a port collision.
  for (const sprite of ["sprite-a", "sprite-b"]) {
    const read = await fetch(`${base}/v1/sprites/${sprite}/services/preview`, { headers: auth });
    expect(read.ok).toBe(true);
  }
}, 30_000);

test("a service read carries its definition, as Sprites answers", async () => {
  const read = await (await fetch(`${base}/v1/sprites/sprite-a/services/preview`, { headers: auth })).json();
  expect(read).toMatchObject({
    name: "preview", cmd: "sh", args: ["-lc", "npm run dev"], dir: "/work/track-a",
    env: { PORT: "20000", HOST: "127.0.0.1" }, needs: [], state: { status: "running" },
  });
});
