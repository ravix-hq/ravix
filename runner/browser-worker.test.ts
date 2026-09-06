import { expect, test } from "bun:test";
import { startTestBrowser } from "./browser-test-process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Opt in with an isolated test Chromium executable; never attach to a personal profile.
const executablePath = process.env.SWITCHYARD_BROWSER_TEST_EXECUTABLE;
test.skipIf(!executablePath)("real Chromium: control handoff, storage checkpoints, restart and cross-machine restore", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sy-browser-real-")), secondDirectory = await mkdtemp(join(tmpdir(), "sy-browser-copy-"));
  const token = "test-browser-token-with-at-least-32-characters";
  const site = Bun.serve({ port: 0, fetch: () => new Response(`<!doctype html><title>Browser fixture</title><input aria-label="Name" id="name"><button id="save" onclick="document.cookie='account=machine; path=/'; localStorage.setItem('login','shared'); sessionStorage.setItem('draft','trip'); document.querySelector('output').textContent='Saved'">Save</button><output></output><script>document.querySelector('output').textContent = [document.cookie,localStorage.getItem('login'),sessionStorage.getItem('draft')].join('|')</script>`, { headers: { "content-type": "text/html" } }) });
  const actor = { id: "agent:1", label: "Agent", kind: "agent" }, human = { id: "human:1", label: "Ana", kind: "human" };
  let worker: any, copy: any;
  const rpc = async (command: Record<string, unknown>, target = worker, credential = token) => {
    const response = await fetch(`http://127.0.0.1:${target.port}/command`, { method: "POST", headers: { authorization: `Bearer ${credential}`, "content-type": "application/json" }, body: JSON.stringify(command) });
    return { status: response.status, body: await response.json() };
  };
  try {
    worker = await startTestBrowser({ directory, token, executablePath: executablePath! });
    expect((await rpc({ action: "status" }, worker, "wrong")).status).toBe(403);
    const revision = (await rpc({ action: "acquire", actor })).body.revision;
    const opened = await rpc({ action: "open", actor, url: `http://127.0.0.1:${site.port}` });
    expect(opened.status).toBe(200); const tabId = opened.body.tabId;
    expect((await rpc({ action: "acquire", actor: { ...actor, id: "agent:2" } })).status).toBe(409);
    expect((await rpc({ action: "acquire", actor: human })).status).toBe(200);
    expect((await rpc({ action: "click", actor, revision, tabId, x: .1, y: .1 })).status).toBe(409);
    expect((await rpc({ action: "click", actor: human, revision: "stale", tabId, x: .1, y: .1 })).status).toBe(409);
    expect((await rpc({ action: "click", actor: human, revision, tabId, x: 40 / 1280, y: 18 / 800 })).status).toBe(200);
    await rpc({ action: "text", actor: human, revision, tabId, text: "Machine account" });
    await rpc({ action: "key", actor: human, revision, tabId, key: "Tab" });
    await rpc({ action: "key", actor: human, revision, tabId, key: "Enter" });
    const inspected = await rpc({ action: "inspect", tabId });
    expect(inspected.body.text).toContain("Machine account");
    expect(inspected.body.text).toContain("Saved");
    const shot = await rpc({ action: "screenshot", tabId });
    expect(Buffer.from(shot.body.image, "base64").subarray(0, 2).toString("hex")).toBe("ffd8");
    const cp = (await rpc({ action: "checkpoint", actor: human })).body;
    expect(cp.storage.cookies.some((cookie: any) => cookie.name === "account" && cookie.value === "machine")).toBe(true);
    expect(cp.tabs[0].sessionStorage.draft).toBe("trip");
    await worker.close();
    worker = await startTestBrowser({ directory, token, executablePath: executablePath! });
    const afterRestart = (await rpc({ action: "status" })).body;
    expect(afterRestart.controller).toBeNull();
    expect(afterRestart.revision).not.toBe(revision);
    expect((await rpc({ action: "inspect", tabId: afterRestart.tabs[0].id })).body.text).toContain("account=machine|shared");
    copy = await startTestBrowser({ directory: secondDirectory, token, executablePath: executablePath! });
    await rpc({ action: "acquire", actor: human }, copy);
    const restored = await rpc({ action: "restore", actor: human, checkpoint: cp }, copy);
    expect(restored.status).toBe(200);
    expect(restored.body.controller).toBeNull();
    expect((await rpc({ action: "inspect", tabId: restored.body.tabs[0].id }, copy)).body.text).toContain("account=machine|shared|trip");
    expect((await rpc({ action: "open", actor: human, url: "file:///etc/passwd" }, copy)).status).not.toBe(200);
    await rpc({ action: "acquire", actor: human }, copy);
    expect((await rpc({ action: "restore", actor: human, checkpoint: { ...cp, version: 999 } }, copy)).status).toBe(422);
    expect((await rpc({ action: "status" }, copy)).body.tabs).toHaveLength(1);
    // A failure after the old context closes must restore its manifest too.
    const failed = await rpc({ action: "restore", actor: human, checkpoint: { ...cp, storage: { cookies: [{ name: "invalid", value: null }], origins: [] } } }, copy);
    expect(failed.status).toBe(422);
    await copy.close();
    copy = await startTestBrowser({ directory: secondDirectory, token, executablePath: executablePath! });
    const rolledBack = (await rpc({ action: "status" }, copy)).body;
    expect(rolledBack.tabs).toHaveLength(1);
    expect((await rpc({ action: "inspect", tabId: rolledBack.tabs[0].id }, copy)).body.text).toContain("account=machine|shared|trip");
  } finally {
    await copy?.close(); await worker?.close(); site.stop(true);
    await rm(directory, { recursive: true, force: true }); await rm(secondDirectory, { recursive: true, force: true });
  }
}, 90000);
