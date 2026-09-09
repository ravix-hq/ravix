/**
 * The front is the only path between the public listener and the preview
 * gateway, so what it must not lose is: the Host that names the track, the
 * cookies and Origin the gateway checks, every Set-Cookie and redirect the
 * gateway answers with, and WebSocket frames in both directions with their
 * negotiated subprotocol. A stand-in gateway records what arrives.
 */
import { afterEach, expect, test } from "bun:test";
import { createServer, type IncomingHttpHeaders } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocketServer } from "ws";
import { loadConfig } from "./config";
import { buildContext } from "./context";
import { Cipher } from "./crypto";
import { Db } from "./db";
import { testSql } from "./sql";
import { createPreviewFront, type PreviewPeer } from "./preview-front";

const cleanup: (() => void)[] = [];
afterEach(() => { for (const fn of cleanup.splice(0)) fn(); });

async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "ravix-front-"));
  const seen: { method: string; url: string; headers: IncomingHttpHeaders; body: string }[] = [];
  const upgrades: IncomingHttpHeaders[] = [];
  const wss = new WebSocketServer({ noServer: true, handleProtocols: protocols => (protocols.has("vite-hmr") ? "vite-hmr" : false) });
  const gateway = createServer(async (req, res) => {
    let body = ""; for await (const chunk of req) body += chunk;
    seen.push({ method: req.method!, url: req.url!, headers: req.headers, body });
    if (req.url === "/redirect") { res.writeHead(302, { location: "/__ravix/start", "cache-control": "no-store" }); res.end(); return; }
    if (req.url === "/cookies") { res.writeHead(204, { "set-cookie": ["a=1; Path=/", "b=2; Path=/; HttpOnly"] }); res.end(); return; }
    if (req.url === "/stream") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.write("first,"); setTimeout(() => { res.write("second,"); res.end("done"); }, 30); return;
    }
    if (req.url === "/gzip") { res.writeHead(200, { "content-type": "text/plain", "content-encoding": "gzip" }); res.end(Buffer.from(Bun.gzipSync("inflated"))); return; }
    res.writeHead(200, { "content-type": "text/plain", "x-echo-host": String(req.headers.host) }); res.end(`hello ${req.headers.host}`);
  });
  gateway.on("upgrade", (req, socket, head) => {
    upgrades.push(req.headers);
    if (req.headers.cookie !== "ravix_preview_local=ok") { socket.end("HTTP/1.1 401 Preview unavailable\r\nConnection: close\r\n\r\n"); return; }
    wss.handleUpgrade(req, socket, head, ws => {
      ws.send(`welcome ${req.headers.host}`);
      ws.on("message", (data, binary) => ws.send(binary ? Buffer.concat([Buffer.from([0xff]), data as Buffer]) : `echo ${data}`, { binary }));
    });
  });
  const gatewayPort = await new Promise<number>(resolve => gateway.listen(0, "127.0.0.1", () => resolve((gateway.address() as { port: number }).port)));
  const config = loadConfig({ DATA_DIR: dir, RAVIX_SECRET: "front-test-secret-long-enough", PUBLIC_URL: "http://localhost:5183", PREVIEW_DOMAIN: "preview.localhost", PORT: "0" });
  const db = await Db.open(await testSql());
  const ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
  const front = createPreviewFront(ctx, gatewayPort);
  const server = Bun.serve<PreviewPeer>({
    port: 0, hostname: "127.0.0.1",
    fetch: (request, server) => front.matches(request) ? front.fetch(request, server) : new Response("app"),
    websocket: front.websocket,
  });
  // The public origin is what a browser would use; the test dials loopback and names the host itself.
  config.previews!.publicPort = `:${server.port}`;
  const host = `t-abc.preview.localhost:${server.port}`;
  const base = `http://127.0.0.1:${server.port}`;
  cleanup.push(() => { server.stop(true); for (const ws of wss.clients) ws.terminate(); wss.close(); gateway.closeAllConnections(); gateway.close(); db.close(); });
  return { host, base, seen, upgrades, port: server.port };
}

