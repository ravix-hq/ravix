import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Db } from "./db";
import { loadConfig } from "./config";
import { buildContext } from "./context";
import { Cipher, sha256 } from "./crypto";
import { previews, parsePreviewConfig } from "./previews";
import { buildRouter } from "./app";
import { Sprites, type SpriteService } from "./sprites";
import { prepareAgentPreview } from "./agent-previews";

const cleanup: (() => void)[] = [];
afterEach(() => { for (const c of cleanup.splice(0).reverse()) c(); });
async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "sy-previews-"));
  const state = { sandbox: "s1", reads: 0, ready: true, crash: 0, collide: false, creates: 0, stops: [] as string[], deletes: [] as string[], holds: [] as string[],
    services: new Map<string, string>(), definitions: new Map<string, SpriteService>(), barrier: null as Promise<void> | null, failStop: false, execs: [] as string[][] };
  const upstream = Bun.serve({ port: 0, fetch(req) {
    state.reads++;
    return Response.json({ data: new URL(req.url).pathname === "/api/conversations"
      ? [{ id: "c", sandbox_id: state.sandbox, status: "idle", inserted_at: "2026-09-05" }]
      : { id: state.sandbox, sprite_name: state.sandbox } });
  } });
  const config = loadConfig({ DATA_DIR: dir, SWITCHYARD_SECRET: "preview-test-secret-long-enough", PUBLIC_URL: "http://localhost:5183", FOUNTAIN_URL: `http://localhost:${upstream.port}`, FOUNTAIN_API_KEY: "test", SPRITES_TOKEN: "test", PREVIEW_DOMAIN: "preview.localhost" });
  const db = new Db(config.dbPath);
  const ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
  class Provider extends Sprites {
    async service(sprite: string, name: string) { const status = state.services.get(`${sprite}/${name}`); return status ? { ...state.definitions.get(`${sprite}/${name}`), name, state: { status, restart_count: state.crash } } : null; }
    async defineService(sprite: string, name: string, directory: string, command: string, port: number) { state.creates++; await state.barrier; state.services.set(`${sprite}/${name}`, "running"); state.definitions.set(`${sprite}/${name}`, { name, cmd: "sh", args: ["-lc", command], dir: directory, env: { PORT: String(port), HOST: "127.0.0.1" } }); return "startup logs"; }
    async serviceAction(sprite: string, name: string, action: "start" | "stop" | "delete") {
      const id = `${sprite}/${name}`;
      if (action === "stop") { if (state.failStop) throw new Error("offline"); state.stops.push(id); state.services.set(id, "stopped"); }
      if (action === "delete") { state.deletes.push(id); state.services.delete(id); }
      if (action === "start") state.services.set(id, "running");
      return "";
    }
    async serviceLogs() { return "Error: command not found"; }
    async activity(sprite: string, name: string, release = false) { state.holds.push(`${sprite}/${name}/${release}`); }
    async exec(_sprite: string, argv: string[]) { state.execs.push(argv); return { stdout: "", stderr: state.collide ? "Port occupied" : "", code: state.collide ? 1 : 0 }; }
  }
  ctx.sprites = new Provider({ token: "test", baseUrl: "unused" });
  const owner = db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "test" });
  const guest = db.upsertUser({ githubId: "2", login: "bo", name: "Bo", avatarUrl: null, tokenEnc: "test" });
  db.createProject({ id: "p", userId: owner.id, name: "Demos", repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null, agentId: "a", environmentId: "e", vaultId: null, runtime: "claude", model: "test", instructions: "" });
  for (const id of ["t1", "t2"]) db.createTrack({ id, projectId: "p", conversationId: id, slug: id, title: id, branch: id, workdir: `/work/${id}`, originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login });
  for (const user of [owner, guest]) db.createSession(user.id, await sha256(user.login), 60_000);
  db.previews.setDefaults("p", { directory: "apps/demo", command: 'npm run dev -- --port "$PORT" --strictPort', readinessPath: "/health" });
  const manager = previews(ctx); manager.ready = async () => state.ready;
  const router = buildRouter(ctx);
  const request = (path: string, method = "GET", body?: unknown, login = "ana", origin = config.publicUrl) => router(new Request(`http://localhost${path}`, {
    method, headers: { cookie: `switchyard_session=${login}`, origin, "content-type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}),
  }));
  cleanup.push(() => { manager.stop(); ctx.db.close(); upstream.stop(true); rmSync(dir, { recursive: true, force: true }); });
  return { ctx, state, manager, request, owner, guest };
}

