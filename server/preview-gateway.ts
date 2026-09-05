import { createServer, type IncomingMessage, type ServerResponse, type IncomingHttpHeaders } from "node:http";
import { Transform, type Duplex } from "node:stream";
import type { AppContext } from "./context";
import { trackAccess } from "./context";
import { sha256, randomToken } from "./crypto";
import { HttpError } from "./http";
import { previewOrigin, previews } from "./previews";
import type { PreviewGrant, PreviewRow } from "./preview-store";
import { spriteTunnel, previewClient } from "./sprites-tunnel";
import { WebSocketServer } from "ws";
import { framing } from "./sprites-tunnel";
import { subscribe } from "./hub";

const COOKIE = "__Host-switchyard_preview";
const LOCAL_COOKIE = "switchyard_preview_local";
const CONTROL = "/__switchyard/";
const HOP = new Set(["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]);
function cookieName(ctx: AppContext) { return ctx.config.previews?.protocol === "http:" ? LOCAL_COOKIE : COOKIE; }
function cookie(req: IncomingMessage, name: string) {
  return req.headers.cookie?.split(";").map(p => p.trim()).find(p => p.startsWith(`${name}=`))?.slice(name.length + 1) ?? "";
}
function escape(value: string) { return value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!); }

export function upstreamHeaders(headers: IncomingHttpHeaders, host: string, upgrade = false): IncomingHttpHeaders {
  const out: IncomingHttpHeaders = {};
  const connection = new Set(String(headers.connection || "").toLowerCase().split(",").map(s => s.trim()));
  for (const [key, value] of Object.entries(headers)) {
    if (HOP.has(key) || connection.has(key) || key === "authorization" || key.startsWith("x-forwarded-") || key === "forwarded" || key === "accept-encoding") continue;
    out[key] = value;
  }
  if (out.cookie) out.cookie = out.cookie.split(";").filter(c => ![COOKIE, LOCAL_COOKIE, "switchyard_session"].includes(c.trim().split("=")[0]!)).join(";");
  out.host = host;
  out["accept-encoding"] = "identity";
  if (upgrade) { out.connection = "Upgrade"; out.upgrade = "websocket"; }
  return out;
}
function responseHeaders(headers: IncomingHttpHeaders, origin: string): IncomingHttpHeaders {
  const out: IncomingHttpHeaders = {};
  const connection = new Set(String(headers.connection || "").toLowerCase().split(",").map(s => s.trim()));
  for (const [key, value] of Object.entries(headers)) {
    if (HOP.has(key) || connection.has(key) || ["clear-site-data", "alt-svc"].includes(key)) continue;
    out[key] = value;
  }
  if (out["set-cookie"]) out["set-cookie"] = out["set-cookie"].filter(v => ![COOKIE, LOCAL_COOKIE, "switchyard_session"].includes(v.split("=")[0]!.trim()))
    .map(v => v.replace(/;\s*Domain=[^;]*/ig, ""));
  if (out.location && /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?([/]|$)/i.test(out.location)) {
    const url = new URL(out.location); out.location = `${origin}${url.pathname}${url.search}${url.hash}`;
  }
  out["referrer-policy"] = "no-referrer";
  // Authenticated content must never survive access loss in a shared cache.
  out["cache-control"] = "no-store";
  return out;
}

/** Insert once into HTML without buffering an entire response or its stream. */
export class PreviewHtml extends Transform {
  private pending = Buffer.alloc(0);
  private injected = false;
  private inject(final = false) {
    const end = this.pending.toString("latin1").toLowerCase().indexOf("</head>");
    if (end >= 0 || final || this.pending.length > 32_768) {
      const index = end >= 0 ? end : this.pending.length;
      this.push(this.pending.subarray(0, index));
      this.push(`<script src="${CONTROL}activity.js" defer></script>`);
      this.push(this.pending.subarray(index));
      this.pending = Buffer.alloc(0); this.injected = true;
    }
  }
  _transform(chunk: Buffer, _encoding: string, done: (err?: Error) => void) {
    if (this.injected) this.push(chunk);
    else { this.pending = Buffer.concat([this.pending, chunk]); this.inject(); }
    done();
  }
  _flush(done: () => void) { if (!this.injected) this.inject(true); done(); }
}

export function createPreviewGateway(ctx: AppContext) {
  const manager = previews(ctx);
  const connections = new Set<() => void>();
  function resolveHost(req: IncomingMessage) {
    const cfg = ctx.config.previews;
    const host = req.headers.host?.toLowerCase();
    if (!cfg || !host || !host.endsWith(`.${cfg.domain}${cfg.publicPort}`)) throw new HttpError(404, "preview", "Preview not found.");
    const name = host.slice(0, -`.${cfg.domain}${cfg.publicPort}`.length);
    const row = ctx.db.previews.byHost(name);
    if (!row) throw new HttpError(404, "preview", "Preview not found.");
    manager.assertOpen(row.trackId);
    return row;
  }
  function allowed(row: PreviewRow, grant: PreviewGrant): boolean {
    if (!ctx.db.previews.getGrant(grant.hash, row.trackId, grant.kind)) return false;
    const user = ctx.db.sessionUser(grant.sessionHash);
    if (!user) return false;
    try { return !trackAccess(ctx, user, row.trackId).track.closedAt && !ctx.db.previews.get(row.trackId)?.cleanup; }
    catch { return false; }
  }
  async function authorize(req: IncomingMessage, row: PreviewRow) {
    const hash = await sha256(cookie(req, cookieName(ctx)));
    const grant = ctx.db.previews.getGrant(hash, row.trackId, "session");
    if (!grant || !allowed(row, grant)) throw new HttpError(401, "preview_signin", "Open this preview from your signed-in Switchyard track.");
    return grant;
  }
  function watch(row: PreviewRow, grant: PreviewGrant, close: () => void) {
    const track = ctx.db.track(row.trackId)!;
    const user = ctx.db.sessionUser(grant.sessionHash)!;
    const check = () => { if (!allowed(row, grant) || ctx.db.previews.get(row.trackId)?.generation !== row.generation) close(); };
    const unsubscribe = subscribe(track.projectId, user.id, check);
    const timer = setInterval(check, 1000); timer.unref();
    connections.add(close);
    check();
    return () => { clearInterval(timer); unsubscribe(); connections.delete(close); };
  }
  function reply(res: ServerResponse, status: number, body: string, type = "text/html; charset=utf-8") {
    res.writeHead(status, { "content-type": type, "cache-control": "no-store", "referrer-policy": "no-referrer", "x-content-type-options": "nosniff" });
    res.end(body);
  }
  function fail(res: ServerResponse, error: unknown) {
    if (res.headersSent) { res.destroy(); return; }
    const status = error instanceof HttpError ? error.status : 502;
    const message = error instanceof HttpError ? error.message : "The preview did not answer. Return to the track to restart it or read its logs.";
    reply(res, status, `<meta name="viewport" content="width=device-width,initial-scale=1"><p>${escape(message)}</p><a href="${escape(ctx.config.publicUrl)}">Back to Switchyard</a>`);
  }
  const server = createServer(async (req, res) => {
    try {
      const row = resolveHost(req);
      const origin = previewOrigin(ctx, row);
      const path = new URL(req.url!, origin).pathname;
      if (path === `${CONTROL}open` && req.method === "GET") {
        // The ticket lives in a fragment: absent from access logs and Referer.
        reply(res, 200, `<meta name="viewport" content="width=device-width,initial-scale=1"><p>Opening private preview…</p><script>
          const ticket=location.hash.slice(1);history.replaceState(null,'',location.pathname);
          fetch('${CONTROL}exchange',{method:'POST',headers:{'content-type':'text/plain'},body:ticket}).then(r=>{if(!r.ok)throw Error('This preview link expired. Open it again from Switchyard.');location.replace('${CONTROL}start')}).catch(e=>document.querySelector('p').textContent=e.message);
        </script>`);
        return;
      }
      if (path === `${CONTROL}exchange` && req.method === "POST") {
        if (req.headers.origin !== origin) throw new HttpError(403, "origin", "Open previews from their own host.");
        let body = "";
        for await (const chunk of req) { body += chunk.toString(); if (body.length > 128) throw new HttpError(400, "ticket", "Invalid ticket."); }
        const ticket = ctx.db.previews.getGrant(await sha256(body), row.trackId, "ticket", true);
        const user = ticket && ctx.db.sessionUser(ticket.sessionHash);
        if (!ticket || !user || trackAccess(ctx, user, row.trackId).track.closedAt) throw new HttpError(401, "ticket", "This preview link expired. Open it again from Switchyard.");
        const token = randomToken();
        ctx.db.previews.grant({ ...ticket, hash: await sha256(token), expires: Date.now() + 12 * 60 * 60_000, kind: "session" });
        res.setHeader("set-cookie", `${cookieName(ctx)}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200${ctx.config.previews!.protocol === "https:" ? "; Secure" : ""}`);
        reply(res, 204, ""); return;
      }
      const grant = await authorize(req, row);
      // Same-origin writes and upgrades also prevent cross-track CSRF when
      // wildcard hosts happen to share a registrable domain.
      if (!["GET", "HEAD"].includes(req.method!) && req.headers.origin !== origin) throw new HttpError(403, "origin", "Cross-origin preview writes are not allowed.");
      if (req.headers["sec-fetch-site"] === "cross-site" || req.headers["sec-fetch-site"] === "same-site") throw new HttpError(403, "origin", "Open the preview directly.");
      const track = ctx.db.track(row.trackId)!;
      const back = `${ctx.config.publicUrl}/p/${track.projectId}/t/${track.id}`;
      if (path === `${CONTROL}start`) {
        manager.touch(row.trackId);
        if (row.state === "stopped") void manager.startService(row.trackId).catch(() => {});
        reply(res, 200, `<meta name="viewport" content="width=device-width,initial-scale=1"><h1>Live working copy</h1><p id="state">Starting preview…</p><pre id="logs"></pre><a href="${escape(back)}">Back to track · send a correction</a><script>
          async function poll(){const r=await fetch('${CONTROL}status');if(!r.ok){document.querySelector('#state').textContent='Access ended. Return to the track.';return;}const s=await r.json();if(s.state==='ready'){location.replace('/');return;}document.querySelector('#state').textContent=s.error||'Starting preview…';document.querySelector('#logs').textContent=s.logs||'';if(s.state!=='failed')setTimeout(poll,1000)}poll();
        </script>`); return;
      }
      if (path === `${CONTROL}status`) {
        reply(res, 200, JSON.stringify(manager.info(row.trackId)), "application/json"); return;
      }
      if (path === `${CONTROL}heartbeat` && req.method === "POST") {
        if (row.desired !== "running") throw new HttpError(409, "stopped", "Preview stopped. Open it from the track again.");
        manager.touch(row.trackId); reply(res, 204, ""); return;
      }
      if (path === `${CONTROL}activity.js`) {
        reply(res, 200, `(()=>{const beat=()=>{if(document.visibilityState==='visible')fetch('${CONTROL}heartbeat',{method:'POST'}).catch(()=>{})};beat();setInterval(beat,30000);document.addEventListener('visibilitychange',beat);const host=document.createElement('div');const root=host.attachShadow({mode:'open'});const a=document.createElement('a');a.href=${JSON.stringify(back)};a.textContent='Live working copy · Back to track';a.style.cssText='position:fixed;bottom:12px;right:12px;z-index:2147483647;background:#171717;color:white;padding:10px 14px;border-radius:8px;font:13px system-ui;text-decoration:none';root.append(a);document.body.append(host)})();`, "application/javascript; charset=utf-8"); return;
      }
      if (path.startsWith(CONTROL)) throw new HttpError(404, "preview", "Unknown preview control.");
      if (row.state !== "ready") {
        res.writeHead(302, { location: `${CONTROL}start`, "cache-control": "no-store" }); res.end(); return;
      }
      await manager.destination(row.trackId);
      manager.touch(row.trackId);
      const controller = new AbortController();
      let client: ReturnType<typeof previewClient> | undefined;
      const close = () => { controller.abort(); void client?.destroy(); res.destroy(); };
      const dispose = watch(row, grant, close);
      res.once("close", () => { dispose(); controller.abort(); void client?.destroy(); });
      req.on("aborted", close);
      const stream = await spriteTunnel(ctx.config.sprites!, row.sprite!, row.port!, controller.signal);
      client = previewClient(stream);
      const response = await client.request({ method: req.method as "GET", path: req.url!,
        signal: controller.signal, headers: upstreamHeaders(req.headers, new URL(origin).host),
        body: ["GET", "HEAD"].includes(req.method!) ? undefined : req });
      const headers = responseHeaders(response.headers, origin);
      const html = headers["content-type"]?.includes("text/html") && !headers["content-encoding"] && req.method !== "HEAD";
      if (html) { delete headers["content-length"]; delete headers.etag; }
      res.writeHead(response.statusCode, headers);
      response.body.on("error", () => res.destroy());
      if (html) response.body.pipe(new PreviewHtml()).pipe(res);
      else response.body.pipe(res);
    } catch (error) { fail(res, error); }
  });
  server.on("upgrade", async (req, socket, head) => {
    let upstream: Duplex | undefined;
    let dispose = () => {};
    const controller = new AbortController();
    const close = () => { controller.abort(); upstream?.destroy(); socket.destroy(); dispose(); };
    try {
      const row = resolveHost(req);
      const origin = previewOrigin(ctx, row);
      if (req.headers.origin !== origin || req.headers.upgrade?.toLowerCase() !== "websocket") throw new HttpError(403, "origin", "Invalid WebSocket origin.");
      if (new URL(req.url!, origin).pathname.startsWith(CONTROL)) throw new HttpError(404, "preview", "Unknown preview control.");
      const grant = await authorize(req, row);
      await manager.destination(row.trackId);
      if (row.state !== "ready") throw new HttpError(503, "starting", "Preview is not ready.");
      manager.touch(row.trackId);
      dispose = watch(row, grant, close);
      socket.once("close", close); socket.on("error", close);
      const tunnel = await spriteTunnel(ctx.config.sprites!, row.sprite!, row.port!, controller.signal);
      upstream = tunnel;
      const client = previewClient(tunnel);
      const cleanHeaders = upstreamHeaders(req.headers, new URL(origin).host, true);
      delete cleanHeaders.connection; delete cleanHeaders.upgrade; delete cleanHeaders["sec-websocket-extensions"];
      const response = await client.upgrade({ path: req.url!, protocol: "websocket", signal: controller.signal, headers: cleanHeaders });
      const remote = response.socket;
      upstream = remote;
      // Bun requires its native upgrade adapter; raw socket.write(101) is
      // unsupported on node:http's compatibility socket.
      const protocol = response.headers["sec-websocket-protocol"];
      const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 1024 * 1024,
        handleProtocols: () => typeof protocol === "string" ? protocol : false });
      wss.handleUpgrade(req, socket, head, ws => {
        const receiver = new framing.Receiver({ isServer: false, binaryType: "nodebuffer", maxPayload: 1024 * 1024 });
        const sender = new framing.Sender(remote);
        let queued = 0;
        let ended = false;
        let drain: ReturnType<typeof setInterval> | undefined;
        const end = () => { if (ended) return; ended = true; clearInterval(drain); receiver.destroy(); ws.terminate(); void client.destroy(); close(); };
        ws.on("close", end); ws.on("error", end); remote.on("error", end); remote.once("close", end);
        remote.on("data", (chunk: Buffer) => { if (!receiver.write(chunk)) remote.pause(); });
        receiver.on("drain", () => { if (ws.bufferedAmount < 64 * 1024) remote.resume(); });
        receiver.on("error", end); receiver.on("conclude", end);
        receiver.on("ping", (data: Buffer) => sender.pong(data, true, error => { if (error) end(); }));
        receiver.on("message", (data: Buffer, binary: boolean) => {
          ws.send(data, { binary }, error => { if (error) end(); });
          if (ws.bufferedAmount > 64 * 1024) {
            remote.pause();
            drain ??= setInterval(() => { if (ws.bufferedAmount < 64 * 1024) { clearInterval(drain); drain = undefined; remote.resume(); } }, 10);
          }
          if (ws.bufferedAmount > 2 * 1024 * 1024) end();
        });
        ws.on("message", (data, binary) => {
          const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
          queued += bytes.length;
          // The native browser socket cannot pause receives. Bound its queue
          // and close overloads instead of allowing unbounded pending writes.
          if (queued > 2 * 1024 * 1024) { end(); return; }
          sender.send(bytes, { binary, mask: true, fin: true, compress: false }, error => { queued -= bytes.length; if (error) end(); });
        });
      });
    } catch (error) {
      socket.end(`HTTP/1.1 ${error instanceof HttpError ? error.status : 502} Preview unavailable\r\nConnection: close\r\n\r\n`);
      controller.abort(); upstream?.destroy(); dispose();
    }
  });
  server.on("close", () => { for (const close of connections) close(); });
  return server;
}
