import { afterEach, expect, test } from "bun:test";
import { PassThrough } from "node:stream";
import type { AppContext } from "./context";
import { sha256 } from "./crypto";
import { Db } from "./db";
import { publish } from "./hub";
import { NativeForwardAccess, type NativeForwardState } from "./native-forward-access";

const cleanup: (() => void)[] = [];
afterEach(() => { for (const close of cleanup.splice(0).reverse()) close(); });

async function fixture() {
  const db = new Db(":memory:");
  const owner = db.upsertUser({ githubId: "1", login: "owner", name: null, avatarUrl: null, tokenEnc: "unused" });
  const member = db.upsertUser({ githubId: "2", login: "member", name: null, avatarUrl: null, tokenEnc: "unused" });
  const sessionHash = await sha256("browser-session");
  db.createSession(member.id, sessionHash, 60_000);
  db.createProject({ id: "project", userId: owner.id, name: "Hello", repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null, agentId: "agent", environmentId: "env", vaultId: null, runtime: "codex", model: "test", instructions: "" });
  for (const id of ["track", "other-track"]) {
    db.createTrack({ id, projectId: "project", conversationId: id, slug: id, title: id, branch: id, workdir: `/work/${id}`, originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login });
    db.addMember(id, member.id, owner.id);
  }
  const state: NativeForwardState = {
    sessionId: "native-session", trackId: "track", projectId: "project", projectRevision: 1,
    runnerId: "runner", runnerOwnerId: owner.id, runnerEpoch: 1, generation: 1,
    enabledProjects: ["project"], leaseUntil: Date.now() + 60_000, active: true,
    services: { metro: { sprite: "sprite", port: 31000, service: "managed-metro" }, backend: { sprite: "sprite", port: 31001, service: "managed-backend" } },
  };
  const states = new Map([[state.sessionId, state]]);
  const calls: { sprite: string; port: number; service: string }[] = [];
  const streams: PassThrough[] = [];
  let barrier: Promise<void> | null = null;
  const access = new NativeForwardAccess({ db } as AppContext, id => states.get(id) ?? null, async destination => {
    calls.push(destination);
    const stream = new PassThrough(); streams.push(stream);
    await barrier;
    return stream;
  });
  cleanup.push(() => { access.stop(); for (const stream of streams) stream.destroy(); db.close(); });
  const principal = { userId: member.id, sessionHash, runnerId: "runner", runnerEpoch: 1 };
  const grant = () => access.issue(state.sessionId, principal);
  return { db, owner, member, sessionHash, principal, state, states, access, calls, streams, grant, block: (wait: Promise<void>) => { barrier = wait; } };
}

function request(token: string, name = "metro", session = "native-session") {
  return new Request(`https://switchyard.test/api/native/sessions/${session}/forward/${name}`, { headers: { authorization: `Bearer ${token}` } });
}

test("named forwards use server destinations and cannot cross sessions or accept browser authentication", async () => {
  const f = await fixture(); const grant = await f.grant();
  expect(grant.paths.metro).toBe("/api/native/sessions/native-session/forward/metro");
  expect(grant.expiresAt).toBeLessThanOrEqual(f.state.leaseUntil);
  const metro = await f.access.authorize(request(grant.token));
  const backend = await f.access.authorize(request(grant.token, "backend"));
  await metro!.connect(); await backend!.connect();
  expect(f.calls).toEqual([f.state.services.metro!, f.state.services.backend!]);
  for (const req of [
    request(grant.token, "arbitrary"), request(grant.token, "metro", "other-session"), request("a".repeat(43)),
    new Request(request(grant.token).url, { headers: { cookie: "switchyard_session=browser-session" } }),
    new Request(request(grant.token), { headers: { authorization: `Bearer ${grant.token}`, origin: "https://switchyard.test" } }),
    new Request(`${request(grant.token).url}?port=22`, { headers: request(grant.token).headers }),
  ]) expect(await f.access.authorize(req)).toBeNull();
  expect(f.calls).toHaveLength(2);
});

test("grants require track membership and the authenticated runner's current connection", async () => {
  const f = await fixture();
  for (const principal of [
    { ...f.principal, sessionHash: "wrong" }, { ...f.principal, userId: f.owner.id },
    { ...f.principal, runnerId: "another-runner" }, { ...f.principal, runnerEpoch: 2 },
  ]) await expect(f.access.issue(f.state.sessionId, principal)).rejects.toThrow();
  f.db.removeMember("track", f.member.id);
  await expect(f.grant()).rejects.toThrow();
  f.db.addProjectMember("project", f.member.id, f.owner.id);
  expect((await f.grant()).token.length).toBeGreaterThanOrEqual(32);
});

