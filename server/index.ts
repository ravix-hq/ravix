/**
 * The process. Config, a database, a cipher, a router, a port.
 *
 * The startup log says which of the three integrations are live, because
 * "switchyard is running" is not the useful sentence — "running, with GitHub,
 * without a terminal" is. Every missing one has a designed empty state behind
 * it in the UI, so a partial deployment is a legitimate way to run this rather
 * than a broken one, and the log is where you find out which you have.
 */
import { buildRouter } from "./app";
import { loadConfig } from "./config";
import { buildContext } from "./context";
import { Cipher } from "./crypto";
import { Db } from "./db";
import { PromptQueue } from "./prompt-queue";

const config = loadConfig();
const db = new Db(config.dbPath);
const cipher = await Cipher.from(config.secret);
const ctx = buildContext({ db, cipher, config });
const promptQueue = new PromptQueue(ctx);
promptQueue.start();
const handle = buildRouter(ctx);

const server = Bun.serve({
  port: config.port,
  // A track's stream stays open as long as its tab is; the default idle
  // timeout would cut every one of them at two minutes.
  idleTimeout: 0,
  fetch: handle,
});

console.log(
  [
    `switchyard on :${server.port}`,
    `fountain=${config.fountainKey ? config.fountainUrl : "MISSING — no machines can be built"}`,
    `github=${config.github ? `app ${config.github.appId} (${config.github.slug})` : "off — no repositories"}`,
    `sprites=${config.sprites ? "on — terminal live" : "off — terminal shows its empty state"}`,
    `public=${config.publicUrl}`,
  ].join("  "),
);
