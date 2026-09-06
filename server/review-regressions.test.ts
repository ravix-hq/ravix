import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { buildRouter } from "./app";
import type { AppContext } from "./context";
import { Cipher, sha256 } from "./crypto";
import { Db } from "./db";
import { resetHub } from "./hub";
import { prepareMachine } from "./projects";
import { GitHubError } from "./github";

const databases: Db[] = [];
afterEach(() => {
  resetHub();
  for (const db of databases.splice(0)) db.close();
});

async function fixture() {
  const db = new Db(":memory:");
  databases.push(db);
  const cipher = await Cipher.from("switchyard regression tests only");
  const owner = db.upsertUser({ githubId: "1", login: "owner", name: "Owner", avatarUrl: null, tokenEnc: await cipher.encrypt("owner-token") });
  const guest = db.upsertUser({ githubId: "2", login: "guest", name: "Guest", avatarUrl: null, tokenEnc: await cipher.encrypt("guest-token") });
  for (const [user, token] of [[owner, "owner"], [guest, "guest"]] as const) db.createSession(user.id, await sha256(token), 60_000);
  const project = db.createProject({
    id: "p", userId: owner.id, name: "Project", repoFullName: null, repoPrivate: 0,
    defaultBranch: null, installationId: null, agentId: "a", environmentId: "e", vaultId: "v",
    runtime: "claude", model: "anthropic/claude-opus-5", instructions: "",
  });
  for (const id of ["t", "other"]) db.createTrack({
    id, projectId: project.id, conversationId: `c-${id}`, slug: id, title: id, branch: id,
    workdir: `/work/${id}`, originKind: "blank", originBase: null, originNumber: null,
    originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login,
  });
  const github = {
    repositories: mock(async () => [{ fullName: "owner/repo", name: "repo", defaultBranch: "main", private: true }]),
    mintCloneToken: mock(async () => "installation-token"),
    installationsFor: mock(async () => []),
    authorizeUrl: (_callback: string, state: string) => `https://github.test/login?state=${state}`,
    installUrl: (state?: string) => `https://github.test/install?state=${state ?? ""}`,
    exchangeCode: mock(async () => "oauth-token"),
    viewer: mock(async () => ({ id: 3, login: "new-user", name: null, avatar_url: "" })),
  };
  const fountain = {
    createEnvironment: mock(async () => ({ id: "new-env" })),
    createVault: mock(async () => ({ id: "new-vault" })),
    updateAgent: mock(async (..._args: unknown[]) => ({})),
    createAgent: mock(async (_input: Record<string, unknown>) => ({ id: "new-agent" })),
    putSecret: mock(async (..._args: unknown[]) => {}),
    catalog: mock(async () => ({ runtimes: ["codex"], models: { codex: ["openai/test-model"] } })),
    listConversations: mock(async () => []),
    deleteAgent: mock(async () => {}),
    deleteVault: mock(async () => {}),
    deleteEnvironment: mock(async () => {}),
    getEnvironment: mock(async () => ({})),
    secretKeys: mock(async () => []),
  };
  const ctx = { db, cipher, github, fountain, sprites: null, config: { publicUrl: "https://switchyard.test", sessionMaxAgeMs: 60_000 } } as unknown as AppContext;
  return { db, ctx, owner, guest, project, github, fountain, route: buildRouter(ctx) };
}

