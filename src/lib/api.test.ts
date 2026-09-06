import { afterEach, expect, test } from "bun:test";
import { api } from "./api";

const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = originalFetch; });
const asleep = () => Response.json({ error: "sandbox_not_ready", message: "the sandbox is suspended; files are read from a ready one only" }, { status: 409 });
const ok = (data: unknown) => Response.json({ data });

function mock(handler: (url: string, init?: RequestInit) => Response | Promise<Response>) {
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => Promise.resolve(handler(String(url), init))) as typeof fetch;
}

test("ready file reads do not wake the machine", async () => {
  const calls: string[] = [];
  mock((url) => { calls.push(url); return ok({ path: "/work", entries: [], truncated: false }); });
  expect(await api.files("ready")).toEqual({ path: "/work", entries: [], truncated: false });
  expect(calls).toEqual(["/api/tracks/ready/files"]);
});

test("sleeping file reads do not run commands or send agent turns", async () => {
  const calls: string[] = [];
  mock((url) => { calls.push(url); return asleep(); });
  await expect(api.files("sleeping")).rejects.toMatchObject({ code: "machine_asleep" });
  expect(calls).toEqual(["/api/tracks/sleeping/files"]);
});

test("explicit wakes share a queued turn and wait for Fountain readiness", async () => {
  let awake = false;
  let wakes = 0;
  mock(async (url, init) => {
    if (url.endsWith("/prompt")) {
      wakes++;
      expect(init?.method).toBe("POST");
      const body = JSON.parse(String(init?.body));
      expect(body.requestId).toMatch(/^[a-f0-9-]{36}$/);
      expect(body.prompt).toContain("Do not edit any files");
      await new Promise((resolve) => setTimeout(resolve, 5));
      // Queue acceptance alone does not mean the machine is ready.
      setTimeout(() => { awake = true; }, 20);
      return ok({ ok: true });
    }
    expect(url).not.toContain("/exec");
    return awake ? ok({ path: url }) : asleep();
  });
  const results = await Promise.all([api.files("shared", undefined, true), api.diff("shared", true)]);
  expect(wakes).toBe(1);
  expect(results.map((r) => r.path)).toEqual(["/api/tracks/shared/files", "/api/tracks/shared/diff"]);
});

test("rejected wake turns show the error and can be retried", async () => {
  let wakes = 0;
  mock((url) => {
    if (url.endsWith("/prompt")) {
      wakes++;
      return Response.json({ error: "queue_full", message: "Cancel a queued prompt first." }, { status: 409 });
    }
    return asleep();
  });
  for (let i = 0; i < 2; i++) {
    await expect(api.diff("failed", true)).rejects.toMatchObject({ code: "queue_full" });
  }
  expect(wakes).toBe(2);
});

test("starting machines and unrelated failures never trigger a wake", async () => {
  let calls = 0;
  mock(() => { calls++; return Response.json({ error: "sandbox_not_ready", message: "sandbox is starting" }, { status: 409 }); });
  await expect(api.files("starting")).rejects.toMatchObject({ code: "machine_starting" });
  expect(calls).toBe(1);
  mock(() => { calls++; return Response.json({ error: "path_not_found", message: "Missing" }, { status: 404 }); });
  await expect(api.files("missing")).rejects.toMatchObject({ code: "path_not_found", message: "Missing" });
  expect(calls).toBe(2);
});

test("a wake that stays queued stops polling without sending another turn", async () => {
  const originalTimeout = globalThis.setTimeout;
  let wakes = 0;
  let reads = 0;
  globalThis.setTimeout = ((callback: () => void) => {
    queueMicrotask(callback);
    return 0;
  }) as unknown as typeof setTimeout;
  try {
    mock((url) => {
      if (url.endsWith("/prompt")) { wakes++; return ok({ ok: true }); }
      reads++;
      return asleep();
    });
    await expect(api.diff("queued", true)).rejects.toMatchObject({ code: "machine_starting" });
    expect(wakes).toBe(1);
    expect(reads).toBe(31);
    await expect(api.diff("queued")).rejects.toMatchObject({ code: "machine_starting" });
    await expect(api.files("queued", undefined, true)).rejects.toMatchObject({ code: "machine_starting" });
    expect(wakes).toBe(1);
  } finally {
    globalThis.setTimeout = originalTimeout;
  }
});
