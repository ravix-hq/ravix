import type { Client } from "undici-node";
import type { PreviewConfig, PreviewInfo } from "../shared/previews";
import type { AppContext } from "./context";
import { authenticate, projectOf, trackAccess } from "./context";
import { HttpError, json, readJson, cookieValue, SESSION_COOKIE } from "./http";
import { randomToken, sha256 } from "./crypto";
import type { PreviewRow } from "./preview-store";
import { machineOf, spriteFor } from "./tracks";
import { resolveCwd, SpritesError } from "./sprites";
import { spriteTunnel, previewClient } from "./sprites-tunnel";

const LEASE_MS = 90_000;
const IDLE_MS = 5 * 60_000;
const START_MS = 60_000;
const managers = new WeakMap<AppContext, Previews>();
export function previews(ctx: AppContext): Previews {
  let manager = managers.get(ctx);
  if (!manager) { manager = new Previews(ctx); managers.set(ctx, manager); }
  return manager;
}
export function previewOrigin(ctx: AppContext, row: PreviewRow): string {
  const cfg = ctx.config.previews;
  if (!cfg) throw new HttpError(501, "preview_unavailable", "PREVIEW_DOMAIN is not configured.");
  return `${cfg.protocol}//${row.hostname}.${cfg.domain}${cfg.publicPort}`;
}
export function parsePreviewConfig(value: unknown): PreviewConfig | null {
  if (value === null) return null;
  if (!value || typeof value !== "object") throw new HttpError(422, "preview_config", "Supply a preview configuration.");
  const { directory, command, readinessPath } = value as Record<string, unknown>;
  if (typeof directory !== "string" || directory.length > 1000 || directory.startsWith("/") || directory.split("/").includes("..") || /[\x00-\x1f]/.test(directory)) {
    throw new HttpError(422, "preview_directory", "Choose a relative app directory inside this track.");
  }
  if (typeof command !== "string" || !command.trim() || command.length > 8000 || command.includes("\0")) throw new HttpError(422, "preview_command", "Supply a startup command that honors $PORT and fails if that port is occupied.");
  if (typeof readinessPath !== "string" || !readinessPath.startsWith("/") || readinessPath.startsWith("//") || readinessPath.length > 1000 || /[\x00-\x20#\\]/.test(readinessPath)) {
    throw new HttpError(422, "preview_readiness", "Readiness must be an HTTP path on this app, such as /health.");
  }
  return { directory: directory.trim() || ".", command: command.trim(), readinessPath };
}

export class Previews {
  private operations = new Map<string, Promise<void>>();
  private timer?: ReturnType<typeof setInterval>;
  private ticking = false;
  private holds = new Map<string, number>();
  private destinations = new Map<string, Promise<{ sandboxId: string; sprite: string }>>();
  constructor(readonly ctx: AppContext) {}
  unavailable(): string | null {
    if (!this.ctx.sprites) return "Previews unavailable: SPRITES_TOKEN is not configured.";
    if (!this.ctx.config.previews) return "Previews unavailable: PREVIEW_DOMAIN and gateway routing are not configured.";
    if (!this.ctx.fountain) return "Previews unavailable: Fountain is not configured.";
    return null;
  }
  info(trackId: string): PreviewInfo {
    const row = this.ctx.db.previews.ensure(trackId);
    const track = this.ctx.db.track(trackId)!;
    const why = this.unavailable() || row.unavailable || null;
    return { available: !why, unavailableReason: why, config: row.config ?? this.ctx.db.previews.defaults(track.projectId), override: row.config,
      state: row.state, error: row.error, logs: row.logs, url: why ? null : previewOrigin(this.ctx, row) };
  }
  assertOpen(trackId: string) {
    const track = this.ctx.db.track(trackId);
    const project = track && this.ctx.db.project(track.projectId);
    if (!track || track.closedAt || !project || project.archivedAt || this.ctx.db.previews.get(trackId)?.cleanup) throw new HttpError(409, "closed_track", "This track is closed or being retired.");
    return { track, project };
  }
  private serial(trackId: string, action: () => Promise<void>): Promise<void> {
    const previous = this.operations.get(trackId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(action);
    this.operations.set(trackId, next);
    void next.finally(() => { if (this.operations.get(trackId) === next) this.operations.delete(trackId); }).catch(() => {});
    return next;
  }
  private current(row: PreviewRow) {
    const fresh = this.ctx.db.previews.get(row.trackId);
    return !!fresh && fresh.generation === row.generation && fresh.desired === "running" && !fresh.cleanup;
  }
  private update(row: PreviewRow, changes: Partial<PreviewRow>) {
    const fresh = this.ctx.db.previews.get(row.trackId);
    if (!fresh || fresh.generation !== row.generation) return;
    this.ctx.db.previews.save({ ...fresh, ...changes });
  }
  touch(trackId: string) {
    this.assertOpen(trackId);
    const row = this.ctx.db.previews.ensure(trackId);
    const now = Date.now();
    this.ctx.db.previews.save({ ...row, lastActivity: now, leaseUntil: now + LEASE_MS });
  }
  async destination(trackId: string): Promise<PreviewRow> {
    const { project } = this.assertOpen(trackId);
    let pending = this.destinations.get(project.id);
    if (!pending) {
      pending = (async () => {
        const machine = await machineOf(this.ctx.fountain!, project);
        if (!machine) throw new HttpError(409, "no_machine", "The workspace is not available.");
        const sprite = await spriteFor(this.ctx.fountain!, machine.sandboxId);
        if (!sprite) throw new HttpError(501, "preview_unavailable", "This workspace does not expose a Sprite.");
        return { sandboxId: machine.sandboxId, sprite };
      })();
      this.destinations.set(project.id, pending);
      void pending.finally(() => this.destinations.delete(project.id)).catch(() => {});
    }
    const actual = await pending;
    const row = this.ctx.db.previews.get(trackId)!;
    if (row.sprite !== actual.sprite || row.sandboxId !== actual.sandboxId) {
      // End existing connections and defer traffic until reconciliation has
      // retired the previous service and passed readiness on the replacement.
      void this.startService(trackId, true).catch(() => {});
      throw new HttpError(503, "preview_replaced", "The workspace changed. Open the preview again while its service restarts.");
    }
    return row;
  }
  startService(trackId: string, restart = false): Promise<void> {
    this.assertOpen(trackId);
    const why = this.unavailable();
    if (why) throw new HttpError(501, "preview_unavailable", why);
    this.touch(trackId);
    const row = this.ctx.db.previews.ensure(trackId);
    if (restart || row.desired !== "running") {
      this.ctx.db.previews.save({ ...row, desired: "running", state: "starting", error: null, unavailable: null, stopPending: false, generation: row.generation + 1, startedAt: Date.now() });
    }
    const generation = this.ctx.db.previews.get(trackId)!.generation;
    return this.serial(trackId, async () => {
      if (this.ctx.db.previews.get(trackId)?.generation === generation) await this.ensureRunning(trackId, restart);
    });
  }
  async stopService(trackId: string, cleanup = false): Promise<void> {
    if (cleanup) this.ctx.db.previews.revokeAgent(trackId);
    const row = this.ctx.db.previews.get(trackId);
    if (!row) return;
    this.ctx.db.previews.save({ ...row, desired: "stopped", state: "stopped", leaseUntil: 0, generation: row.generation + 1, cleanup: cleanup || row.cleanup, stopPending: true });
    this.ctx.db.previews.revoke(trackId);
    const current = this.ctx.db.previews.get(trackId)!;
    await this.serial(trackId, async () => {
      await this.retire(current, cleanup);
      this.update(current, { state: "stopped", error: null, stopPending: false, ...(cleanup ? { sprite: null, sandboxId: null, port: null, appliedConfig: null } : {}) });
    });
  }
  async configure(trackId: string, config: PreviewConfig | null) {
    this.assertOpen(trackId);
    const row = this.ctx.db.previews.ensure(trackId);
    const next = { ...row, config, appliedConfig: null, desired: "stopped" as const, state: "stopped" as const,
      generation: row.generation + 1, leaseUntil: 0, stopPending: true };
    this.ctx.db.previews.save(next);
    this.ctx.db.previews.revoke(trackId);
    await this.serial(trackId, async () => { await this.retire(next, false); this.update(next, { stopPending: false }); });
  }

  private async retire(row: PreviewRow, remove: boolean) {
    if (!row.sprite) return;
    if (!this.ctx.sprites) throw new HttpError(501, "preview_unavailable", "Restore SPRITES_TOKEN to stop the saved preview service.");
    await this.ctx.sprites.serviceAction(row.sprite, row.service, "stop");
    await this.ctx.sprites.activity(row.sprite, row.service, true);
    this.holds.delete(row.trackId);
    if (remove) await this.ctx.sprites.serviceAction(row.sprite, row.service, "delete");
  }
  private async hold(row: PreviewRow) {
    if (!row.sprite || row.leaseUntil <= Date.now() || (this.holds.get(row.trackId) ?? 0) > Date.now() - 30_000) return;
    await this.ctx.sprites!.activity(row.sprite, row.service);
    this.holds.set(row.trackId, Date.now());
  }
  private async ensureRunning(trackId: string, restart: boolean) {
    let row = this.ctx.db.previews.get(trackId)!;
    if (!this.current(row)) return;
    try {
      const { track, project } = this.assertOpen(trackId);
      const config = row.config ?? this.ctx.db.previews.defaults(project.id);
      if (!config) throw new Error("Save a preview startup command and app directory first.");
      const machine = await machineOf(this.ctx.fountain!, project);
      if (!machine) throw new Error("This project has no machine. Open a track first.");
      const sprite = await spriteFor(this.ctx.fountain!, machine.sandboxId);
      if (!sprite) throw new SpritesError(501, "This workspace does not expose a Sprite. Previews are unavailable.");
      if (!this.current(row)) return;
      if (row.sprite && (row.sprite !== sprite || row.sandboxId !== machine.sandboxId)) {
        await this.retire(row, true);
        if (!this.current(row)) return;
        this.update(row, { sprite: null, port: null, appliedConfig: null, state: "starting", generation: row.generation + 1 });
        row = this.ctx.db.previews.get(trackId)!;
      }
      row = this.ctx.db.previews.allocate(trackId, machine.sandboxId, sprite);
      const applied = JSON.stringify(config);
      const service = await this.ctx.sprites!.service(sprite, row.service);
      const directory = resolveCwd(track.workdir, config.directory);
      const matches = service?.cmd === "sh" && JSON.stringify(service.args) === JSON.stringify(["-lc", config.command]) &&
        service.dir === directory && service.env?.PORT === String(row.port) && service.env?.HOST === "127.0.0.1" &&
        service.http_port == null && !service.needs?.length;
      if (!this.current(row)) return;
      if (restart || row.appliedConfig !== applied || !matches) {
        if (service) await this.ctx.sprites!.serviceAction(sprite, row.service, "stop");
        if (!this.current(row)) return;
        // PUT can return 200 "already running with that command" while
        // retaining old args, env or cwd, even after stop. Replace this
        // track's owned definition so the saved configuration really applies.
        if (service) await this.ctx.sprites!.serviceAction(sprite, row.service, "delete");
        if (!this.current(row)) return;
        // Refuse a collision before creating a service. Readiness below only
        // examines the allocated port, so a server's fallback is never Ready.
        const check = await this.ctx.sprites!.exec(sprite, ["sh", "-lc", `command -v ss >/dev/null || { echo "Cannot verify preview port: ss is unavailable." >&2; exit 1; }; if ss -H -ltn 'sport = :${row.port}' | read line; then echo 'Preview port ${row.port} is occupied. Stop the conflicting process.' >&2; exit 1; fi`], 15);
        if (check.code) throw new Error(check.stderr || "Preview port collision.");
        if (!this.current(row)) return;
        const logs = await this.ctx.sprites!.defineService(sprite, row.service, directory, config.command, row.port!);
        this.update(row, { appliedConfig: applied, state: "starting", logs, startedAt: Date.now() });
      } else if (service.state?.status !== "running") {
        const logs = await this.ctx.sprites!.serviceAction(sprite, row.service, "start");
        this.update(row, { state: "starting", logs, startedAt: Date.now() });
      }
      if (!this.current(row)) return;
      await this.hold(this.ctx.db.previews.get(trackId)!);
      const deadline = Date.now() + START_MS;
      do {
        if (!this.current(row)) return;
        const actual = await this.ctx.sprites!.service(sprite, row.service);
        if ((actual?.state?.restart_count ?? 0) >= 3) throw new Error("Preview crashed repeatedly. Fix the startup command, then restart. See logs below.");
        if (actual?.state?.status === "running" && await this.ready(row, config.readinessPath)) {
          // A machine replacement during startup cannot publish an old result.
          const now = await machineOf(this.ctx.fountain!, project);
          if (now?.sandboxId !== row.sandboxId) throw new Error("The workspace changed during startup. Open the preview again.");
          this.update(row, { state: "ready", error: null });
          return;
        }
        await Bun.sleep(500);
      } while (Date.now() < deadline);
      throw new Error(`Readiness did not pass at ${config.readinessPath} on $PORT=${row.port}. The command must honor $PORT and fail on a collision.`);
    } catch (error) {
      if (!this.current(row)) return;
      const message = error instanceof Error ? error.message : "Preview startup failed.";
      let logs = row.logs;
      if (row.sprite) {
        logs = await this.ctx.sprites!.serviceLogs(row.sprite, row.service).catch(() => logs);
        await this.retire(row, false).catch(() => { this.update(row, { stopPending: true }); });
      }
      this.update(row, { state: "failed", desired: "stopped", error: message, logs,
        unavailable: error instanceof SpritesError && [404, 501].includes(error.status) ? message : null });
    }
  }
  async ready(row: PreviewRow, path: string): Promise<boolean> {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 3000);
    let client: Client | undefined;
    try {
      const stream = await spriteTunnel(this.ctx.config.sprites!, row.sprite!, row.port!, abort.signal);
      client = previewClient(stream);
      const res = await client.request({ path, method: "GET", signal: abort.signal, headers: { host: new URL(previewOrigin(this.ctx, row)).host } });
      res.body.destroy();
      return res.statusCode >= 200 && res.statusCode < 400;
    } catch { return false; }
    finally { clearTimeout(timer); abort.abort(); await client?.destroy(); }
  }

  async refreshLogs(trackId: string) {
    const row = this.ctx.db.previews.get(trackId);
    if (this.ctx.sprites && row?.sprite && row.desired === "running") {
      const logs = await this.ctx.sprites.serviceLogs(row.sprite, row.service);
      const fresh = this.ctx.db.previews.get(trackId)!;
      if (fresh.generation === row.generation) this.ctx.db.previews.save({ ...fresh, logs });
    }
  }

  start() {
    if (this.timer || this.unavailable()) return;
    void this.tick();
    this.timer = setInterval(() => void this.tick(), 15_000);
    this.timer.unref();
  }
  stop() { clearInterval(this.timer); this.timer = undefined; }
  async tick() {
    if (this.ticking || this.unavailable()) return;
    this.ticking = true;
    try {
      await Promise.all(this.ctx.db.previews.all().map(async row => {
        try {
          const track = this.ctx.db.track(row.trackId);
          const project = track && this.ctx.db.project(track.projectId);
          if (!track || track.closedAt || !project || project.archivedAt || row.cleanup) {
            if (row.sprite) await this.stopService(row.trackId, true);
          } else if (row.stopPending) {
            await this.stopService(row.trackId);
          } else if (row.desired === "running") {
            if (Date.now() - row.lastActivity > IDLE_MS) await this.stopService(row.trackId);
            else if (row.leaseUntil > Date.now() && !this.operations.has(row.trackId)) await this.serial(row.trackId, () => this.ensureRunning(row.trackId, false));
          }
        } catch (error) { console.error("switchyard: preview reconciliation", row.trackId, error instanceof Error ? error.message : "failed"); }
      }));
    } finally { this.ticking = false; }
  }
}

export async function previewRoute(ctx: AppContext, req: Request, trackId: string, action = "status"): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track } = trackAccess(ctx, user, trackId);
  if (track.closedAt) throw new HttpError(409, "closed_track", "This track is closed.");
  const manager = previews(ctx);
  if (req.method !== "GET" && req.headers.get("origin") !== new URL(ctx.config.publicUrl).origin) throw new HttpError(403, "origin", "Open preview controls from Switchyard.");
  if (action === "config") await manager.configure(trackId, parsePreviewConfig((await readJson(req)).config));
  if (action === "stop") await manager.stopService(trackId);
  if (action === "logs") {
    // Persisted failure logs remain available without waking an idle machine.
    await manager.refreshLogs(trackId);
  }
  if (action === "open" || action === "restart") {
    void manager.startService(trackId, action === "restart").catch(() => {});
    const row = ctx.db.previews.ensure(trackId);
    const ticket = randomToken();
    ctx.db.previews.grant({ hash: await sha256(ticket), trackId, sessionHash: await sha256(cookieValue(req, SESSION_COOKIE)!), expires: Date.now() + 60_000, kind: "ticket" });
    return json({ data: { ...manager.info(trackId), openUrl: `${previewOrigin(ctx, row)}/__switchyard/open#${ticket}` } }, 202, { "cache-control": "no-store" });
  }
  return json({ data: manager.info(trackId) }, 200, { "cache-control": "no-store" });
}
export async function previewDefaults(ctx: AppContext, req: Request, projectId: string) {
  const user = await authenticate(ctx, req);
  projectOf(ctx, user, projectId);
  if (req.method === "PUT") {
    if (req.headers.get("origin") !== new URL(ctx.config.publicUrl).origin) throw new HttpError(403, "origin", "Open settings from Switchyard.");
    const config = parsePreviewConfig((await readJson(req)).config);
    ctx.db.previews.setDefaults(projectId, config);
    await Promise.all(ctx.db.tracksOf(projectId).filter(track => !ctx.db.previews.get(track.id)?.config).map(track => previews(ctx).stopService(track.id)));
  }
  return json({ data: ctx.db.previews.defaults(projectId) });
}
