import { afterEach, expect, test } from "bun:test";
import { createServer, request } from "node:http";
import { connect } from "node:net";
import { WebSocketServer, WebSocket } from "ws";
import { Duplex } from "node:stream";
function createWebSocketStream(ws: import("ws").WebSocket) {
 const stream = new Duplex({read() {}, write(c,_e,cb) { ws.send(c,cb); }, final(cb) { ws.close(); cb(); }}); ws.on("message", d=>stream.push(d)); ws.on("close",()=>stream.push(null)); return stream;
}

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildContext } from "./context";
import { loadConfig } from "./config";
import { Db } from "./db";
import { Cipher, sha256 } from "./crypto";
import { createPreviewGateway } from "./preview-gateway";
import { publish } from "./hub";
import { spriteTunnel } from "./sprites-tunnel";

const cleanup: (() => void)[] = [];
afterEach(() => { for (const fn of cleanup.splice(0).reverse()) fn(); });
const listen = (server: ReturnType<typeof createServer>) => new Promise<number>(resolve => server.listen(0, "127.0.0.1", () => resolve((server.address() as { port: number }).port)));
async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "sy-gateway-"));
  cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
  const headers: Record<string, unknown>[] = [];
  const upstream = createServer((req, res) => {
    headers.push(req.headers);
    if (req.url === "/stream") {
      res.writeHead(200, { "content-type": "text/event-stream" }); res.write("first\n");
      const timer = setInterval(() => res.write("later\n"), 25);
      res.on("close", () => clearInterval(timer)); return;
    }
    if (req.url === "/flood") {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      let n = 0;
      const write = () => { while (n < 128) { n++; if (!res.write(Buffer.alloc(65_536, 120))) return; } res.end(); };
      res.on("drain", write); write(); return;
    }
    if (req.url === "/upload") { req.pipe(res); return; }
    res.writeHead(200, { "content-type": "text/html", "set-cookie": ["app=1; Domain=preview.localhost; Path=/", "__Host-switchyard_preview=evil; Path=/; Secure"] });
    res.end("<!DOCTYPE html><html><head><title>App</title></head><body>track app</body></html>");
  });
  const appPort = await listen(upstream);
  const appWs = new WebSocketServer({ server: upstream });
  appWs.on("connection", ws => ws.on("message", (data, binary) => ws.send(data, { binary })));
  const provider = createServer();
  const proxyWs = new WebSocketServer({ server: provider });
  let tunnels = 0;
  proxyWs.on("connection", (ws, req) => {
    expect(req.headers.authorization).toBe("Bearer secret-provider-token");
    ws.once("message", data => {
      expect(JSON.parse(data.toString())).toEqual({ host: "127.0.0.1", port: appPort }); tunnels++;
      const tcp = connect(appPort, "127.0.0.1", () => {
        ws.send(JSON.stringify({ status: "connected" }));
        const stream = createWebSocketStream(ws);
        stream.on("error", () => tcp.destroy()); tcp.on("error", () => stream.destroy());
        tcp.pipe(stream).pipe(tcp);
      });
      ws.on("close", () => tcp.destroy());
    });
  });
  const providerPort = await listen(provider);
  const config = loadConfig({ DATA_DIR: dir, SWITCHYARD_SECRET: "gateway-test-secret-long-enough", PUBLIC_URL: "http://localhost:5183", SPRITES_TOKEN: "secret-provider-token", SPRITES_URL: `http://127.0.0.1:${providerPort}`, FOUNTAIN_API_KEY: "test", PREVIEW_DOMAIN: "preview.localhost" });
  const db = new Db(config.dbPath);
  const ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
  ctx.fountain!.listConversations = async () => [{ id: "c", sandbox_id: "s", status: "idle", inserted_at: "2026-09-05" }] as never;
  ctx.fountain!.sandbox = async () => ({ id: "s", sprite_name: "sprite" }) as never;
  const owner = db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "test" });
  const guest = db.upsertUser({ githubId: "2", login: "bo", name: "Bo", avatarUrl: null, tokenEnc: "test" });
  db.createProject({ id: "p", userId: owner.id, name: "Demos", repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null, agentId: "a", environmentId: "e", vaultId: null, runtime: "claude", model: "test", instructions: "" });
  for (const id of ["t1", "t2"]) db.createTrack({ id, projectId: "p", conversationId: id, slug: id, title: id, branch: id, workdir: `/work/${id}`, originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login });
  db.addMember("t1", guest.id, owner.id);
  db.createSession(guest.id, await sha256("app-session"), 60_000);
  db.previews.grant({ hash: await sha256("preview-session"), trackId: "t1", sessionHash: await sha256("app-session"), expires: Date.now() + 60_000, kind: "session" });
  const row = db.previews.ensure("t1");
  Object.assign(row, { sprite: "sprite", sandboxId: "s", port: appPort, desired: "running", state: "ready" }); db.previews.save(row);
  const gateway = createPreviewGateway(ctx);
  const port = await listen(gateway); config.previews!.publicPort = `:${port}`;
  const host = `${row.hostname}.preview.localhost:${port}`, origin = `http://${host}`;
  const get = (path = "/", opts: { method?: string; cookie?: string; origin?: string; body?: string; host?: string } = {}) => new Promise<{ status: number; body: string; headers: Record<string, unknown> }>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: opts.method ?? "GET", headers: { host: opts.host ?? host, cookie: opts.cookie ?? "switchyard_preview_local=preview-session; switchyard_session=NEVER; app=okay", ...(opts.origin ? { origin: opts.origin } : {}) } }, res => {
      let body = ""; res.on("data", c => body += c); res.on("end", () => resolve({ status: res.statusCode!, body, headers: res.headers }));
    }); req.on("error", reject); req.end(opts.body);
  });
  cleanup.push(() => {
    for (const ws of proxyWs.clients) ws.terminate(); for (const ws of appWs.clients) ws.terminate();
    gateway.closeAllConnections(); gateway.close(); proxyWs.close(); provider.closeAllConnections(); provider.close(); appWs.close(); upstream.closeAllConnections(); upstream.close(); db.close();
  });
  return { ctx, row, guest, host, origin, port, get, headers, tunnels: () => tunnels };
}

