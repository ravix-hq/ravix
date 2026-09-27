import { afterEach, expect, test } from "bun:test";
import { fountain } from "./server";

process.env.MOCK_RUNTIME_CAPACITY = "2";
const owned: string[] = [];

async function request(method: string, path: string, body?: unknown) {
  const url = new URL(`http://mock.test${path}`);
  const response = await fountain(new Request(url, {
    method, headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  }), url);
  if (!response) throw new Error(`Unimplemented route ${method} ${path}`);
  return { status: response.status, body: response.status === 204 ? null : await response.json() };
}

async function create(kind: string, fields = {}) {
  const result = await request("POST", `/api/${kind}`, fields);
  expect(result.status).toBe(200);
  return result.body.data;
}

async function fixture(runtime = "claude") {
  const environment = await create("environments", { repositories: [{ mount_path: "/workspace/repo" }] });
  const vault = await create("vaults");
  const home = await create("agents", { runtime });
  const guest = await create("agents", { runtime: runtime === "claude" ? "codex" : "claude" });
  const identity = { agent_id: home.id, environment_id: environment.id, vault_id: vault.id };
  const result = await request("POST", "/api/conversations", { ...identity, prompt: "initialize" });
  expect(result.status).toBe(200);
  const first = result.body.data;
  owned.push(first.sandbox_id);
  await request("POST", `/api/conversations/${first.id}/interrupt`);
  return { identity, home, guest, first, sandbox_id: first.sandbox_id };
}

async function attach(f: Awaited<ReturnType<typeof fixture>>, agent_id = f.home.id, extra = {}) {
  return request("POST", "/api/conversations", { ...f.identity, sandbox_id: f.sandbox_id, agent_id, ...extra });
}

async function idle(id: string) {
  const deadline = Date.now() + 6000;
  while (Date.now() < deadline) {
    const result = await request("GET", `/api/conversations/${id}`);
    if (result.body.data.status === "idle") return;
    await Bun.sleep(10);
  }
  throw new Error("turn did not become idle");
}

afterEach(async () => {
  for (const id of owned.splice(0)) await request("DELETE", `/api/sandboxes/${id}`);
});

for (const runtime of ["claude", "codex"]) {
  test(`${runtime} home accepts the other runtime and many home threads, refusing identity and runtime mismatches`, async () => {
    const f = await fixture(runtime);
    const guest = await attach(f, f.guest.id);
    expect(guest.status).toBe(200);
    expect(guest.body.data.sandbox_id).toBe(f.sandbox_id);
    expect((await attach(f)).status).toBe(200);
    expect((await attach(f, f.guest.id)).status).toBe(200);
    const same = await create("agents", { runtime });
    const third = await create("agents", { runtime: f.guest.runtime });
    for (const agent of [same, third]) {
      expect(await attach(f, agent.id)).toMatchObject({ status: 422, body: { error: "sandbox_runtime_mismatch" } });
    }
    for (const extra of [{ environment_id: null }, { vault_id: "different" }]) {
      expect(await attach(f, f.guest.id, extra)).toMatchObject({ status: 422, body: { error: "sandbox_identity_mismatch" } });
    }
    const foreign = await create("agents", { runtime: f.guest.runtime, user_id: "someone-else" });
    expect(await attach(f, foreign.id)).toMatchObject({ status: 422, body: { error: "sandbox_identity_mismatch" } });
    expect(await attach(f, f.home.id, { sandbox_id: "missing" })).toMatchObject({ status: 404, body: { error: "sandbox_not_found" } });
  });
}

test("vaults partition disks while home and guest threads share changes, and termination retains them", async () => {
  const f = await fixture();
  const second = await request("POST", "/api/conversations", { ...f.identity, vault_id: "other-track", prompt: "initialize" });
  const box2 = second.body.data.sandbox_id;
  owned.push(box2);
  expect(box2).not.toBe(f.sandbox_id);
  const guest = (await attach(f, f.guest.id)).body.data;
  await request("POST", `/api/conversations/${guest.id}/prompts`, { prompt: "[ravix] Open this track. /home/sprite/work/same-path" });
  await idle(guest.id);
  const path = "/file?path=/home/sprite/work/same-path/.keep";
  expect((await request("GET", `/api/sandboxes/${f.sandbox_id}${path}`)).status).toBe(200);
  expect((await request("GET", `/api/sandboxes/${box2}${path}`)).status).toBe(404);
  expect((await attach(f)).body.data.sandbox.id).toBe(f.sandbox_id);
  await request("POST", `/api/conversations/${guest.id}/terminate`);
  expect((await request("GET", `/api/sandboxes/${f.sandbox_id}${path}`)).status).toBe(200);
  expect((await request("GET", `/api/conversations/${f.first.id}`)).body.data.status).toBe("idle");
});