function request(path: string, user?: string, method = "GET", body?: unknown, cookie?: string) {
  return new Request(`https://switchyard.test${path}`, {
    method, headers: { cookie: [user ? `switchyard_session=${user}` : "", cookie ?? ""].filter(Boolean).join("; ") },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}
const cookieOf = (response: Response) => response.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
const stateOf = (url: string) => new URL(url).searchParams.get("state")!;

test("expired user credentials offer reauthentication without misdiagnosing permission failures", async () => {
  const { route, github } = await fixture();
  github.installationsFor.mockRejectedValueOnce(new GitHubError(401, "Bad credentials"));
  const expired = await route(request("/api/github/repos", "owner"));
  expect(expired.status).toBe(401);
  expect((await expired.json()).error).toBe("reauthenticate");
  github.installationsFor.mockRejectedValueOnce(new GitHubError(403, "Forbidden"));
  const denied = await route(request("/api/github/repos", "owner"));
  expect(denied.status).toBe(502);
  expect((await denied.json()).error).toBe("github_rejected");
});

test("signing out revokes the server session and clears the cookie", async () => {
  const { route, db } = await fixture();
  const response = await route(request("/api/auth/signout", "owner", "POST"));
  expect(response.status).toBe(200);
  expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
  expect(db.sessionUser(await sha256("owner"))).toBeNull();
  expect((await route(request("/api/projects", "owner"))).status).toBe(401);
  expect(db.sessionUser(await sha256("guest"))).not.toBeNull();
});

async function signin(route: ReturnType<typeof buildRouter>) {
  const response = await route(request("/api/session"));
  return { response, cookie: cookieOf(response), state: stateOf((await response.json()).data.signInUrl) };
}

test("blank projects reject installation credentials before creating upstream records", async () => {
  const { route, fountain, github } = await fixture();
  const response = await route(request("/api/projects", "guest", "POST", { name: "Blank", installationId: 99999 }));
  expect(response.status).toBe(422);
  expect(fountain.createEnvironment).not.toHaveBeenCalled();
  expect(github.mintCloneToken).not.toHaveBeenCalled();
  const blank = await route(request("/api/projects", "guest", "POST", { name: "Blank" }));
  expect(blank.status).toBe(201);
  expect(github.mintCloneToken).not.toHaveBeenCalled();
});

test("repository access is checked before minting the installation token", async () => {
  const { route, github, fountain } = await fixture();
  expect((await route(request("/api/projects", "owner", "POST", { repo: "stranger/private", installationId: 99 }))).status).toBe(404);
  expect(github.mintCloneToken).not.toHaveBeenCalled();
  expect(fountain.createEnvironment).not.toHaveBeenCalled();
  expect((await route(request("/api/projects", "owner", "POST", { repo: "owner/repo", installationId: 1 }))).status).toBe(201);
  expect(github.repositories).toHaveBeenLastCalledWith("owner-token", 1);
  expect(github.mintCloneToken).toHaveBeenCalledWith(1);
  expect(fountain.putSecret).toHaveBeenCalledWith("vaults", "new-vault", "GITHUB_TOKEN", "installation-token");
});

test("legacy blank projects do not refresh an unverified installation", async () => {
  const { ctx, project, github } = await fixture();
  await prepareMachine(ctx, { ...project, installationId: 99 }, ctx.fountain!);
  expect(github.mintCloneToken).not.toHaveBeenCalled();
});

test("catalog fallback survives project responses, settings and rebuild", async () => {
  const { route, db, fountain } = await fixture();
  const response = await route(request("/api/projects", "owner", "POST", { name: "Blank" }));
  const project = (await response.json()).data;
  for (const result of [project, db.project(project.id), fountain.createAgent.mock.calls[0]![0]]) {
    expect(result).toMatchObject({ runtime: "codex", model: "openai/test-model" });
  }
  const settings = await route(request(`/api/projects/${project.id}/settings`, "owner"));
  expect((await settings.json()).data.model).toBe("openai/test-model");
  expect((await route(request(`/api/projects/${project.id}/rebuild`, "owner", "POST"))).status).toBe(200);
  expect(fountain.createAgent.mock.calls[1]![0]).toMatchObject({ runtime: "codex", model: "openai/test-model" });
});

test("callback requires its own browser secret and rejects replay", async () => {
  const { route, github } = await fixture();
  const attempt = await signin(route);
  const other = await signin(route);
  const path = `/api/auth/callback?state=${attempt.state}&code=code`;
  for (const cookie of [undefined, other.cookie, attempt.cookie.replace(/=.+$/, "=wrong")]) {
    const response = await route(request(path, "owner", "GET", undefined, cookie));
    expect(response.headers.get("location")).toBe("/?error=stale_signin");
    expect(response.headers.getSetCookie().some((c) => c.startsWith("switchyard_session="))).toBe(false);
  }
  expect(github.exchangeCode).not.toHaveBeenCalled();
  const success = await route(request(path, undefined, "GET", undefined, attempt.cookie));
  expect(success.headers.get("location")).toBe("/");
  expect(success.headers.getSetCookie().some((c) => c.startsWith("switchyard_session="))).toBe(true);
  expect(success.headers.getSetCookie().some((c) => c.includes("Max-Age=0"))).toBe(true);
  expect((await route(request(path, undefined, "GET", undefined, attempt.cookie))).headers.get("location")).toBe("/?error=stale_signin");
  expect(github.exchangeCode).toHaveBeenCalledTimes(1);
});

test("independent tabs can finish sign-in in either order", async () => {
  const { route, github } = await fixture();
  const first = await signin(route);
  const second = await signin(route);
  const cookies = `${first.cookie}; ${second.cookie}`;
  for (const attempt of [second, first]) {
    expect((await route(request(`/api/auth/callback?state=${attempt.state}&code=code`, undefined, "GET", undefined, cookies))).headers.get("location")).toBe("/");
  }
  expect(github.exchangeCode).toHaveBeenCalledTimes(2);
  expect(first.response.headers.get("set-cookie")).toContain("HttpOnly; SameSite=Lax; Max-Age=900; Secure");
  expect(first.response.headers.get("cache-control")).toBe("no-store");
});

test("expired and pre-upgrade unbound states cannot exchange a code", async () => {
  const { route, db, github } = await fixture();
  const attempt = await signin(route);
  const now = Date.now();
  const clock = spyOn(Date, "now").mockReturnValue(now + 16 * 60_000);
  try {
    expect((await route(request(`/api/auth/callback?state=${attempt.state}&code=code`, undefined, "GET", undefined, attempt.cookie))).headers.get("location")).toBe("/?error=stale_signin");
  } finally { clock.mockRestore(); }
  db.putState(attempt.state, "signin", null);
  expect((await route(request(`/api/auth/callback?state=${attempt.state}&code=code`, undefined, "GET", undefined, attempt.cookie))).headers.get("location")).toBe("/?error=stale_signin");
  expect(github.exchangeCode).not.toHaveBeenCalled();
});

test("installation and both invite flows bind their callbacks to the browser", async () => {
  const { route, db, owner } = await fixture();
  db.putLink("t", await sha256("track-link"), owner.id, 60_000);
  db.putProjectLink("p", await sha256("project-link"), owner.id, 60_000);
  for (const [path, user, landing] of [
    ["/api/auth/install", "owner", "/"],
    ["/j/track-link", undefined, "/p/p/t/t"],
    ["/j/project-link", undefined, "/p/p"],
  ] as const) {
    const response = await route(request(path, user));
    const state = stateOf(response.headers.get("location")!);
    const callback = `/api/auth/callback?state=${state}&code=code`;
    expect((await route(request(callback))).headers.get("location")).toBe("/?error=stale_signin");
    expect((await route(request(callback, undefined, "GET", undefined, cookieOf(response)))).headers.get("location")).toBe(landing);
  }
});

test("track and project people responses contain only public profile fields", async () => {
  const { route, db, guest, owner } = await fixture();
  db.addProjectMember("p", guest.id, owner.id);
  for (const path of ["/api/tracks/t/people", "/api/projects/p/people"]) {
    const response = await route(request(path, "guest"));
    expect(response.status).toBe(200);
    const people = (await response.json()).data;
    expect(people).toHaveLength(2);
    for (const person of people) {
      expect(Object.keys(person).sort()).toEqual(person.via ? ["avatarUrl", "login", "name", "via"] : ["avatarUrl", "login", "name"]);
    }
  }
});

function upstream() {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const cancel = mock(() => {});
  const response = new Response(new ReadableStream<Uint8Array>({ start(c) { controller = c; }, cancel }));
  return { response, cancel, send: (text: string) => controller.enqueue(new TextEncoder().encode(text)), close: () => controller.close() };
}

for (const scope of ["track", "project"] as const) test(`${scope} removal cancels existing transcripts while leaving the owner's stream open`, async () => {
  const { ctx, route, db, owner, guest } = await fixture();
  if (scope === "track") db.addMember("t", guest.id, owner.id);
  else db.addProjectMember("p", guest.id, owner.id);
  const guestUpstream = upstream();
  const ownerUpstream = upstream();
  const signals: AbortSignal[] = [];
  ctx.fountain!.stream = mock(async (_id: string, signal?: AbortSignal) => {
    signals.push(signal!);
    return signals.length === 1 ? guestUpstream.response : ownerUpstream.response;
  });
  const guestResponse = await route(request("/api/tracks/t/stream", "guest"));
  const ownerResponse = await route(request("/api/tracks/t/stream", "owner"));
  const guestReader = guestResponse.body!.getReader();
  const ownerReader = ownerResponse.body!.getReader();
  guestUpstream.send("before removal");
  expect(new TextDecoder().decode((await guestReader.read()).value)).toBe("before removal");
  const ended = guestReader.read().then(() => "unexpected output", () => "revoked");
  const endpoint = scope === "track" ? "/api/tracks/t/people/guest" : "/api/projects/p/people/guest";
  expect((await route(request(endpoint, "owner", "DELETE"))).status).toBe(200);
  expect(await ended).toBe("revoked");
  expect(signals[0]!.aborted).toBe(true);
  expect(signals[1]!.aborted).toBe(false);
  ownerUpstream.send("after removal");
  expect(new TextDecoder().decode((await ownerReader.read()).value)).toBe("after removal");
  expect(guestUpstream.cancel).toHaveBeenCalledTimes(1);
  expect((await route(request("/api/tracks/t/stream", "guest"))).status).toBe(404);
  await ownerReader.cancel();
});

test("removal while upstream headers are pending aborts the request", async () => {
  const { ctx, route, db, owner, guest } = await fixture();
  db.addMember("t", guest.id, owner.id);
  const started = Promise.withResolvers<void>();
  ctx.fountain!.stream = mock((_id: string, signal?: AbortSignal) => new Promise<Response>((_resolve, reject) => {
    signal!.addEventListener("abort", () => reject(signal!.reason), { once: true });
    started.resolve();
  }));
  const pending = route(request("/api/tracks/t/stream", "guest"));
  await started.promise;
  await route(request("/api/tracks/t/people/guest", "owner", "DELETE"));
  expect((await pending).ok).toBe(false);
});

test("project channel closes when the last membership is removed", async () => {
  const { route, db, owner, guest } = await fixture();
  db.addMember("t", guest.id, owner.id);
  db.addMember("other", guest.id, owner.id);
  const response = await route(request("/api/projects/p/stream", "guest"));
  const reader = response.body!.getReader();
  await reader.read();
  await route(request("/api/tracks/t/people/guest", "owner", "DELETE"));
  expect((await reader.read()).done).toBe(false);
  const ended = reader.read().then(() => "unexpected output", () => "revoked");
  await route(request("/api/tracks/other/people/guest", "owner", "DELETE"));
  expect(await ended).toBe("revoked");
});

test("EOF and browser cancellation release upstream streams", async () => {
  const { ctx, route } = await fixture();
  for (const action of ["eof", "cancel"] as const) {
    const source = upstream();
    ctx.fountain!.stream = mock(async () => source.response);
    const response = await route(request("/api/tracks/t/stream", "owner"));
    const reader = response.body!.getReader();
    if (action === "eof") {
      source.close();
      expect((await reader.read()).done).toBe(true);
    } else {
      await reader.cancel();
      expect(source.cancel).toHaveBeenCalledTimes(1);
    }
  }
});

test("client disconnect cancels an idle upstream response", async () => {
  const { ctx, route } = await fixture();
  const source = upstream();
  let signal!: AbortSignal;
  ctx.fountain!.stream = mock(async (_id: string, upstreamSignal?: AbortSignal) => {
    signal = upstreamSignal!;
    return source.response;
  });
  const client = new AbortController();
  const response = await route(new Request(request("/api/tracks/t/stream", "owner"), { signal: client.signal }));
  const ended = response.body!.getReader().read();
  client.abort();
  // A client that already disconnected gets EOF; authorization revocations
  // still error the stream and discard queued output (covered below).
  expect(await ended).toEqual({ done: true, value: undefined });
  expect(signal.aborted).toBe(true);
  expect(source.cancel).toHaveBeenCalledTimes(1);
});

test("revocation discards queued output before an idle client reads it", async () => {
  const { ctx, route, db, owner, guest } = await fixture();
  db.addMember("t", guest.id, owner.id);
  const source = upstream();
  ctx.fountain!.stream = mock(async () => source.response);
  const response = await route(request("/api/tracks/t/stream", "guest"));
  source.send("queued output");
  await route(request("/api/tracks/t/people/guest", "owner", "DELETE"));
  expect(await response.body!.getReader().read().catch(() => "revoked")).toBe("revoked");
});

test("archiving a project ends its open transcript and project channel", async () => {
  const { ctx, route } = await fixture();
  const source = upstream();
  ctx.fountain!.stream = mock(async () => source.response);
  const transcript = await route(request("/api/tracks/t/stream", "owner"));
  const project = await route(request("/api/projects/p/stream", "owner"));
  const transcriptReader = transcript.body!.getReader();
  const projectReader = project.body!.getReader();
  await projectReader.read();
  const transcriptEnd = transcriptReader.read().catch(() => "revoked");
  const projectEnd = projectReader.read().catch(() => "revoked");
  expect((await route(request("/api/projects/p", "owner", "DELETE"))).status).toBe(200);
  expect(await transcriptEnd).toBe("revoked");
  expect(await projectEnd).toBe("revoked");
});


test("settings expose the catalog and switch harness in place for future tracks", async () => {
  const { route, db, fountain } = await fixture();
  const settings = await route(request("/api/projects/p/settings", "owner"));
  expect((await settings.json()).data).toMatchObject({ runtime: "claude", catalog: { runtimes: ["codex"] } });
  const response = await route(request("/api/projects/p/settings", "owner", "PUT", { runtime: "codex", model: "openai/test-model" }));
  expect(response.status).toBe(200);
  expect(fountain.updateAgent).toHaveBeenCalledWith("a", { runtime: "codex", model: "openai/test-model" });
  expect(db.project("p")).toMatchObject({ runtime: "codex", model: "openai/test-model", agentId: "a", environmentId: "e", rev: 2 });
  expect(db.tracksOf("p")).toHaveLength(2);
  expect(db.tracksOf("p")[0]!.rev).toBe(1);
});

test("invalid harness/model pairs are rejected before any settings change", async () => {
  const { route, db, fountain } = await fixture();
  for (const body of [{ runtime: "codex" }, { model: "invented" }, { runtime: "unknown", model: "openai/test-model" }]) {
    const response = await route(request("/api/projects/p/settings", "owner", "PUT", { ...body, name: "Changed" }));
    expect(response.status).toBe(422);
  }
  expect(fountain.updateAgent).not.toHaveBeenCalled();
  expect(db.project("p")).toMatchObject({ name: "Project", runtime: "claude", rev: 1 });
});

test("upstream failure preserves the saved harness and model", async () => {
  const { route, db, fountain } = await fixture();
  fountain.updateAgent.mockRejectedValueOnce(new Error("offline"));
  const response = await route(request("/api/projects/p/settings", "owner", "PUT", { runtime: "codex", model: "openai/test-model" }));
  expect(response.status).toBeGreaterThanOrEqual(500);
  expect(db.project("p")).toMatchObject({ runtime: "claude", model: "anthropic/claude-opus-5", rev: 1 });
});

test("catalog outages allow unrelated edits and preserve current selection", async () => {
  const { route, fountain, db } = await fixture();
  fountain.catalog.mockRejectedValue(new Error("offline"));
  const response = await route(request("/api/projects/p/settings", "owner"));
  expect((await response.json()).data.catalog).toBeNull();
  const saved = await route(request("/api/projects/p/settings", "owner", "PUT", { name: "Renamed", runtime: "claude", model: "anthropic/claude-opus-5" }));
  expect(saved.status).toBe(200);
  expect(db.project("p")?.name).toBe("Renamed");
});

test("machine preparation propagates mint and vault failures instead of starting with stale credentials", async () => {
  const { ctx, project, github, fountain } = await fixture();
  const repo = { ...project, repoFullName: "owner/repo", installationId: 1 };
  github.mintCloneToken.mockRejectedValueOnce(new Error("mint unavailable"));
  await expect(prepareMachine(ctx, repo, fountain as any)).rejects.toThrow("mint unavailable");
  expect(fountain.putSecret).not.toHaveBeenCalled();
  fountain.putSecret.mockRejectedValueOnce(new Error("vault unavailable"));
  await expect(prepareMachine(ctx, repo, fountain as any)).rejects.toThrow("vault unavailable");
  await prepareMachine(ctx, repo, fountain as any);
  expect(fountain.putSecret).toHaveBeenLastCalledWith("vaults", "v", "GITHUB_TOKEN", "installation-token");
});