test("app hosts stay with the app; preview hosts reach the gateway with Host, cookies and Origin intact", async () => {
  const f = await fixture();
  expect(await (await fetch(`${f.base}/`, { headers: { host: `localhost:${f.port}` } })).text()).toBe("app");
  const res = await fetch(`${f.base}/p?q=1`, { method: "POST", body: "payload", headers: { host: f.host, cookie: "ravix_preview_local=ok", origin: `http://${f.host}`, "sec-fetch-site": "same-origin" } });
  expect(await res.text()).toBe(`hello ${f.host}`);
  expect(res.headers.get("x-echo-host")).toBe(f.host);
  const hit = f.seen.at(-1)!;
  expect(hit.method).toBe("POST"); expect(hit.url).toBe("/p?q=1"); expect(hit.body).toBe("payload");
  expect(hit.headers.host).toBe(f.host); expect(hit.headers.cookie).toBe("ravix_preview_local=ok");
  expect(hit.headers.origin).toBe(`http://${f.host}`); expect(hit.headers["sec-fetch-site"]).toBe("same-origin");
});

test("redirects, every Set-Cookie, encodings and streamed bodies pass through untouched", async () => {
  const f = await fixture();
  const redirect = await fetch(`${f.base}/redirect`, { headers: { host: f.host }, redirect: "manual" });
  expect(redirect.status).toBe(302); expect(redirect.headers.get("location")).toBe("/__ravix/start");
  const cookies = await fetch(`${f.base}/cookies`, { headers: { host: f.host } });
  expect(cookies.status).toBe(204); expect(cookies.headers.getSetCookie()).toEqual(["a=1; Path=/", "b=2; Path=/; HttpOnly"]);
  const gz = await fetch(`${f.base}/gzip`, { headers: { host: f.host }, decompress: false } as RequestInit);
  expect(gz.headers.get("content-encoding")).toBe("gzip");
  expect(Buffer.from(Bun.gunzipSync(new Uint8Array(await gz.arrayBuffer()))).toString()).toBe("inflated");
  const stream = await fetch(`${f.base}/stream`, { headers: { host: f.host } });
  const reader = stream.body!.getReader();
  const first = await reader.read();
  expect(new TextDecoder().decode(first.value)).toBe("first,");
  let rest = ""; for (;;) { const r = await reader.read(); if (r.done) break; rest += new TextDecoder().decode(r.value); }
  expect(rest).toBe("second,done");
});

test("WebSockets relay both directions with their subprotocol, and a refused handshake is refused", async () => {
  const f = await fixture();
  const ws = new WebSocket(`ws://127.0.0.1:${f.port}/hmr?x=1`, { headers: { host: f.host, cookie: "ravix_preview_local=ok", origin: `http://${f.host}` }, protocols: ["vite-hmr", "other"] } as unknown as string[]);
  ws.binaryType = "arraybuffer";
  const frames: (string | ArrayBuffer)[] = [];
  const next = () => new Promise<string | ArrayBuffer>(resolve => { ws.onmessage = e => { frames.push(e.data); resolve(e.data); }; });
  await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("upgrade failed")); });
  expect(ws.protocol).toBe("vite-hmr");
  expect(await next()).toBe(`welcome ${f.host}`);
  const echo = next(); ws.send("ping"); expect(await echo).toBe("echo ping");
  const binary = next(); ws.send(new Uint8Array([1, 2, 3])); expect([...new Uint8Array(await binary as ArrayBuffer)]).toEqual([0xff, 1, 2, 3]);
  const closed = new Promise<CloseEvent>(resolve => { ws.onclose = resolve; });
  ws.close(1000, "bye"); await closed;
  expect(f.upgrades.at(-1)!.host).toBe(f.host); expect(f.upgrades.at(-1)!.origin).toBe(`http://${f.host}`);

  const refused = new WebSocket(`ws://127.0.0.1:${f.port}/hmr`, { headers: { host: f.host } } as unknown as string[]);
  const outcome = await new Promise<string>(resolve => { refused.onopen = () => resolve("open"); refused.onerror = () => resolve("error"); refused.onclose = () => resolve("closed"); });
  expect(outcome).not.toBe("open");
});