test("capacity is reserved atomically per runtime, with no queue and no dropped launch prompts", async () => {
  const f = await fixture();
  const threads = await Promise.all([attach(f), attach(f), attach(f), attach(f, f.guest.id)]);
  const [one, two, three, guest] = threads.map(result => result.body.data);
  const prompt = (id: string) => request("POST", `/api/conversations/${id}/prompts`, { prompt: "work" });
  expect((await prompt(one.id)).status).toBe(200);
  expect((await prompt(two.id)).status).toBe(200);
  expect(await prompt(three.id)).toMatchObject({ status: 409, body: { error: "sandbox_at_capacity" } });
  expect(await prompt(one.id)).toMatchObject({ status: 409, body: { error: "conversation_busy" } });
  expect((await prompt(guest.id)).status).toBe(200);
  expect(await attach(f, f.home.id, { prompt: "cannot start" })).toMatchObject({ status: 409, body: { error: "sandbox_at_capacity" } });
  await request("POST", `/api/conversations/${one.id}/interrupt`);
  expect((await prompt(three.id)).status).toBe(200);
  expect((await request("GET", `/api/conversations/${one.id}/turns`)).body.data).toHaveLength(1);
});

test("delete ends all home/guest conversations, retains siblings, and retains terminal rows; rebuild creates a new disk", async () => {
  const f = await fixture();
  const sibling = await fixture();
  const guest = (await attach(f, f.guest.id, { prompt: "[ravix] Open this track. /home/sprite/work/late" })).body.data;
  expect((await request("POST", `/api/sandboxes/${f.sandbox_id}`)).status).toBe(405);
  expect((await request("DELETE", `/api/sandboxes/${f.sandbox_id}`)).status).toBe(204);
  expect(await request("GET", `/api/sandboxes/${f.sandbox_id}`)).toMatchObject({ status: 200, body: { data: { status: "terminated" } } });
  expect(await request("DELETE", `/api/sandboxes/${f.sandbox_id}`)).toMatchObject({ status: 422, body: { error: "sandbox_not_resettable" } });
  for (const id of [f.first.id, guest.id]) {
    expect((await request("GET", `/api/conversations/${id}`)).body.data.status).toBe("terminated");
  }
  expect((await request("GET", `/api/sandboxes/${sibling.sandbox_id}`)).status).toBe(200);
  const rebuilt = await request("POST", "/api/conversations", { ...f.identity, prompt: "initialize" });
  const fresh = rebuilt.body.data.sandbox_id;
  owned.push(fresh);
  expect(fresh).not.toBe(f.sandbox_id);
  await idle(rebuilt.body.data.id);
  expect((await request("GET", `/api/conversations/${guest.id}`)).body.data.status).toBe("terminated");
  expect((await request("GET", `/api/sandboxes/${fresh}/file?path=/home/sprite/work/late/.keep`)).status).toBe(404);
});

test("home agent deletion owns the lifecycle; deleting a guest only ends its conversations", async () => {
  const f = await fixture();
  const guest = (await attach(f, f.guest.id)).body.data;
  await request("DELETE", `/api/agents/${f.guest.id}`);
  expect((await request("GET", `/api/conversations/${guest.id}`)).body.data.status).toBe("terminated");
  expect((await request("GET", `/api/sandboxes/${f.sandbox_id}`)).status).toBe(200);
  await request("DELETE", `/api/agents/${f.home.id}`);
  expect(await request("GET", `/api/sandboxes/${f.sandbox_id}`)).toMatchObject({ status: 200, body: { data: { status: "terminated" } } });
});

test("a discarded create response can be reconciled by full identity without allocating twice", async () => {
  const f = await fixture();
  const before = (await request("GET", "/api/sandboxes?status=ready")).body.data.length;
  // Deliberately discard the conversation-create acknowledgement at the client boundary.
  await request("POST", "/api/conversations", { ...f.identity, vault_id: "lost-vault", channel_id: "operation-key", prompt: "lost reply" });
  const listed = (await request("GET", "/api/sandboxes?status=ready")).body.data;
  const matching = listed.filter((box: any) => box.agent_id === f.identity.agent_id &&
    box.environment_id === f.identity.environment_id && box.vault_id === "lost-vault");
  expect(matching).toHaveLength(1);
  expect(matching[0].id).not.toBe(f.sandbox_id);
  owned.push(matching[0].id);
  expect(listed).toHaveLength(before + 1);
  expect((await request("GET", "/api/sandboxes?status=parked")).body.data).toEqual([]);
  expect((await request("GET", `/api/sandboxes/${f.sandbox_id}`)).body.data.status).toBe("ready");
});