test("auth precedes tunneling; gateway credentials and parent-domain cookies never reach apps", async () => {
  const f = await fixture();
  expect((await f.get("/", { cookie: "" })).status).toBe(401); expect(f.tunnels()).toBe(0);
  const res = await f.get(); expect(res.status).toBe(200); expect(res.body).toContain("track app");
  expect(res.body).toContain("/__switchyard/activity.js"); expect(String(f.headers[0]!.cookie).trim()).toBe("app=okay");
  expect(res.headers["set-cookie"]).toEqual(["app=1; Path=/"]);
  const other = f.ctx.db.previews.ensure("t2");
  expect((await f.get("/", { host: `${other.hostname}.preview.localhost:${f.port}` })).status).toBe(401);
}, 10_000);

test("tickets are single-use and exchange only on their own origin", async () => {
  const f = await fixture();
  f.ctx.db.previews.grant({ hash: await sha256("ticket"), trackId: "t1", sessionHash: await sha256("app-session"), expires: Date.now() + 60_000, kind: "ticket" });
  expect((await f.get("/__switchyard/exchange", { method: "POST", body: "ticket", origin: "http://evil.test" })).status).toBe(403);
  const accepted = await f.get("/__switchyard/exchange", { method: "POST", body: "ticket", origin: f.origin });
  expect(accepted.status).toBe(204); expect(String(accepted.headers["set-cookie"])).toContain("HttpOnly; SameSite=Strict");
  expect((await f.get("/__switchyard/exchange", { method: "POST", body: "ticket", origin: f.origin })).status).toBe(401);
});

test("HTTP streams deliver before completion and access revocation closes existing streams", async () => {
  const f = await fixture();
  await new Promise<void>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port: f.port, path: "/stream", headers: { host: f.host, cookie: "switchyard_preview_local=preview-session" } }, res => {
      res.once("data", chunk => {
        expect(chunk.toString()).toBe("first\n"); f.ctx.db.removeMember("t1", f.guest.id);
        publish("p", { event: "tracks", data: { projectId: "p" } });
      }); res.on("error", () => {}); res.on("close", resolve);
    }); req.on("error", reject); req.end();
  });
  expect((await f.get()).status).toBe(401);
}, 10_000);

