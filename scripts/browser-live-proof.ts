/** Local end-to-end fixture: real UI, routes and Chromium; only Sprites transport
 * is substituted. Uses temporary shared profiles and no personal credentials. */
import { startTestBrowser } from "../runner/browser-test-process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Db } from "../server/db";
import { Cipher, sha256 } from "../server/crypto";
import { loadConfig } from "../server/config";
import { buildContext } from "../server/context";
import { buildRouter } from "../server/app";
import { browsers } from "../server/browsers";
import { Sprites } from "../server/sprites";
import { HttpError } from "../server/http";

const executablePath = process.env.SWITCHYARD_BROWSER_TEST_EXECUTABLE;
if (!executablePath) throw Error("Set SWITCHYARD_BROWSER_TEST_EXECUTABLE to an installed Chromium executable.");
const directory = await mkdtemp(join(tmpdir(), "sy-browser-ui-"));
const port = Number(process.env.BROWSER_PROOF_PORT || 5199), origin = `http://127.0.0.1:${port}`;
const config = loadConfig({ DATA_DIR: directory, SWITCHYARD_SECRET: "local-proof-secret-not-a-real-credential", PUBLIC_URL: origin, FOUNTAIN_API_KEY: "fixture", SPRITES_TOKEN: "fixture", SHARED_BROWSER: "1" });
const db = new Db(config.dbPath), ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
const owner = db.upsertUser({ githubId: "proof", login: "proof", name: "Local proof", avatarUrl: null, tokenEnc: "fixture" });
db.createSession(owner.id, await sha256("local-proof"), 3600000);
db.createProject({ id: "proof", userId: owner.id, name: "Proof", repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null, agentId: "proof", environmentId: "proof", vaultId: null, runtime: "claude", model: "test", instructions: "" });
db.createTrack({ id: "proof", projectId: "proof", conversationId: "proof", slug: "proof", title: "Proof", branch: "proof", workdir: "/work/proof", originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: owner.login });
const token = "local-proof-worker-token-not-a-real-credential";
const worker = await startTestBrowser({ directory: join(directory, "profile"), executablePath, token });
db.browsers.save({ id: "proof", projectId: "proof", profile: "shared", sprite: "proof", sandboxId: "proof", state: "ready", error: null, tokenEnc: await ctx.cipher.encrypt(token) });
const manager = browsers(ctx);
manager.destination = async () => ({ sprite: "proof", sandboxId: "proof" });
manager.transport = async (_row, body) => {
  const response = await fetch(`http://127.0.0.1:${worker.port}/command`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) });
  const value = await response.json();
  if (!response.ok) throw new HttpError(response.status, "browser_command", value.error);
  return value;
};
class LocalSprites extends Sprites { async activity() {} }
ctx.sprites = new LocalSprites({ token: "fixture", baseUrl: "unused" });
const built = await Bun.build({ entrypoints: [join(import.meta.dir, "browser-proof-ui.tsx")], target: "browser", minify: false });
if (!built.success) throw Error(String(built.logs));
const js = built.outputs.find(output => output.path.endsWith(".js"))!, css = built.outputs.find(output => output.path.endsWith(".css"))!;
const router = buildRouter(ctx);
const server = Bun.serve({ port, hostname: "127.0.0.1", fetch(req) {
  const path = new URL(req.url).pathname;
  if (path.startsWith("/api/")) return router(req);
  if (path === "/app.js") return new Response(js, { headers: { "content-type": "text/javascript" } });
  if (path === "/app.css") return new Response(css, { headers: { "content-type": "text/css" } });
  if (path === "/fixture") return new Response(`<!doctype html><style>body{font:24px system-ui;padding:50px;background:#faf7f0;color:#222}input,button{font:inherit;padding:12px;margin:8px}output{display:block;margin:20px}</style><title>Trip planner fixture</title><h1>Plan a trip</h1><label>Name <input id="name" aria-label="Name"></label><button onclick="localStorage.setItem('name',document.querySelector('input').value);document.cookie='account=machine; path=/';document.querySelector('output').textContent='Saved for '+localStorage.getItem('name')">Save</button><output></output><script>document.querySelector('output').textContent=localStorage.getItem('name')?'Welcome back, '+localStorage.getItem('name'):'No trip saved yet'</script>`, { headers: { "content-type": "text/html" } });
  return new Response('<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>Browser proof</title><link rel="stylesheet" href="/app.css"><div id="root"></div><script type="module" src="/app.js"></script>', { headers: { "content-type": "text/html", "set-cookie": "switchyard_session=local-proof; Path=/; HttpOnly; SameSite=Lax" } });
} });
console.log(`Browser proof: ${origin}`);
let closing = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => {
  if (closing) return; closing = true;
  void worker.close().finally(async () => { server.stop(true); db.close(); await rm(directory, { recursive: true, force: true }); process.exit(0); });
});
