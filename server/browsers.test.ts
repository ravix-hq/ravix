import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Db } from "./db";
import { buildContext } from "./context";
import { loadConfig } from "./config";
import { Cipher, sha256 } from "./crypto";
import { buildRouter } from "./app";
import { browsers } from "./browsers";
import { Sprites, type SpriteService } from "./sprites";
import { prepareAgentBrowser } from "./agent-browser";
import { visibleBrowserPrompt } from "../shared/browser";
import { visiblePreviewPrompt, AGENT_PREVIEW_START, AGENT_PREVIEW_END } from "../shared/previews";

const cleanup: (() => void)[] = [];
afterEach(() => { for (const fn of cleanup.splice(0).reverse()) fn(); });
async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "sy-browser-"));
  const config = loadConfig({ DATA_DIR: dir, SWITCHYARD_SECRET: "browser-test-secret-long-enough", PUBLIC_URL: "http://localhost:5183", FOUNTAIN_API_KEY: "test", SPRITES_TOKEN: "test", SHARED_BROWSER: "1" });
  const db = new Db(config.dbPath), ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
  const owner = db.upsertUser({ githubId: "1", login: "owner", name: null, avatarUrl: null, tokenEnc: "test" });
  const member = db.upsertUser({ githubId: "2", login: "member", name: null, avatarUrl: null, tokenEnc: "test" });
  const other = db.upsertUser({ githubId: "3", login: "other", name: null, avatarUrl: null, tokenEnc: "test" });
  for (const [id, user] of [["p", owner], ["next", owner], ["other", other]] as const) {
    db.createProject({ id, userId: user.id, name: id, repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null, agentId: id, environmentId: id, vaultId: null, runtime: "claude", model: "test", instructions: "" });
    db.browsers.save({ id: `session-${id}`, projectId: id, profile: "shared", sprite: id, sandboxId: id, state: "ready", error: null, tokenEnc: await ctx.cipher.encrypt("worker-private-token") });
  }
  for (const [id, projectId] of [["a", "p"], ["b", "p"], ["c", "next"], ["d", "other"]]) db.createTrack({ id: id!, projectId: projectId!, conversationId: id!, slug: id!, title: id!, branch: id!, workdir: `/work/${id}`, originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login });
  for (const user of [owner, member, other]) db.createSession(user.id, await sha256(user.login), 60000);
  db.addMember("a", member.id, owner.id);
  const manager = browsers(ctx), calls: Record<string, unknown>[] = [];
  const services = new Map<string, SpriteService>(), providerCalls = { uploads: 0, definitions: 0, stops: 0, starts: 0 };
  let onDestination: (() => void) | undefined;
  manager.destination = async projectId => { onDestination?.(); return { sprite: projectId, sandboxId: projectId }; };
  manager.transport = async (_row, command) => {
    calls.push(command);
    if (command.action === "checkpoint") return { version: 1, engine: "chromium", storage: { cookies: [{ value: "machine-account-secret" }], origins: [] }, tabs: [] } as any;
    return { tabs: [], controller: null, revision: "r", sequence: calls.length };
  };
  class Provider extends Sprites {
    async activity() {}
    async service(sprite: string) { return services.get(sprite) ?? null; }
    async defineService(sprite: string, name: string, dir: string, command: string, port: number) {
      providerCalls.definitions++; services.set(sprite, { name, dir, cmd: "sh", args: ["-lc", command], env: { PORT: String(port) }, state: { status: "running" } }); return "";
    }
    async serviceAction(sprite: string, _name: string, action: "start" | "stop" | "delete") {
      if (action === "delete") services.delete(sprite);
      else { if (action === "stop") providerCalls.stops++; else providerCalls.starts++;
        const service = services.get(sprite); if (service) service.state = { status: action === "start" ? "running" : "stopped" }; }
      return "";
    }
    async exec() { providerCalls.uploads++; return { stdout: "", stderr: "", code: 0 }; }
  }
  ctx.sprites = new Provider({ token: "", baseUrl: "" });
  const router = buildRouter(ctx), clientId = crypto.randomUUID();
  const request = (track: string, action?: string, body: Record<string, unknown> = {}, login = "owner", origin = config.publicUrl) => router(new Request(`http://localhost/api/tracks/${track}/browser${action ? `/${action}` : ""}`, {
    method: action ? "POST" : "GET", headers: { cookie: `switchyard_session=${login}`, origin, "content-type": "application/json" }, ...(action ? { body: JSON.stringify({ clientId, ...body }) } : {}),
  }));
  cleanup.push(() => { ctx.db.close(); rmSync(dir, { recursive: true, force: true }); });
  return { ctx, manager, request, calls, owner, member, other, clientId, providerCalls, setOnDestination: (fn: () => void) => { onDestination = fn; } };
}

