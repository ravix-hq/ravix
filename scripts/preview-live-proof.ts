/** Temporary live routing harness. Run inside Switchyard's pod: credentials
 * remain in its environment. Does not mutate the production SQLite database. */
import { Database } from "bun:sqlite";
import { Db } from "../server/db";
import { loadConfig } from "../server/config";
import { buildContext } from "../server/context";
import { Cipher, sha256, randomToken } from "../server/crypto";
import { previews, previewOrigin } from "../server/previews";
import { createPreviewGateway } from "../server/preview-gateway";
import { machineOf, spriteFor } from "../server/tracks";
import { shq } from "../server/sprites";

const source = new Database("/data/switchyard.sqlite", { readonly: true });
const project = source.query("SELECT * FROM projects WHERE name='demos' AND archived_at IS NULL").get() as Record<string, string>;
if (!project) throw new Error("Need the selected Demos project.");
const tracks = source.query("SELECT * FROM tracks WHERE project_id=? AND slug IN ('hamlet','elkhart') AND closed_at IS NULL ORDER BY slug").all(project.id!) as Record<string, string>[];
if (tracks.length !== 2) throw new Error("Need the two selected open Demos tracks.");
const config = loadConfig({ ...process.env, DATA_DIR: "/tmp/switchyard-preview-proof", SWITCHYARD_SECRET: "disposable-preview-proof-secret", PUBLIC_URL: "http://localhost:18083", PREVIEW_DOMAIN: "preview.localhost", PREVIEW_PORT: "18082" });
const db = new Db(config.dbPath);
const ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
const owner = db.upsertUser({ githubId: "proof", login: "proof", name: "Preview proof", avatarUrl: null, tokenEnc: "proof" });
if (!db.project(project.id!)) db.createProject({ id: project.id!, userId: owner.id, name: "Demos", repoFullName: null, repoPrivate: 0, defaultBranch: null, installationId: null,
  agentId: project.agent_id!, environmentId: project.environment_id!, vaultId: project.vault_id || null, runtime: "claude", model: "test", instructions: "" });
const session = randomToken(); db.createSession(owner.id, await sha256(session), 60 * 60_000);
for (const t of tracks) {
  if (!db.track(t.id!)) db.createTrack({ id: t.id!, projectId: project.id!, conversationId: t.conversation_id!, slug: t.slug!, title: t.title!, branch: t.branch!, workdir: t.workdir!, originKind: "blank", originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "proof" });
}
const machine = await machineOf(ctx.fountain!, db.project(project.id!)!);
const sprite = await spriteFor(ctx.fountain!, machine!.sandboxId);
if (!sprite) throw new Error("Demos is not on Sprites.");
const directory = ".switchyard-preview-proof";
const vite = "/home/sprite/work/hamlet/apps/switchyard/node_modules/vite/bin/vite.js";
const manager = previews(ctx);
const revision = new Map<string, number>();
async function write(t: Record<string, string>, version: number) {
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${t.slug} preview</title></head><body style="font:24px system-ui;padding:32px"><h1>${t.slug} · version ${version}</h1><p>Independent Demos track. Live working copy.</p><script type="module" src="/main.js"></script></body></html>`;
  const main = `document.body.dataset.loaded = 'yes'; if(import.meta.hot) import.meta.hot.accept();`;
  const root = `${t.workdir}/${directory}`;
  const command = `mkdir -p ${shq(root)} && printf %s ${shq(html)} > ${shq(root + "/index.html")} && printf %s ${shq(main)} > ${shq(root + "/main.js")} && printf %s ${shq('export default {server:{allowedHosts:[".preview.localhost"]}}')} > ${shq(root + "/vite.config.mjs")}`;
  const r = await ctx.sprites!.exec(sprite!, ["sh", "-lc", command], 15); if (r.code) throw new Error(r.stderr);
  revision.set(t.id!, version);
}
if (process.argv.includes("--cleanup")) {
  for (const t of tracks) {
    if (db.previews.get(t.id!)?.config?.directory !== directory) { console.log("No owned fixture to clean", t.slug); continue; }
    await manager.stopService(t.id!, true);
    const r = await ctx.sprites!.exec(sprite, ["rm", "-rf", `${t.workdir}/${directory}`], 15);
    console.log("cleanup", t.slug, r.code);
  }
  process.exit(0);
}
// Never overwrite a pre-existing fixture or working-copy directory.
for (const t of tracks) {
  if (db.previews.get(t.id!)?.cleanup) throw new Error("Remove the disposable /tmp/switchyard-preview-proof database after cleanup before running again.");
  const check = await ctx.sprites!.exec(sprite, ["sh", "-lc", `test ! -e ${shq(`${t.workdir}/${directory}`)}`], 15);
  if (check.code) throw new Error(`Fixture already exists on ${t.slug}; inspect it before running again.`);
}
for (const t of tracks) {
  await write(t, 1);
  await manager.configure(t.id!, { directory, command: `exec node ${shq(vite)} --host 127.0.0.1 --port "$PORT" --strictPort`, readinessPath: "/" });
  await manager.startService(t.id!);
  console.log(t.slug, JSON.stringify(manager.info(t.id!)));
}
createPreviewGateway(ctx).listen(18082, "127.0.0.1");
manager.start();
Bun.serve({ port: 18083, hostname: "127.0.0.1", async fetch(req) {
  const url = new URL(req.url);
  if (req.headers.get("host") !== "localhost:18083") return new Response("Invalid host", { status: 403 });
  if (url.pathname.startsWith("/open/")) {
    const t = tracks.find(t => t.slug === url.pathname.split("/")[2]);
    if (!t) return new Response("missing", { status: 404 });
    const ticket = randomToken();
    db.previews.grant({ hash: await sha256(ticket), trackId: t.id!, sessionHash: await sha256(session), expires: Date.now() + 60_000, kind: "ticket" });
    return Response.redirect(`${previewOrigin(ctx, db.previews.get(t.id!)!)}/__switchyard/open#${ticket}`);
  }
  if (req.method === "POST" && url.pathname.startsWith("/edit/")) {
    if (req.headers.get("origin") !== "http://localhost:18083") return new Response("Invalid origin", { status: 403 });
    const t = tracks.find(t => t.slug === url.pathname.split("/")[2]);
    if (!t) return new Response("missing", { status: 404 });
    await write(t, (revision.get(t.id!) ?? 1) + 1);
    return Response.redirect("http://localhost:18083/", 303);
  }
  return new Response(`<h1>Live Demos routing verification</h1>${tracks.map(t => `<p><a href="/open/${t.slug}">Open ${t.slug}</a> · <a href="${previewOrigin(ctx, db.previews.get(t.id!)!)}">Unsigned ${t.slug}</a></p><form method="post" action="/edit/${t.slug}"><button>Edit ${t.slug}</button></form>`).join("")}`, { headers: { "content-type": "text/html" } });
} });
console.log("Live proof gateway 18082, launcher 18083. Stop and clean up after verification.");
