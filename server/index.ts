/**
 * The process. Config, a database, a cipher, a router, a port.
 *
 * One port. The app and the track-preview gateway share it and are told
 * apart by Host: `PREVIEW_DOMAIN` subdomains go to the gateway, which listens
 * on loopback and is reached only through `server/preview-front.ts`.
 *
 * The startup log says which of the three integrations are live, because
 * "ravix is running" is not the useful sentence — "running, with GitHub,
 * without a terminal" is. Every missing one has a designed empty state behind
 * it in the UI, so a partial deployment is a legitimate way to run this rather
 * than a broken one, and the log is where you find out which you have.
 */
import { buildRouter } from "./app";
import { loadConfig } from "./config";
import { buildContext } from "./context";
import { Cipher } from "./crypto";
import { Db } from "./db";
import { openSql } from "./sql";
import { PromptQueue } from "./prompt-queue";
import { previews } from "./previews";
import { createPreviewGateway } from "./preview-gateway";
import { createPreviewFront, type PreviewPeer } from "./preview-front";
import { nativeExperiments, type NativeSocketData } from "./native-experiment";
import type { AddressInfo } from "node:net";

const config = loadConfig();
const db = await Db.open(await openSql({ url: config.databaseUrl, dataDir: config.dataDir }));
const cipher = await Cipher.from(config.secret);
const ctx = buildContext({ db, cipher, config });
const promptQueue = new PromptQueue(ctx);
await promptQueue.start();
const handle = buildRouter(ctx);
const previewManager = previews(ctx);
previewManager.start();
const gateway = config.previews ? createPreviewGateway(ctx) : null;
const gatewayPort = gateway ? await new Promise<number>(resolve => gateway.listen(0, "127.0.0.1", () => resolve((gateway.address() as AddressInfo).port))) : 0;
const front = gateway ? createPreviewFront(ctx, gatewayPort) : null;
const native = nativeExperiments(ctx);
await native.start();

const isPreview = (data: NativeSocketData | PreviewPeer): data is PreviewPeer => "preview" in data;
const server = Bun.serve<NativeSocketData | PreviewPeer>({
  port: config.port,
  // A track's stream stays open as long as its tab is; the default idle
  // timeout would cut every one of them at two minutes.
  idleTimeout: 0,
  fetch: (request, server) => {
    if (front?.matches(request)) return front.fetch(request, server);
    return request.headers.get("upgrade")?.toLowerCase() === "websocket" && new URL(request.url).pathname.startsWith("/api/native/") ? native.fetch(request, server) : handle(request);
  },
  websocket: {
    ...native.websocket,
    open: ws => isPreview(ws.data) ? front!.websocket.open(ws as never) : native.websocket.open(ws as never),
    message: (ws, data) => isPreview(ws.data) ? front!.websocket.message(ws as never, data) : native.websocket.message(ws as never, data),
    close: ws => isPreview(ws.data) ? front!.websocket.close(ws as never) : native.websocket.close(ws as never),
  },
});

process.on("SIGTERM", () => {
  previewManager.stop(); promptQueue.stop();
  native.stop();
  gateway?.close(); gateway?.closeAllConnections();
  server.stop(true);
  void db.close().finally(() => process.exit(0));
});

console.log(
  [
    `ravix on :${server.port}`,
    `database=${config.databaseUrl ? "postgres" : `embedded under ${config.dataDir}`}`,
    `fountain=${config.fountainKey ? config.fountainUrl : "MISSING — no machines can be built"}`,
    `github=${config.github ? `app ${config.github.appId} (${config.github.slug})` : "off — no repositories"}`,
    `sprites=${config.sprites ? "on — terminal live" : "off — terminal shows its empty state"}`,
    `public=${config.publicUrl}`,
  ].join("  "),
);