test("configuration is confined to the worktree and readiness cannot select another host", () => {
  for (const directory of ["../other", "/etc", "a/../../b", "a\0b"]) expect(() => parsePreviewConfig({ directory, command: "run", readinessPath: "/" })).toThrow();
  for (const readinessPath of ["//evil", "https://evil", "/\r\n", "/#fragment"]) expect(() => parsePreviewConfig({ directory: ".", command: "run", readinessPath })).toThrow();
});

test("members operate only their tracks, defaults remain owner controlled, closed tracks reject owners too", async () => {
  const f = await fixture();
  expect((await f.request("/api/tracks/t1/preview", "GET", undefined, "bo")).status).toBe(404);
  f.ctx.db.addMember("t1", f.guest.id, f.owner.id);
  expect((await f.request("/api/tracks/t1/preview", "GET", undefined, "bo")).status).toBe(200);
  expect((await f.request("/api/projects/p/preview", "GET", undefined, "bo")).status).toBe(404);
  expect((await f.request("/api/tracks/t1/preview/stop", "POST", undefined, "bo", "http://evil")).status).toBe(403);
  f.ctx.db.closeTrack("t1");
  expect((await f.request("/api/tracks/t1/preview", "GET")).status).toBe(409);
});

test("parallel starts allocate different ports and repeated opens are idempotent", async () => {
  const f = await fixture();
  await Promise.all([f.manager.startService("t1"), f.manager.startService("t2"), f.manager.startService("t1")]);
  const a = f.ctx.db.previews.get("t1")!, b = f.ctx.db.previews.get("t2")!;
  expect(a.port).not.toBe(b.port); expect(a.hostname).not.toBe(b.hostname); expect(a.state).toBe("ready"); expect(b.state).toBe("ready");
  expect(f.state.creates).toBe(2);
  await f.manager.stopService("t1");
  expect(f.state.services.get(`${b.sprite}/${b.service}`)).toBe("running"); expect(f.ctx.db.previews.get("t2")!.state).toBe("ready");
});

test("allocation remains unique across SQLite connections", async () => {
  const f = await fixture(); const second = new Db(f.ctx.config.dbPath);
  try {
    const a = f.ctx.db.previews.allocate("t1", "s1", "sprite"); const b = second.previews.allocate("t2", "s1", "sprite");
    expect(a.port).not.toBe(b.port);
    expect(() => second.previews.save({ ...b, port: a.port })).toThrow();
  } finally { second.close(); }
});

test("a stop during service creation rejects the stale readiness result", async () => {
  const f = await fixture(); let release!: () => void;
  f.state.barrier = new Promise(resolve => { release = resolve; });
  const starting = f.manager.startService("t1");
  while (!f.state.creates) await Bun.sleep(5);
  const stopping = f.manager.stopService("t1"); release(); await Promise.all([starting, stopping]);
  expect(f.ctx.db.previews.get("t1")!.state).toBe("stopped");
  expect([...f.state.services.values()]).toEqual(["stopped"]);
});

test("configuration change during startup cannot publish an old service as Ready", async () => {
  const f = await fixture(); let release!: () => void;
  f.state.barrier = new Promise(resolve => { release = resolve; });
  const starting = f.manager.startService("t1"); while (!f.state.creates) await Bun.sleep(5);
  const configuring = f.manager.configure("t1", { directory: "app2", command: "new command", readinessPath: "/" });
  release(); await Promise.all([starting, configuring]);
  expect(f.manager.info("t1").state).toBe("stopped"); expect(f.manager.info("t1").config!.directory).toBe("app2");
  await f.manager.startService("t1"); expect(f.manager.info("t1").state).toBe("ready");
});

