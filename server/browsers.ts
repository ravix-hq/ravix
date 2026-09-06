import source from "../runner/scripts/browser-worker.cjs" with { type: "text" };
import type { AppContext } from "./context";
import { authenticate, trackAccess, requireOwner } from "./context";
import type { BrowserActor, BrowserInfo, BrowserResult } from "../shared/browser";
import type { BrowserSessionRow } from "./browser-store";
import { randomToken, sha256 } from "./crypto";
import { HttpError, json, cookieValue, SESSION_COOKIE } from "./http";
import { machineOf, spriteFor } from "./tracks";
import { shq } from "./sprites";
import { STATE_DIR } from "../shared/ids";
import { spriteTunnel, previewClient } from "./sprites-tunnel";

const PORT = 40000; // Web: 20000–29999, native: 30000–39999. One browser per machine.
const SERVICE = "switchyard-browser";
const LIMIT = 16 * 1024 * 1024;
const managers = new WeakMap<AppContext, Browsers>();
export function browsers(ctx: AppContext) {
  let manager = managers.get(ctx);
  if (!manager) { manager = new Browsers(ctx); managers.set(ctx, manager); }
  return manager;
}

export class Browsers {
  private jobs = new Map<string, Promise<unknown>>();
  private holds = new Map<string, number>();
  constructor(private ctx: AppContext) {}
  available() { return !!(this.ctx.config.sharedBrowser && this.ctx.fountain && this.ctx.sprites); }
  info(projectId: string): BrowserInfo {
    const row = this.ctx.db.browsers.get(projectId);
    return { available: this.available(), session: row ? { id: row.id, profile: "shared", state: row.state, error: row.error } : null,
      checkpoints: row ? this.ctx.db.browsers.checkpoints(row.id) : [] };
  }
  serial<T>(projectId: string, fn: () => Promise<T>): Promise<T> {
    const job = (this.jobs.get(projectId) ?? Promise.resolve()).catch(() => {}).then(fn);
    this.jobs.set(projectId, job);
    void job.finally(() => { if (this.jobs.get(projectId) === job) this.jobs.delete(projectId); }).catch(() => {});
    return job;
  }
  async destination(projectId: string) {
    const project = this.ctx.db.project(projectId);
    if (!project || project.archivedAt) throw new HttpError(404, "not_found", "No such project.");
    const machine = await machineOf(this.ctx.fountain!, project);
    const sprite = machine && await spriteFor(this.ctx.fountain!, machine.sandboxId);
    if (!machine || !sprite) throw new HttpError(409, "browser_machine", "Open a track to create this project's machine first.");
    return { sandboxId: machine.sandboxId, sprite };
  }
  async start(projectId: string, authorize: () => void) {
    if (!this.available()) throw new HttpError(501, "browser_unavailable", "Shared browser requires SHARED_BROWSER=1, Fountain, and Sprites.");
    return this.serial(projectId, async () => {
      authorize();
      const actual = await this.destination(projectId); authorize();
      let row = this.ctx.db.browsers.get(projectId);
      if (!row) {
        row = { id: randomToken(16), projectId, profile: "shared", sprite: null, sandboxId: null, state: "stopped", error: null, tokenEnc: await this.ctx.cipher.encrypt(randomToken()) };
        this.ctx.db.browsers.save(row);
      }
      if (row.sprite && row.sprite !== actual.sprite) await this.ctx.sprites!.serviceAction(row.sprite, SERVICE, "stop");
      const dir = `${STATE_DIR}/browsers/${row.id}`;
      const runtime = `${STATE_DIR}/browser-runtime-1.63.0`;
      const worker = `${runtime}/worker-${(await sha256(source)).slice(0, 12)}.cjs`;
      const command = `SWITCHYARD_BROWSER_DIR=${shq(dir)} exec node ${shq(worker)}`;
      try {
        const service = await this.ctx.sprites!.service(actual.sprite, SERVICE); authorize();
        const matches = service?.cmd === "sh" && JSON.stringify(service.args) === JSON.stringify(["-lc", command]) && service.env?.PORT === String(PORT) && service.http_port == null;
        if (!matches) {
          if (service) await this.ctx.sprites!.serviceAction(actual.sprite, SERVICE, "stop");
          authorize();
          const token = await this.ctx.cipher.decrypt(row.tokenEnc);
          const prepare = await this.ctx.sprites!.exec(actual.sprite, ["sh", "-lc", `set -eu; umask 077; mkdir -p ${shq(dir)} ${shq(runtime)}; printf %s ${shq(token)} > ${shq(dir + "/token")}; : > ${shq(worker + ".tmp")}`], 15);
          if (prepare.code) throw new HttpError(502, "browser_setup", "Could not prepare the browser's private state directory.");
          // Sprites exec encodes argv in the URL. Bound each source upload.
          for (let offset = 0; offset < source.length; offset += 2000) {
            authorize();
            const chunk = await this.ctx.sprites!.exec(actual.sprite, ["sh", "-lc", `printf %s ${shq(source.slice(offset, offset + 2000))} >> ${shq(worker + ".tmp")}`], 15);
            if (chunk.code) throw new HttpError(502, "browser_setup", "Could not upload the browser worker.");
          }
          const setup = `set -eu\numask 077\nmv ${shq(worker + ".tmp")} ${shq(worker)}\nif [ ! -f ${shq(runtime + "/node_modules/playwright-core/package.json")} ]; then npm install --prefix ${shq(runtime)} --no-audit --no-fund playwright-core@1.63.0; fi\nnode ${shq(runtime + "/node_modules/playwright-core/cli.js")} install chromium`;
          const result = await this.ctx.sprites!.exec(actual.sprite, ["sh", "-lc", setup], 240);
          if (result.code) throw new HttpError(502, "browser_setup", "Browser setup failed. The machine needs Node/npm and Chromium's system libraries; check the shared browser setup instructions.");
          authorize();
          if (service) await this.ctx.sprites!.serviceAction(actual.sprite, SERVICE, "delete");
          await this.ctx.sprites!.defineService(actual.sprite, SERVICE, dir, command, PORT);
        } else if (service?.state?.status !== "running") await this.ctx.sprites!.serviceAction(actual.sprite, SERVICE, "start");
        row = { ...row, ...actual, state: "stopped", error: null }; this.ctx.db.browsers.save(row);
        let ready = false;
        for (let attempt = 0; attempt < 15; attempt++) {
          authorize();
          try { await this.transport(row, { action: "status" }); ready = true; break; }
          catch { await new Promise(resolve => setTimeout(resolve, 1000)); }
        }
        if (!ready) throw new HttpError(502, "browser_start", "Chromium did not become ready. Check the switchyard-browser service logs on the machine.");
        authorize(); this.ctx.db.browsers.save({ ...row, state: "ready", error: null });
      } catch (error) {
        this.ctx.db.browsers.save({ ...row, ...actual, state: "failed", error: error instanceof HttpError ? error.message : "Could not start the shared browser. Check the machine connection and service logs." });
        throw error;
      }
      return this.info(projectId);
    });
  }
  async stop(projectId: string) {
    return this.serial(projectId, async () => {
      const row = this.ctx.db.browsers.get(projectId);
      if (row?.sprite) {
        await this.ctx.sprites!.serviceAction(row.sprite, SERVICE, "stop");
        await this.ctx.sprites!.activity(row.sprite, SERVICE, true);
        this.ctx.db.browsers.save({ ...row, state: "stopped", error: null });
      }
    });
  }
  async current(projectId: string, authorize: () => void) {
    if (!this.available()) throw new HttpError(501, "browser_unavailable", "Shared browser is unavailable.");
    const row = this.ctx.db.browsers.get(projectId);
    if (!row?.sprite || row.state !== "ready") throw new HttpError(409, "browser_stopped", "Open the shared browser first.");
    const actual = await this.destination(projectId); authorize();
    if (row.sprite !== actual.sprite || row.sandboxId !== actual.sandboxId) throw new HttpError(409, "browser_replaced", "The machine changed. Open the browser, then restore a checkpoint if needed.");
    return row;
  }
  /** Private, bounded JSON RPC; never expose the remote endpoint or credential. */
  async transport(row: BrowserSessionRow, command: Record<string, unknown>): Promise<BrowserResult> {
    const stream = await spriteTunnel(this.ctx.config.sprites!, row.sprite!, PORT);
    const client = previewClient(stream);
    try {
      const response = await client.request({ method: "POST", path: "/command", headers: { authorization: `Bearer ${await this.ctx.cipher.decrypt(row.tokenEnc)}`, "content-type": "application/json" }, body: JSON.stringify(command), signal: AbortSignal.timeout(45_000) });
      let length = 0; const chunks: Buffer[] = [];
      for await (const chunk of response.body) { const bytes = Buffer.from(chunk); length += bytes.length; if (length > LIMIT) throw new HttpError(413, "browser_size", "Browser state exceeds the 16 MB checkpoint limit."); chunks.push(bytes); }
      const value = JSON.parse(Buffer.concat(chunks).toString());
      if (response.statusCode !== 200) throw new HttpError(response.statusCode, "browser_command", String(value.error || "Browser command failed."));
      return value;
    } finally { await client.destroy(); stream.destroy(); }
  }
  async execute(projectId: string, body: Record<string, unknown>, actor: BrowserActor, authorize: () => void) {
    return this.serial(projectId, async () => {
      const row = await this.current(projectId, authorize);
      const allowed = ["status", "acquire", "release", "open", "navigate", "close", "back", "forward", "reload", "inspect", "screenshot", "click", "scroll", "text", "key"];
      if (!allowed.includes(String(body.action))) throw new HttpError(422, "browser_action", "Unknown browser command.");
      // Touch only while someone is watching or operating. The disk profile survives parking.
      if ((this.holds.get(row.id) ?? 0) < Date.now() - 30000) {
        await this.ctx.sprites!.activity(row.sprite!, SERVICE); this.holds.set(row.id, Date.now()); authorize();
      }
      const result = await this.transport(row, { ...body, actor });
      authorize(); return result;
    });
  }
  async checkpoint(projectId: string, label: string, actor: BrowserActor, authorize: () => void) {
    return this.serial(projectId, async () => {
      const row = await this.current(projectId, authorize);
      if (this.ctx.db.browsers.checkpoints(row.id).length >= 20) throw new HttpError(409, "browser_checkpoints", "Delete a checkpoint before saving another (limit 20).");
      const payload = await this.transport(row, { action: "checkpoint", actor }); authorize();
      const payloadEnc = await this.ctx.cipher.encrypt(JSON.stringify(payload)); authorize();
      const cp = { id: randomToken(16), sessionId: row.id, label: label.trim().slice(0, 120) || "Browser checkpoint", createdAt: new Date().toISOString() };
      this.ctx.db.browsers.addCheckpoint(cp, this.ctx.db.project(projectId)!.userId, payloadEnc);
      return cp;
    });
  }
  async restore(projectId: string, checkpointId: string, ownerId: string, actor: BrowserActor, authorize: () => void) {
    return this.serial(projectId, async () => {
      const row = await this.current(projectId, authorize);
      const cp = this.ctx.db.browsers.checkpoint(checkpointId);
      if (!cp || cp.ownerId !== ownerId || this.ctx.db.project(projectId)?.userId !== ownerId) throw new HttpError(404, "not_found", "No such browser checkpoint.");
      const checkpoint = JSON.parse(await this.ctx.cipher.decrypt(cp.payloadEnc)); authorize();
      return this.transport(row, { action: "restore", checkpoint, actor });
    });
  }
}