test("WebSockets preserve text and binary frames and terminate on membership removal", async () => {
  const f = await fixture();
  const ws = new WebSocket(`ws://127.0.0.1:${f.port}/hmr`, { headers: { host: f.host, origin: f.origin, cookie: "switchyard_preview_local=preview-session" } });
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); });
  ws.binaryType = "arraybuffer";
  for (const data of ["hot reload", Buffer.from([0, 1, 2, 255])]) {
    const message = new Promise<[Buffer, boolean]>(resolve => ws.once("message", (data, binary) => resolve([Buffer.from(data as ArrayBuffer), binary])));
    ws.send(data); const [echo, binary] = await message;
    expect(echo).toEqual(Buffer.from(data)); expect(binary).toBe(typeof data !== "string");
  }
  const closed = new Promise<void>(resolve => ws.once("close", () => resolve()));
  f.ctx.db.removeMember("t1", f.guest.id); publish("p", { event: "tracks", data: { projectId: "p" } }); await closed;
}, 10_000);

test("expired tickets and cross-track exchanges cannot create a preview session", async () => {
  const f = await fixture(); const other = f.ctx.db.previews.ensure("t2");
  const otherHost = `${other.hostname}.preview.localhost:${f.port}`;
  f.ctx.db.previews.grant({ hash: await sha256("wrong-track"), trackId: "t1", sessionHash: await sha256("app-session"), expires: Date.now() + 60_000, kind: "ticket" });
  expect((await f.get("/__switchyard/exchange", { method: "POST", body: "wrong-track", host: otherHost, origin: `http://${otherHost}` })).status).toBe(401);
  f.ctx.db.previews.grant({ hash: await sha256("expired"), trackId: "t1", sessionHash: await sha256("app-session"), expires: Date.now() - 1, kind: "ticket" });
  expect((await f.get("/__switchyard/exchange", { method: "POST", body: "expired", origin: f.origin })).status).toBe(401);
  expect(f.tunnels()).toBe(0);
});

test("removal permanently revokes sessions, even if the member is invited again", async () => {
  const f = await fixture(); f.ctx.db.removeMember("t1", f.guest.id);
  f.ctx.db.addMember("t1", f.guest.id, f.ctx.db.project("p")!.userId);
  expect((await f.get()).status).toBe(401);
  expect(f.tunnels()).toBe(0);
});

test("sign-out revokes preview sessions and WebSockets fail closed without auth or with a foreign origin", async () => {
  const f = await fixture();
  for (const headers of [{ origin: f.origin }, { cookie: "switchyard_preview_local=preview-session", origin: "http://other.preview.localhost" }]) {
    const ws = new WebSocket(`ws://127.0.0.1:${f.port}/hmr`, { headers: { host: f.host, ...headers } });
    await new Promise<void>((resolve, reject) => { ws.once("open", () => reject(new Error("unauthorized upgrade"))); ws.on("error", () => resolve()); });
  }
  f.ctx.db.endSession(await sha256("app-session")); expect((await f.get()).status).toBe(401); expect(f.tunnels()).toBe(0);
});

test("HTTP request bodies are forwarded and cross-origin writes are rejected", async () => {
  const f = await fixture(); const data = "payload ".repeat(100_000);
  expect((await f.get("/upload", { method: "POST", body: data, origin: "http://evil" })).status).toBe(403);
  const response = await f.get("/upload", { method: "POST", body: data, origin: f.origin });
  expect(response.status).toBe(200); expect(response.body).toBe(data);
}, 10_000);

test("a slow tunnel consumer applies backpressure with a bounded readable queue", async () => {
  const f = await fixture();
  const stream = await spriteTunnel(f.ctx.config.sprites!, "sprite", f.row.port!);
  try {
    stream.write("GET /flood HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    await Bun.sleep(100);
    expect(stream.readableLength).toBeGreaterThan(0);
    expect(stream.readableLength).toBeLessThanOrEqual(2 * 1024 * 1024);
    let bytes = 0;
    for await (const chunk of stream) bytes += chunk.length;
    expect(bytes).toBeGreaterThanOrEqual(128 * 65_536);
  } finally { stream.destroy(); }
}, 10_000);