test("port collisions and repeated crashes fail with logs, without an endless supervisor restart loop", async () => {
  const f = await fixture(); f.state.collide = true;
  await f.manager.startService("t1"); expect(f.manager.info("t1").error).toContain("Port occupied"); expect(f.state.creates).toBe(0);
  f.state.collide = false; f.state.crash = 3;
  await f.manager.startService("t1"); expect(f.manager.info("t1").state).toBe("failed"); expect(f.manager.info("t1").logs).toContain("command not found");
  const created = f.state.creates; await f.manager.tick(); expect(f.state.creates).toBe(created);
});

test("changing or restarting a stopped service replaces the provider definition instead of accepting its no-op PUT", async () => {
  const f = await fixture();
  const define = f.ctx.sprites!.defineService.bind(f.ctx.sprites);
  let actualCommand = "";
  f.ctx.sprites!.defineService = async (sprite, name, directory, command, port) => {
    // Live Sprites kept the old sh args after a stop followed by PUT, returning
    // this 200 response. Only deleting the definition makes it accept new args.
    if (f.state.services.has(`${sprite}/${name}`)) return JSON.stringify({ name, message: `Service already running with that command, use POST /v1/services/${name}/restart if you want to restart it` });
    actualCommand = command;
    return define(sprite, name, directory, command, port);
  };
  await Promise.all([f.manager.startService("t1"), f.manager.startService("t2")]);
  const peer = f.ctx.db.previews.get("t2")!;
  await f.manager.stopService("t1");
  await f.manager.configure("t1", { directory: "new-app", command: 'exec new-server --port "$PORT"', readinessPath: "/" });
  await f.manager.startService("t1");
  expect(actualCommand).toBe('exec new-server --port "$PORT"');
  expect(f.manager.info("t1").state).toBe("ready");
  expect(f.manager.info("t1").logs).not.toContain("already running");
  expect(f.state.deletes).toHaveLength(1);
  await f.manager.startService("t1", true);
  expect(f.state.deletes).toHaveLength(2);
  expect(f.manager.info("t1").state).toBe("ready");
  expect(f.state.services.get(`${peer.sprite}/${peer.service}`)).toBe("running");
  expect(f.state.stops).not.toContain(`${peer.sprite}/${peer.service}`);
  const row = f.ctx.db.previews.get("t1")!;
  f.ctx.db.previews.save({ ...row, logs: "old startup response" });
  await f.manager.stopService("t1"); await f.manager.startService("t1");
  expect(f.manager.info("t1").logs).not.toContain("old startup response");
  // Recover rows already affected on the live deployment: appliedConfig says
  // the new command was saved, but the provider still holds the old arguments.
  await f.manager.stopService("t1");
  const definition = f.state.definitions.get(`${row.sprite}/${row.service}`)!;
  f.state.definitions.set(`${row.sprite}/${row.service}`, { ...definition, args: ["-lc", "old-server"] });
  await f.manager.startService("t1");
  expect(f.state.definitions.get(`${row.sprite}/${row.service}`)!.args).toEqual(["-lc", 'exec new-server --port "$PORT"']);
  expect(f.state.deletes).toHaveLength(3);
});

test("restart reconciliation recovers saved intent, replaces sandboxes, and retries an interrupted stop", async () => {
  const f = await fixture(); await f.manager.startService("t1");
  const original = f.ctx.db.previews.get("t1")!;
  f.state.services.clear(); f.ctx.db.close(); f.ctx.db = new Db(f.ctx.config.dbPath);
  await f.manager.tick(); expect(f.manager.info("t1").state).toBe("ready"); expect(f.state.creates).toBe(2);
  f.state.sandbox = "s2"; await f.manager.tick(); expect(f.ctx.db.previews.get("t1")!.sprite).toBe("s2");
  expect(f.state.deletes).toContain(`s1/${original.service}`);
  f.state.failStop = true; await expect(f.manager.stopService("t1")).rejects.toThrow("offline");
  expect(f.ctx.db.previews.get("t1")!.stopPending).toBe(true);
  f.state.failStop = false; await f.manager.tick(); expect(f.ctx.db.previews.get("t1")!.stopPending).toBe(false);
});