export async function browserBody(req: Request): Promise<Record<string, unknown>> {
  if (!req.headers.get("content-type")?.startsWith("application/json")) throw new HttpError(415, "browser_json", "Use application/json.");
  const text = await req.text();
  if (text.length > 24000) throw new HttpError(413, "browser_size", "Browser command is too large.");
  let value;
  try { value = JSON.parse(text); } catch { throw new HttpError(400, "bad_json", "Invalid browser command JSON."); }
  if (!value || Array.isArray(value) || typeof value !== "object") throw new HttpError(422, "browser_action", "Supply a browser command.");
  return value;
}
export async function browserRoute(ctx: AppContext, req: Request, trackId: string, action?: string) {
  const user = await authenticate(ctx, req);
  const sessionHash = await sha256(cookieValue(req, SESSION_COOKIE)!);
  const authorize = () => {
    if (!ctx.db.sessionUser(sessionHash)) throw new HttpError(401, "unauthenticated", "Sign in again to use the browser.");
    const access = trackAccess(ctx, user, trackId); if (access.track.closedAt) throw new HttpError(409, "track_closed", "This track is closed."); return access;
  };
  const access = authorize(), manager = browsers(ctx), projectId = access.project.id;
  if (!action) return json({ data: manager.info(projectId) }, 200, { "cache-control": "no-store" });
  if (req.headers.get("origin") !== new URL(ctx.config.publicUrl).origin) throw new HttpError(403, "origin", "Open the browser from Switchyard.");
  const body = await browserBody(req);
  if (typeof body.clientId !== "string" || !/^[a-f0-9-]{36}$/.test(body.clientId)) throw new HttpError(422, "browser_client", "Supply a browser client identity.");
  const actor: BrowserActor = { id: `human:${user.id}:${body.clientId}`, label: `@${user.login}`, kind: "human" };
  if (action === "start") return json({ data: await manager.start(projectId, authorize) });
  if (action === "stop") { requireOwner(access.role, "stop the shared browser"); await manager.stop(projectId); return json({ data: manager.info(projectId) }); }
  if (action === "command") return json({ data: await manager.execute(projectId, body, actor, authorize) }, 200, { "cache-control": "no-store" });
  if (action === "checkpoint") return json({ data: await manager.checkpoint(projectId, String(body.label ?? ""), actor, authorize) });
  if (action === "restore") { requireOwner(access.role, "restore the shared browser"); return json({ data: await manager.restore(projectId, String(body.checkpointId), user.id, actor, authorize) }); }
  if (action === "delete-checkpoint") {
    requireOwner(access.role, "delete browser checkpoints");
    const cp = ctx.db.browsers.checkpoint(String(body.checkpointId));
    if (!cp || cp.sessionId !== ctx.db.browsers.get(projectId)?.id) throw new HttpError(404, "not_found", "No such browser checkpoint.");
    ctx.db.browsers.deleteCheckpoint(cp.id); return json({ data: manager.info(projectId) });
  }
  throw new HttpError(404, "not_found", "Unknown browser operation.");
}
