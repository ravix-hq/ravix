import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildRouter } from "./app";
import { loadConfig } from "./config";
import { buildContext } from "./context";
import { Cipher, sha256 } from "./crypto";
import { Db } from "./db";
import { PromptQueue } from "./prompt-queue";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "switchyard-queue-"));
  const state = {
    status: "running", readFails: false, response: 200, error: "", reads: 0,
    posted: [] as { prompt: string; images?: unknown[] }[],
    onRead: null as (() => Promise<void>) | null,
    onPost: null as (() => void) | null,
  };
  const upstream = Bun.serve({ port: 0, async fetch(req) {
    if (req.method === "GET") {
      state.reads++;
      await state.onRead?.();
      if (state.readFails) return Response.json({ error: "offline" }, { status: 503 });
      return Response.json({ data: { id: "c1", status: state.status } });
    }
    state.posted.push(await req.json());
    state.onPost?.();
    if (state.response !== 200) return Response.json({ error: state.error }, { status: state.response });
    state.status = "running";
    return Response.json({ status: "queued" });
  } });
  const config = loadConfig({ DATA_DIR: dir, SWITCHYARD_SECRET: "queue-test-secret-at-least-16", FOUNTAIN_API_KEY: "test", FOUNTAIN_URL: `http://localhost:${upstream.port}` });
  const db = new Db(config.dbPath);
  const ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
  const owner = db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "test" });
  const guest = db.upsertUser({ githubId: "2", login: "bo", name: "Bo", avatarUrl: null, tokenEnc: "test" });
  const stranger = db.upsertUser({ githubId: "3", login: "cy", name: "Cy", avatarUrl: null, tokenEnc: "test" });
  db.createProject({ id: "p1", userId: owner.id, name: "Demo", repoFullName: null, repoPrivate: 0, defaultBranch: null,
    installationId: null, agentId: "a1", environmentId: "e1", vaultId: null, runtime: "claude", model: "anthropic/test", instructions: "" });
  db.createTrack({ id: "t1", projectId: "p1", conversationId: "c1", slug: "crewe", title: "Crewe", branch: "crewe", workdir: "/work/crewe",
    originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana" });
  for (const user of [owner, guest, stranger]) db.createSession(user.id, await sha256(user.login), config.sessionMaxAgeMs);
  const worker = new PromptQueue(ctx);
  const route = buildRouter(ctx);
  const request = (path: string, method = "GET", body?: unknown, login = "ana") => route(new Request(`http://localhost${path}`, {
    method, headers: { cookie: `switchyard_session=${login}`, "content-type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}),
  }));
  const send = (prompt: string, id = crypto.randomUUID(), login = "ana", images: unknown[] = []) => request("/api/tracks/t1/prompt", "POST", { requestId: id, prompt, images }, login);
  cleanups.push(() => { worker.stop(); ctx.db.close(); upstream.stop(true); rmSync(dir, { recursive: true, force: true }); });
  return { state, ctx, worker, request, send, owner, guest, stranger };
}

test("acknowledged prompts and images survive reopening SQLite and deliver without a browser", async () => {
  const f = await fixture();
  const image = { media_type: "image/png", data: "aGVsbG8=" };
  expect((await f.send("first", crypto.randomUUID(), "ana", [image])).status).toBe(202);
  expect((await f.send("second")).status).toBe(202);
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(0);
  f.ctx.db.close();
  f.ctx.db = new Db(f.ctx.config.dbPath);
  const restarted = new PromptQueue(f.ctx);
  f.ctx.db.recoverPromptQueue();
  f.state.status = "idle";
  await restarted.tick();
  expect(f.state.posted).toEqual([{ prompt: "first", images: [image] }]);
  await restarted.tick();
  expect(f.state.posted).toHaveLength(1);
  f.state.status = "idle";
  await restarted.tick();
  expect(f.state.posted[1]?.prompt).toBe("second");
  expect(f.ctx.db.queuedPrompts()).toHaveLength(0);
});

test("HTTP retries use the same receipt before and after delivery", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("only once", id);
  await f.send("only once", id);
  expect(f.ctx.db.queuedPrompts()).toHaveLength(1);
  f.state.status = "idle";
  await Promise.all([f.worker.tick(), f.worker.tick()]);
  await f.send("only once", id);
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(1);
  expect(f.ctx.db.queuedPrompt(id)?.payload).toBe("");
});

test("cancellation survives restart and does not block the next prompt", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("cancel me", id);
  await f.send("keep me");
  expect((await f.request(`/api/tracks/t1/queue/${id}`, "DELETE")).status).toBe(200);
  f.ctx.db.recoverPromptQueue();
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted.map(p => p.prompt)).toEqual(["keep me"]);
});

test("queue routes respect membership and only sender or owner can cancel", async () => {
  const f = await fixture();
  f.ctx.db.addMember("t1", f.guest.id, f.owner.id);
  const id = crypto.randomUUID();
  await f.send("owner's prompt", id);
  expect((await f.request("/api/tracks/t1/queue", "GET", undefined, "cy")).status).toBe(404);
  expect((await f.send("intruder", crypto.randomUUID(), "cy")).status).toBe(404);
  expect((await f.request(`/api/tracks/t1/queue/${id}`, "DELETE", undefined, "bo")).status).toBe(403);
  const guestView = await (await f.request("/api/tracks/t1/queue", "GET", undefined, "bo")).json();
  expect(guestView.data[0].canCancel).toBe(false);
  const guestId = crypto.randomUUID();
  await f.send("guest's prompt", guestId, "bo");
  expect((await f.request(`/api/tracks/t1/queue/${guestId}`, "DELETE")).status).toBe(200);
});