test("all tracks and participants attach to one shared profile; credentials stay server-side", async () => {
  const f = await fixture();
  const a = await (await f.request("a", undefined, {}, "member")).json(), b = await (await f.request("b")).json();
  expect(a.data.session.id).toBe(b.data.session.id);
  expect(a.data.session.profile).toBe("shared");
  expect(JSON.stringify(a)).not.toContain("token");
  expect((await f.request("b", undefined, {}, "member")).status).toBe(404);
  await f.request("a", "command", { action: "acquire", actor: { id: "spoof", kind: "agent" } }, "member");
  expect(f.calls[0]?.actor).toEqual({ id: `human:${f.member.id}:${f.clientId}`, label: "@member", kind: "human" });
});

test("concurrent opens install one private service; stop and reopen reuse the same profile", async () => {
  const f = await fixture();
  const results = await Promise.all([f.request("a", "start"), f.request("b", "start"), f.request("a", "start", {}, "member")]);
  expect(results.map(result => result.status)).toEqual([200, 200, 200]);
  expect(f.providerCalls.definitions).toBe(1);
  const uploads = f.providerCalls.uploads;
  expect(uploads).toBeGreaterThan(3);
  expect((await f.request("a", "stop", {}, "member")).status).toBe(403);
  expect((await f.request("a", "stop")).status).toBe(200);
  expect(f.ctx.db.browsers.get("p")?.state).toBe("stopped");
  expect((await f.request("b", "start")).status).toBe(200);
  expect(f.ctx.db.browsers.get("p")?.id).toBe("session-p");
  expect(f.providerCalls.uploads).toBe(uploads);
  expect(f.providerCalls.starts).toBe(1);
});

test("origin, membership, closed-track and command checks precede browser access", async () => {
  const f = await fixture();
  expect((await f.request("a", "command", { action: "status" }, "owner", "https://evil.test")).status).toBe(403);
  expect((await f.request("a", "command", { action: "evaluate", expression: "bad" })).status).toBe(422);
  expect((await f.request("a", "command", { action: "status" }, "other")).status).toBe(404);
  f.ctx.db.closeTrack("a");
  expect((await f.request("a", "command", { action: "status" })).status).toBe(409);
  expect(f.calls).toHaveLength(0);
});

test("membership removed during a machine lookup cannot send input", async () => {
  const f = await fixture();
  f.setOnDestination(() => f.ctx.db.removeMember("a", f.member.id));
  expect((await f.request("a", "command", { action: "click", tabId: "tab", x: 0, y: 0 }, "member")).status).toBe(404);
  expect(f.calls).toHaveLength(0);
});

test("signing out during a machine lookup prevents a late browser command", async () => {
  const f = await fixture(), hash = await sha256("owner");
  f.setOnDestination(() => f.ctx.db.endSession(hash));
  expect((await f.request("a", "command", { action: "acquire" })).status).toBe(401);
  expect(f.calls).toHaveLength(0);
});