test("vault copy is an atomic owned snapshot and never returns secret values", async () => {
  const source = await create("vaults", { name: crypto.randomUUID(), description: "project", metadata: { project: "p" } });
  await request("POST", `/api/vaults/${source.id}/secrets`, { key: "TOKEN", value: "private-original" });
  const name = crypto.randomUUID();
  const result = await request("POST", `/api/vaults/${source.id}/copy`, { name });
  expect(result.status).toBe(201);
  expect(result.body.data).toMatchObject({ name, description: "project", metadata: { project: "p" }, secret_count: 1 });
  expect(JSON.stringify(result.body)).not.toContain("private-original");
  expect((await request("POST", `/api/vaults/${source.id}/copy`, { name })).status).toBe(422);
  expect((await request("POST", `/api/vaults/${source.id}/copy`, {})).status).toBe(422);
  await request("POST", `/api/vaults/${source.id}/secrets`, { key: "LATER", value: "later" });
  const keys = await request("GET", `/api/vaults/${result.body.data.id}/secrets`);
  expect(JSON.stringify(keys.body)).toContain("TOKEN");
  expect(JSON.stringify(keys.body)).not.toContain("LATER");
  const foreign = await create("vaults", { user_id: "another-owner" });
  expect(await request("POST", `/api/vaults/${foreign.id}/copy`, { name: crypto.randomUUID() }))
    .toEqual(await request("POST", "/api/vaults/malformed/copy", { name: crypto.randomUUID() }));
  await request("POST", `/api/vaults/${source.id}/secrets`, { key: "BAD", value: "mock:cannot-decrypt" });
  const before = await request("GET", "/api/vaults");
  expect(await request("POST", `/api/vaults/${source.id}/copy`, { name: crypto.randomUUID() }))
    .toMatchObject({ status: 422, body: { error: "secret_not_copyable", key: "BAD" } });
  expect(await request("GET", "/api/vaults")).toEqual(before);
  for (const id of [source.id, result.body.data.id, foreign.id]) {
    expect((await request("DELETE", `/api/vaults/${id}`)).status).toBe(204);
    expect((await request("GET", `/api/vaults/${id}`)).status).toBe(404);
    expect((await request("DELETE", `/api/vaults/${id}`)).status).toBe(404);
  }
});

test("an inference revision invalidates both runtimes; a connected runtime resumes on the same disk", async () => {
  const root = "/api/account/inference-credential-sets";
  const set = (await request("POST", root, { name: `revision-${crypto.randomUUID()}` })).body.data;
  await request("PUT", `${root}/${set.id}/credentials/anthropic_api_key`, { value: "fixture-claude" });
  await request("PUT", `${root}/${set.id}/credentials/openai_api_key`, { value: "fixture-codex" });
  const home = await create("agents", { runtime: "claude", inference_credential_id: set.id });
  const guest = await create("agents", { runtime: "codex", inference_credential_id: set.id });
  const opening = await request("POST", "/api/conversations", { agent_id: home.id, prompt: "initialize" });
  const first = opening.body.data;
  owned.push(first.sandbox_id);
  await request("POST", `/api/conversations/${first.id}/interrupt`);
  const second = (await request("POST", "/api/conversations", {
    agent_id: guest.id, sandbox_id: first.sandbox_id,
  })).body.data;
  await request("DELETE", `${root}/${set.id}/credentials/openai_api_key`);
  for (const id of [first.id, second.id]) {
    expect((await request("GET", `/api/conversations/${id}`)).body.data.status).toBe("terminated");
    expect(await request("POST", `/api/conversations/${id}/prompts`, { prompt: "resume" }))
      .toMatchObject({ status: 409, body: { error: "inference_source_changed" } });
  }
  const renewed = await request("POST", "/api/conversations", {
    agent_id: home.id, sandbox_id: first.sandbox_id, inference_credential_id: set.id, channel_id: "revision-recovery",
  });
  expect(renewed.status).toBe(200);
  expect(renewed.body.data.sandbox_id).toBe(first.sandbox_id);
  expect((await request("POST", `/api/conversations/${renewed.body.data.id}/prompts`, { prompt: "resume" })).status).toBe(200);
  const disconnected = (await request("POST", "/api/conversations", {
    agent_id: guest.id, sandbox_id: first.sandbox_id, inference_credential_id: set.id,
  })).body.data;
  expect(await request("POST", `/api/conversations/${disconnected.id}/prompts`, { prompt: "resume" }))
    .toMatchObject({ status: 409, body: { error: "inference_credential_unusable" } });
});