test("revoked membership and closed tracks cannot dispatch saved work", async () => {
  const f = await fixture();
  f.ctx.db.addMember("t1", f.guest.id, f.owner.id);
  await f.send("guest work", crypto.randomUUID(), "bo");
  f.ctx.db.removeMember("t1", f.guest.id);
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(0);
  await f.send("owner work");
  f.ctx.db.closeTrack("t1");
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(0);
  expect((await f.send("closed track work")).status).toBe(409);
});

test("cancelling during the readiness check prevents the subsequent POST", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("cancel during read", id);
  f.state.status = "idle";
  f.state.onRead = async () => { await f.request(`/api/tracks/t1/queue/${id}`, "DELETE"); };
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(0);
});

test("a failed readiness check retries safely without losing the prompt", async () => {
  const f = await fixture();
  await f.send("after outage");
  f.state.readFails = true;
  await f.worker.tick();
  expect(f.ctx.db.queuedPrompts()[0]?.status).toBe("queued");
  expect(f.state.posted).toHaveLength(0);
  f.state.readFails = false;
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted[0]?.prompt).toBe("after outage");
});

test("capacity races retry, while ambiguous delivery holds later work for review", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("first", id);
  await f.send("second");
  f.state.status = "idle";
  f.state.response = 409;
  f.state.error = "sandbox_at_capacity";
  await f.worker.tick();
  expect(f.ctx.db.queuedPrompt(id)?.status).toBe("queued");
  f.state.response = 502;
  await f.worker.tick();
  expect(f.ctx.db.queuedPrompt(id)?.status).toBe("unconfirmed");
  const count = f.state.posted.length;
  await f.worker.tick();
  expect(f.state.posted).toHaveLength(count);
  f.state.response = 200;
  expect((await f.request(`/api/tracks/t1/queue/${id}/retry`, "POST")).status).toBe(200);
  await f.worker.tick();
  expect(f.state.posted.at(-1)?.prompt).toBe("first");
});

test("a server crash during POST recovers as unconfirmed, never an automatic replay", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("might already have run", id);
  f.ctx.db.claimPrompt(id);
  f.ctx.db.close();
  f.ctx.db = new Db(f.ctx.config.dbPath);
  f.ctx.db.recoverPromptQueue();
  f.state.status = "idle";
  await new PromptQueue(f.ctx).tick();
  expect(f.state.posted).toHaveLength(0);
  expect(f.ctx.db.queuedPrompt(id)?.status).toBe("unconfirmed");
});

test("project members retain authorship and a full queue refuses more work", async () => {
  const f = await fixture();
  f.ctx.db.addProjectMember("p1", f.guest.id, f.owner.id);
  await f.send("project member work", crypto.randomUUID(), "bo");
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted[0]?.prompt).toContain("[from @bo]");
  for (let i = 0; i < 20; i++) expect((await f.send(`queued ${i}`)).status).toBe(202);
  expect((await f.send("over limit")).status).toBe(409);
});

test("the background timer advances waiting work with no subsequent client requests", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("run after I leave", id);
  f.worker.start();
  await Bun.sleep(30);
  expect(f.state.posted).toHaveLength(0);
  f.state.status = "idle";
  const deadline = Date.now() + 3500;
  while (f.ctx.db.queuedPrompt(id)?.status !== "sent" && Date.now() < deadline) await Bun.sleep(20);
  f.worker.stop();
  expect(f.state.posted.map(p => p.prompt)).toEqual(["run after I leave"]);
  expect(f.ctx.db.queuedPrompt(id)?.status).toBe("sent");
});

test("one track needing attention does not block another track", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("blocked", id);
  f.ctx.db.setPromptStatus(id, "unconfirmed", "Check delivery");
  f.ctx.db.createTrack({ ...f.ctx.db.track("t1")!, id: "t2", conversationId: "c2", slug: "selkirk", workdir: "/work/selkirk" });
  await f.request("/api/tracks/t2/prompt", "POST", { requestId: crypto.randomUUID(), prompt: "independent work" });
  f.state.status = "idle";
  await f.worker.tick();
  expect(f.state.posted.map(p => p.prompt)).toEqual(["independent work"]);
});

test("a late delivery failure cannot resurrect a closed track's queue", async () => {
  const f = await fixture();
  const id = crypto.randomUUID();
  await f.send("closing", id);
  f.state.status = "idle";
  f.state.response = 409;
  f.state.error = "sandbox_at_capacity";
  f.state.onPost = () => f.ctx.db.closeTrack("t1");
  await f.worker.tick();
  expect(f.ctx.db.queuedPrompt(id)?.status).toBe("cancelled");
  expect(f.ctx.db.queuedPrompt(id)?.payload).toBe("");
});