test("lease expiry does not health-poll an idle machine; idle stop and closed-track cleanup preserve peers", async () => {
  const f = await fixture(); await Promise.all([f.manager.startService("t1"), f.manager.startService("t2")]);
  let row = f.ctx.db.previews.get("t1")!; f.ctx.db.previews.save({ ...row, leaseUntil: Date.now() - 1 });
  const before = f.state.reads;
  // Isolate t1's idle behavior; t2 remains running but its lease expires too.
  const b = f.ctx.db.previews.get("t2")!; f.ctx.db.previews.save({ ...b, leaseUntil: Date.now() - 1 });
  await f.manager.tick(); expect(f.state.reads).toBe(before);
  row = f.ctx.db.previews.get("t1")!; f.ctx.db.previews.save({ ...row, lastActivity: Date.now() - 6 * 60_000 });
  await f.manager.tick(); expect(f.manager.info("t1").state).toBe("stopped"); expect(f.manager.info("t2").state).toBe("ready");
  await f.manager.startService("t1"); expect(f.manager.info("t1").state).toBe("ready");
  f.ctx.db.closeTrack("t1"); await f.manager.tick(); expect(f.ctx.db.previews.get("t1")!.port).toBeNull();
  expect(f.state.services.get(`${b.sprite}/${b.service}`)).toBe("running");
});

test("a sandbox replacement during readiness cannot publish the stale service as Ready", async () => {
  const f = await fixture(); f.manager.ready = async () => { f.state.sandbox = "s2"; return true; };
  await f.manager.startService("t1");
  expect(f.manager.info("t1").state).toBe("failed"); expect(f.manager.info("t1").error).toContain("workspace changed");
  expect([...f.state.services.values()]).toEqual(["stopped"]);
});

test("a running process is not Ready until the HTTP readiness path succeeds", async () => {
  const f = await fixture(); let probes = 0;
  f.manager.ready = async () => { probes++; if (probes === 1) { expect(f.manager.info("t1").state).toBe("starting"); return false; } return true; };
  await f.manager.startService("t1"); expect(probes).toBe(2); expect(f.manager.info("t1").state).toBe("ready");
});

test("unconfigured deployments explicitly report previews unavailable", async () => {
  const f = await fixture(); f.ctx.config.previews = null;
  const r = await f.request("/api/tracks/t1/preview"); const data = (await r.json()).data;
  expect(data.available).toBe(false); expect(data.unavailableReason).toContain("PREVIEW_DOMAIN");
  expect((await f.request("/api/tracks/t1/preview/open", "POST")).status).toBe(501);
});

test("overlapping restart requests discard superseded operations and leave the latest intent running", async () => {
  const f = await fixture(); await f.manager.startService("t1");
  await Promise.all([f.manager.startService("t1", true), f.manager.startService("t1", true), f.manager.startService("t1", true)]);
  expect(f.state.creates).toBe(2); expect(f.manager.info("t1").state).toBe("ready");
  await Promise.all([f.manager.stopService("t1"), f.manager.startService("t1")]);
  expect(f.manager.info("t1").state).toBe("ready");
});

async function agentFixture(guest = false) {
  const f = await fixture();
  if (guest) f.ctx.db.addMember("t1", f.guest.id, f.owner.id);
  const user = guest ? f.guest : f.owner;
  const prompt = f.ctx.db.enqueuePrompt({ id: crypto.randomUUID(), trackId: "t1", userId: user.id, authorLogin: user.login, payload: JSON.stringify({ prompt: "Set up preview", images: [] }) });
  f.ctx.db.claimPrompt(prompt.id);
  const instructions = await prepareAgentPreview(f.ctx, prompt);
  const token = /Authorization: Bearer ([A-Za-z0-9_-]+)/.exec(f.state.execs.at(-1)![2]!)![1]!;
  const router = buildRouter(f.ctx);
  const call = (action: string, config?: unknown, id = "t1", credential = token) => router(new Request(`http://localhost/api/tracks/${id}/preview/agent`, {
    method: "POST", headers: { authorization: `Bearer ${credential}`, "content-type": "application/json" }, body: JSON.stringify({ action, config }),
  }));
  return { ...f, user, prompt, instructions, token, call };
}

