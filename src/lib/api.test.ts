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

test("simultaneous files and diff share one wake and retry their reads", async () => {
  let awake = false;
  let wakes = 0;
  mock(async (url, init) => {
    if (url.endsWith("/exec")) {
      wakes++;
      expect(init?.method).toBe("POST");
      expect(JSON.parse(String(init?.body))).toEqual({ command: ":", timeoutSec: 30 });
      await new Promise((resolve) => setTimeout(resolve, 5));
      awake = true;
      return ok({ code: 0 });
    }
    return awake ? ok({ path: url }) : asleep();
  });
  const results = await Promise.all([api.files("shared"), api.diff("shared")]);
  expect(wakes).toBe(1);
  expect(results.map((r) => r.path)).toEqual(["/api/tracks/shared/files", "/api/tracks/shared/diff"]);
});

test("wake failures hide provider details and can be retried", async () => {
  let wakes = 0;
  mock((url) => {
    if (url.endsWith("/exec")) {
      wakes++;
      return Response.json({ error: "exec_failed", message: "private provider details" }, { status: 502 });
    }
    return asleep();
  });
  for (let i = 0; i < 2; i++) {
    await expect(api.file("failed", "a.txt")).rejects.toMatchObject({ code: "machine_asleep", message: "The machine is asleep. Try waking it again, or send a message in this track to resume work." });
  }
  expect(wakes).toBe(2);
});

test("a stale suspended status produces guidance without a retry loop", async () => {
  let reads = 0;
  mock((url) => { if (url.endsWith("/exec")) return ok({ code: 0 }); reads++; return asleep(); });
  await expect(api.diff("stale")).rejects.toMatchObject({ code: "machine_asleep" });
  expect(reads).toBe(2);
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