const changes: [string, (f: Awaited<ReturnType<typeof fixture>>) => void][] = [
  ["sign-out", f => f.db.endSession(f.sessionHash)],
  ["membership removal", f => f.db.removeMember("track", f.member.id)],
  ["track closure", f => f.db.closeTrack("track")],
  ["project archive", f => f.db.archiveProject("project")],
  ["project revision change", f => f.db.bumpRev("project")],
  ["runner reassignment", f => { f.state.runnerId = "other"; }],
  ["connection replacement", f => { f.state.runnerEpoch++; }],
  ["session generation change", f => { f.state.generation++; }],
  ["runner project revocation", f => { f.state.enabledProjects = []; }],
  ["runner ownership change", f => { f.state.runnerOwnerId = f.member.id; }],
  ["service replacement", f => { f.state.services.metro!.port++; }],
  ["workspace replacement", f => { f.state.services.metro!.sprite = "new-sprite"; }],
  ["assignment stop", f => { f.state.active = false; }],
  ["lease expiry", f => { f.state.leaseUntil = Date.now() - 1; }],
];
for (const [name, change] of changes) test(`${name} revokes an existing native channel and refuses its token`, async () => {
  const f = await fixture(); const grant = await f.grant();
  const channel = (await f.access.authorize(request(grant.token)))!;
  expect(channel.signal.aborted).toBe(false);
  change(f);
  expect(await f.access.authorize(request(grant.token))).toBeNull();
  expect(channel.signal.aborted).toBe(true);
  await expect(channel.connect()).rejects.toThrow();
  expect(f.calls).toHaveLength(0);
});

test("membership events abort established channels immediately and preserve another track", async () => {
  const f = await fixture();
  f.states.set("peer", { ...f.state, sessionId: "peer", trackId: "other-track" });
  const grant = await f.grant(); const peer = await f.access.issue("peer", f.principal);
  const channel = (await f.access.authorize(request(grant.token)))!;
  const peerChannel = (await f.access.authorize(request(peer.token, "metro", "peer")))!;
  f.db.removeMember("track", f.member.id);
  publish("project", { event: "people", data: { trackId: "track" } });
  expect(channel.signal.aborted).toBe(true);
  expect(peerChannel.signal.aborted).toBe(false);
  f.access.revokeSession("native-session");
  expect(await f.access.authorize(request(peer.token, "metro", "peer"))).not.toBeNull();
});

test("revocation during destination connection destroys the late stream", async () => {
  const f = await fixture(); const grant = await f.grant();
  const channel = (await f.access.authorize(request(grant.token)))!;
  let release!: () => void;
  f.block(new Promise(resolve => { release = resolve; }));
  const connecting = channel.connect();
  f.state.generation++; release();
  await expect(connecting).rejects.toThrow();
  expect(f.streams[0]!.destroyed).toBe(true);
  expect(channel.signal.aborted).toBe(true);
});

test("lease expiry closes an idle channel without another request", async () => {
  const f = await fixture(); f.state.leaseUntil = Date.now() + 50;
  const grant = await f.grant(); const channel = (await f.access.authorize(request(grant.token)))!;
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Lease timer did not revoke the channel")), 1_000);
    channel.signal.addEventListener("abort", () => { clearTimeout(timeout); resolve(); }, { once: true });
  });
  expect(await f.access.authorize(request(grant.token))).toBeNull();
});

test("sign-out polling also closes an idle channel without hub events", async () => {
  const f = await fixture(); const grant = await f.grant();
  const channel = (await f.access.authorize(request(grant.token)))!;
  f.db.endSession(f.sessionHash);
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Sign-out did not revoke the channel")), 2_000);
    channel.signal.addEventListener("abort", () => { clearTimeout(timeout); resolve(); }, { once: true });
  });
  expect(channel.signal.aborted).toBe(true);
});

test("concurrent issuance is bounded and stopping invalidates every grant", async () => {
  const f = await fixture();
  const results = await Promise.allSettled(Array.from({ length: 70 }, () => f.grant()));
  expect(results.filter(r => r.status === "fulfilled")).toHaveLength(64);
  const successful = results.find(r => r.status === "fulfilled")!;
  if (successful.status !== "fulfilled") throw new Error("No grant issued");
  const channel = (await f.access.authorize(request(successful.value.token)))!;
  f.access.stop();
  expect(channel.signal.aborted).toBe(true);
  expect(await f.access.authorize(request(successful.value.token))).toBeNull();
  await expect(f.grant()).rejects.toThrow();
});