test("an installed agent helper configures and starts only its track without granting browser access", async () => {
  const f = await agentFixture(true);
  expect(f.instructions).not.toContain(f.token);
  expect(f.instructions).toContain("/home/sprite/.switchyard/previews/t1.sh");
  expect(f.state.execs[0]![2]).toContain("umask 077");
  expect((await f.call("status", undefined, "t2")).status).toBe(401);
  expect((await f.call("open")).status).toBe(422);
  expect((await f.call("project-defaults")).status).toBe(422);
  const config = { directory: "apps/web", command: 'npm run dev -- --port "$PORT" --strictPort', readinessPath: "/" };
  expect((await f.call("configure", config)).status).toBe(200);
  expect(f.manager.info("t1").config).toEqual(config);
  expect(f.ctx.db.previews.defaults("p")!.directory).toBe("apps/demo");
  const start = await f.call("start"); expect(start.status).toBe(200);
  expect((await start.json()).data.openUrl).toBeUndefined();
  for (let i = 0; i < 100 && f.manager.info("t1").state !== "ready"; i++) await Bun.sleep(5);
  expect(f.manager.info("t1").state).toBe("ready");
  expect((await f.call("logs")).status).toBe(200);
  expect((await f.call("stop")).status).toBe(200);
  expect((await f.call("configure", null)).status).toBe(200);
  expect(f.manager.info("t1").override).toBeNull();
});

test("agent capabilities expire, rotate, and remain revoked after removal and reinvitation", async () => {
  const f = await agentFixture(true);
  const hash = await sha256(f.token), grant = f.ctx.db.previews.agentGrant(hash)!;
  f.ctx.db.previews.grantAgent({ ...grant, expires: Date.now() - 1 });
  expect((await f.call("status")).status).toBe(401);
  f.ctx.db.previews.grantAgent({ ...grant, expires: Date.now() + 60_000 });
  f.ctx.db.removeMember("t1", f.guest.id); f.ctx.db.addMember("t1", f.guest.id, f.owner.id);
  expect((await f.call("configure", null)).status).toBe(401);
  await prepareAgentPreview(f.ctx, f.prompt);
  expect((await f.call("status")).status).toBe(401);
});

test("agent helper rejects cancelled turns, replacement conversations, closed tracks, and changed sandboxes", async () => {
  const cancelled = await agentFixture();
  cancelled.ctx.db.setPromptStatus(cancelled.prompt.id, "cancelled"); expect((await cancelled.call("status")).status).toBe(401);
  const f = await agentFixture();
  f.ctx.db.setPromptStatus(f.prompt.id, "sent");
  f.ctx.db.attachConversation("t1", "replacement"); expect((await f.call("status")).status).toBe(401);
  f.ctx.db.attachConversation("t1", "t1");
  f.state.sandbox = "s2"; expect((await f.call("configure", null)).status).toBe(409);
  f.state.sandbox = "s1"; f.ctx.db.closeTrack("t1"); expect((await f.call("status")).status).toBe(409);
});

test("helper grants survive SQLite reopen but are revoked by project removal and track cleanup", async () => {
  const f = await agentFixture(true);
  f.ctx.db.close(); f.ctx.db = new Db(f.ctx.config.dbPath);
  expect((await f.call("status")).status).toBe(200);
  f.ctx.db.addProjectMember("p", f.guest.id, f.owner.id);
  f.ctx.db.removeProjectMember("p", f.guest.id);
  expect((await f.call("status")).status).toBe(401);
  const g = await agentFixture(); await g.manager.stopService("t1", true);
  expect((await g.call("status")).status).toBe(401);
});