test("checkpoints are encrypted, survive SQLite reopen, and restore across projects of the same owner", async () => {
  const f = await fixture();
  const response = await f.request("a", "checkpoint", { label: "Signed in" }, "member");
  expect(response.status).toBe(200);
  const cp = (await response.json()).data;
  const saved = f.ctx.db.browsers.checkpoint(cp.id)!;
  expect(saved.payloadEnc).not.toContain("machine-account-secret");
  expect(JSON.stringify(cp)).not.toContain("storage");
  f.ctx.db.close(); f.ctx.db = new Db(f.ctx.config.dbPath);
  expect((await f.request("c", "restore", { checkpointId: cp.id })).status).toBe(200);
  expect(JSON.stringify(f.calls.at(-1)?.checkpoint)).toContain("machine-account-secret");
  expect((await f.request("a", "restore", { checkpointId: cp.id }, "member")).status).toBe(403);
  expect((await f.request("d", "restore", { checkpointId: cp.id }, "other")).status).toBe(404);
  expect((await f.request("c", "delete-checkpoint", { checkpointId: cp.id })).status).toBe(404);
  expect((await f.request("a", "delete-checkpoint", { checkpointId: cp.id })).status).toBe(200);
  expect(f.ctx.db.browsers.checkpoint(cp.id)).toBeNull();
});

test("machine replacement fences old browser input, and closing a track preserves the profile", async () => {
  const f = await fixture();
  const row = f.ctx.db.browsers.get("p")!;
  f.ctx.db.browsers.save({ ...row, sandboxId: "previous" });
  expect((await f.request("a", "command", { action: "status" })).status).toBe(409);
  expect(f.calls).toHaveLength(0);
  f.ctx.db.closeTrack("a");
  expect(f.ctx.db.browsers.get("p")?.id).toBe(row.id);
});

test("browser helper instructions remain hidden alongside preview instructions", async () => {
  const f = await fixture();
  const instructions = await prepareAgentBrowser(f.ctx, { sequence: 1, id: "prompt", trackId: "a", userId: f.owner.id, authorLogin: "owner", createdAt: "now", status: "sending", error: null });
  expect(instructions).toContain("one shared Switchyard browser profile");
  expect(instructions).not.toContain("Bearer");
  const prompt = `${AGENT_PREVIEW_START}\npreview instructions\n${AGENT_PREVIEW_END}\n\n${instructions}\n\nHello`;
  expect(visibleBrowserPrompt(visiblePreviewPrompt(prompt))).toBe("Hello");
  expect(visibleBrowserPrompt("Hello")).toBe("Hello");
});

test("removed and reinvited members cannot reuse an old browser helper", async () => {
  const f = await fixture();
  const hash = await sha256("test-grant");
  f.ctx.db.browsers.grant({ hash, trackId: "a", userId: f.member.id, promptId: "p", conversationId: "a", sandboxId: "p", sprite: "p", expires: Date.now() + 60000 });
  f.ctx.db.removeMember("a", f.member.id); f.ctx.db.addMember("a", f.member.id, f.owner.id);
  expect(f.ctx.db.browsers.agent(hash)).toBeNull();
});

test("agent grants bind input to the delivered prompt and machine and cannot invoke restore", async () => {
  const f = await fixture(), token = "browser-agent-test-token-long-enough";
  const hash = await sha256(token);
  f.ctx.db.enqueuePrompt({ id: "prompt", trackId: "a", userId: f.member.id, authorLogin: "member", payload: JSON.stringify({ prompt: "Browse" }) });
  f.ctx.db.setPromptStatus("prompt", "sending");
  const grant = { hash, trackId: "a", userId: f.member.id, promptId: "prompt", conversationId: "a", sandboxId: "p", sprite: "p", expires: Date.now() + 60000 };
  f.ctx.db.browsers.grant(grant);
  const router = buildRouter(f.ctx);
  const request = (action: string) => router(new Request("http://localhost/api/tracks/a/browser/agent", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ action }) }));
  expect((await request("acquire")).status).toBe(200);
  expect(f.calls[0]?.actor).toEqual({ id: "agent:prompt", label: "Agent · a", kind: "agent" });
  expect((await request("restore")).status).toBe(422);
  f.ctx.db.browsers.grant({ ...grant, sandboxId: "replaced" });
  expect((await request("status")).status).toBe(409);
  f.ctx.db.browsers.grant(grant);
  f.ctx.db.setPromptStatus("prompt", "cancelled");
  expect((await request("status")).status).toBe(401);
});
