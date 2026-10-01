/** Local Sprites fixture. The service API is simulated; each app is a real
 * Node/Vite process so browser exercises cover HTTP and actual HMR traffic.
 * The exec WebSocket in TTY mode is a small pretend shell (see below). */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, createServer, type Socket } from "node:net";
import type { ServerWebSocket, Subprocess } from "bun";

// `port` is the service's $PORT on its own sprite; `hostPort` is where the
// process really listens. Every sprite has its own ports, as a real one does,
// but every mock sprite is this one host: two tracks on different sprites
// both given 20000 used to be two Vites fighting over one host port, and the
// loser's preview answered with the winner's app (or not at all).
interface Service { name: string; sprite: string; dir: string; root: string; port: number; hostPort: number; definition: Record<string, unknown>; status: string; logs: string; process?: Subprocess; version: number; }
const services = new Map<string, Service>();
// A worktree's Git state for the Checks tab, per sprite: some edits and a
// commit not yet on GitHub, so `python3 scripts/dev-mock.py` shows every row.
// A commit message containing "reject" is refused at the push, as a remote
// with newer commits would.
interface GitFixture { uncommitted: string[]; unpushed: number; upstream: boolean }
const worktrees = new Map<string, GitFixture>();
function gitExec(sprite: string, script: string): [string, number] {
  const key = `${sprite}:${/cd '([^']+)'/.exec(script)?.[1] ?? ""}`;
  const git = worktrees.get(key) ?? { uncommitted: [" M lib/app.ex", " M README.md", "?? lib/app/search.ex"], unpushed: 1, upstream: false };
  worktrees.set(key, git);
  const branch = `ravix/${/cd '[^']*\/([^'/]+)'/.exec(script)?.[1] ?? "track"}`;
  if (script.includes("__ravix_git__"))
    return [`${git.uncommitted.join("\n")}\n__ravix_git__\n${branch}\n${git.upstream ? "upstream" : "none"} ${git.unpushed}\n`, 0];
  if (script.includes("git commit")) {
    if (git.uncommitted.length === 0) return ["", 13];
    git.uncommitted = []; git.unpushed++;
    if (/git commit -q -m '[^']*reject/i.test(script))
      return [` ! [rejected]        HEAD -> ${branch} (fetch first)\nerror: failed to push some refs to 'https://github.com/mockuser/atlas-api.git'\nhint: Updates were rejected because the remote contains work that you do not\nhint: have locally. Integrate the remote changes (e.g.\nhint: 'git pull ...') before pushing again.\n`, 12];
  }
  git.unpushed = 0; git.upstream = true;
  return [`branch '${branch}' set up to track 'origin/${branch}'.\n`, 0];
}
const root = mkdtempSync(join(tmpdir(), "ravix-preview-mock-"));
const vite = new URL("../node_modules/vite/bin/vite.js", import.meta.url).pathname;
function render(service: Service) {
  const label = service.dir.replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  writeFileSync(join(service.root, "index.html"), `<!doctype html><html><head><meta charset="utf-8"><title>Track preview</title><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="font:20px system-ui;padding:32px;background:#f4f1e9;color:#252c28"><h1>Live track · version ${service.version}</h1><p>${label}</p><p>A saved correction updates this app, even after closing Ravix.</p><script type="module" src="/main.js"></script></body></html>`);
}
// Sprites put to sleep by the browser harness (`/__browser/sandbox-status`),
// each with what waking it does to the Fountain sandbox it runs. A passive
// status read reports it stopped; an exec wakes it, as a real sprite does.
// `wakeMs` is how long the exec that wakes one takes to answer, for a
// harness that wants to see a machine waking rather than already awake.
const asleep = new Map<string, () => void>();
const wakeDelay = new Map<string, number>();
export function setMockSpriteAsleep(sprite: string, wake: (() => void) | null, wakeMs = 0) {
  if (wake) asleep.set(sprite, wake); else asleep.delete(sprite);
  if (wake && wakeMs > 0) wakeDelay.set(sprite, wakeMs); else wakeDelay.delete(sprite);
}
// Sprites whose exec WebSocket accepts the connection and never answers the
// upgrade, as a machine that is slow to come up does: the browser harness
// sets this (`/__browser/pty-silent`) to show a terminal the machine did not
// answer. An asleep sprite's socket does the same until an exec wakes it.
const silent = new Set<string>();
export function setMockPtySilent(sprite: string, on: boolean) {
  if (on) silent.add(sprite); else silent.delete(sprite);
}
export function updateMockPreview(workdir: string) {
  for (const service of services.values()) if (service.dir === workdir || service.dir.startsWith(`${workdir}/`)) { service.version++; render(service); }
}
async function stop(service: Service) {
  service.status = "stopped";
  const process = service.process; service.process = undefined;
  process?.kill(); if (process) await process.exited;
}
// A host port nothing holds right now, for one service's process.
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as { port: number };
      probe.close(() => resolve(port));
    });
  });
}
async function start(service: Service) {
  if (service.process && service.process.exitCode === null) return;
  service.status = "running";
  service.hostPort = await freePort();
  const process = Bun.spawn(["node", vite, service.root, "--host", "127.0.0.1", "--port", String(service.hostPort), "--strictPort"], { stdout: "pipe", stderr: "pipe" });
  service.process = process;
  for (const output of [process.stdout, process.stderr]) void (async () => {
    for await (const chunk of output as ReadableStream<Uint8Array>) service.logs = (service.logs + new TextDecoder().decode(chunk)).slice(-32_000);
  })();
  void process.exited.then(() => { if (service.process === process) { service.process = undefined; service.status = "stopped"; } });
}
// ── the interactive terminal (RAV-54) ──────────────────────────────────
// Sprites' exec WebSocket in TTY mode, stood in for by a small shell: it echoes
// what is typed, answers a few commands with fixed output, runs a pretend
// `iex -S mix`, and keeps each session's output so that a re-attach replays it
// the way Sprites does. Sessions are detachable: closing the socket leaves one
// running until `POST .../exec/:id/kill` or `exit`.
interface PtySession { id: string; dir: string; output: string; alive: boolean; ws?: ServerWebSocket<SocketData>; line: string; repl: number | null; cols: number; rows: number; ps1: boolean; }
type SocketData = { tcp?: Socket; pty?: string; attach?: boolean; sprite?: string };
const ptys = new Map<string, PtySession>();
let nextPty = 1;
const ESC = "\x1b[";
function prompt(session: PtySession) {
  if (session.repl !== null) return `iex(${session.repl})> `;
  // A shell started with Ravix's own prompt (`PS1='\W $ '`) names only its
  // directory; anything else gets the machine's user@host, as bash would.
  if (session.ps1) return `${session.dir.split("/").at(-1) || "/"} $ `;
  const where = session.dir.replace(/^\/home\/sprite/, "~");
  return `${ESC}32msprite@ravix${ESC}0m:${ESC}34m${where}${ESC}0m$ `;
}
function ptyWrite(session: PtySession, text: string) {
  session.output += text;
  session.ws?.send(new TextEncoder().encode(text));
}
function ptyEnd(session: PtySession, code: number) {
  session.alive = false;
  session.ws?.send(JSON.stringify({ type: "exit", exit_code: code }));
  session.ws?.close(1000);
}
const COMMANDS: Record<string, string> = {
  "ls": `${ESC}34mconfig${ESC}0m  ${ESC}34mlib${ESC}0m  ${ESC}34mpriv${ESC}0m  ${ESC}34mtest${ESC}0m  mix.exs  mix.lock  README.md`,
  "git status": `On branch ravix/track\r\nYour branch is up to date with 'origin/main'.\r\n\r\nnothing to commit, working tree clean`,
  "pwd": "",
  "mix test": `Running ExUnit with seed: 42, max_cases: 16\r\n\r\n${ESC}32m.........................................${ESC}0m\r\nFinished in 0.4 seconds (0.3s async, 0.1s sync)\r\n${ESC}32m41 tests, 0 failures${ESC}0m`,
};
function ptyRun(session: PtySession, line: string) {
  const command = line.trim();
  if (session.repl !== null) {
    if (command === "") return ptyWrite(session, `\r\n${prompt(session)}`);
    const sum = /^(\d+)\s*\+\s*(\d+)$/.exec(command);
    const answer = sum ? `${ESC}33m${Number(sum[1]) + Number(sum[2])}${ESC}0m` : command === "Ravix.Repo.aggregate(Ravix.Tracks.Track, :count)" ? `${ESC}33m3${ESC}0m` : `${ESC}31m** (CompileError) undefined function ${command}${ESC}0m`;
    session.repl++;
    return ptyWrite(session, `\r\n${answer}\r\n${prompt(session)}`);
  }
  if (command === "exit") { ptyWrite(session, "\r\nlogout\r\n"); return ptyEnd(session, 0); }
  if (command === "iex -S mix") {
    session.repl = 1;
    return ptyWrite(session, `\r\nErlang/OTP 28 [erts-16.4] [source] [64-bit] [smp:2:2] [ds:2:2:10] [async-threads:1] [jit]\r\n\r\nInteractive Elixir (1.19.5) - press Ctrl+C to exit (type h() ENTER for help)\r\n${prompt(session)}`);
  }
  const out = command === "pwd" ? session.dir : command === "stty size" ? `${session.rows} ${session.cols}` : command === "" ? null : COMMANDS[command] ?? `${command.split(" ")[0]}: ran on the mock machine`;
  ptyWrite(session, `\r\n${out === null ? "" : out + "\r\n"}${prompt(session)}`);
}
function ptyInput(session: PtySession, bytes: string) {
  for (const ch of bytes) {
    if (ch === "\r") { const line = session.line; session.line = ""; ptyRun(session, line); }
    else if (ch === "\x7f") { if (session.line) { session.line = session.line.slice(0, -1); ptyWrite(session, "\b \b"); } }
    else if (ch === "\x03") { session.line = ""; if (session.repl !== null) session.repl = null; ptyWrite(session, `^C\r\n${prompt(session)}`); }
    else if (ch >= " ") { session.line += ch; ptyWrite(session, ch); }
  }
}

const server = Bun.serve<SocketData>({ port: Number(process.env.MOCK_SPRITES_PORT || 8794), hostname: "127.0.0.1", idleTimeout: 0,
  async fetch(req, server) {
    if (req.headers.get("authorization") !== "Bearer sprites_mock") return new Response("unauthorized", { status: 401 });
    const url = new URL(req.url);
    const exec = /^\/v1\/sprites\/([^/]+)\/exec(?:\/([^/]+))?(\/kill)?$/.exec(url.pathname)?.slice(1);
    if (exec && req.headers.get("upgrade")?.toLowerCase() === "websocket" && (silent.has(exec[0]!) || asleep.has(exec[0]!)))
      return new Promise<Response>(() => {});
    if (exec && req.headers.get("upgrade")?.toLowerCase() === "websocket") {
      if (exec[1]) {
        const session = ptys.get(exec[1]);
        if (!session?.alive) return new Response("no such session", { status: 404 });
        return server.upgrade(req, { data: { pty: session.id, attach: true } }) ? undefined : new Response("upgrade", { status: 400 });
      }
      const id = `pty-${nextPty++}`;
      ptys.set(id, { id, dir: url.searchParams.get("dir") || "/home/sprite", output: "", alive: true, line: "", repl: null,
        cols: Number(url.searchParams.get("cols")) || 80, rows: Number(url.searchParams.get("rows")) || 24,
        ps1: url.searchParams.getAll("cmd").some(arg => arg.includes("PS1=")) });
      return server.upgrade(req, { data: { pty: id } }) ? undefined : new Response("upgrade", { status: 400 });
    }
    if (exec?.[2] && req.method === "POST") {
      const session = ptys.get(exec[1]!);
      if (!session?.alive) return new Response("no such session", { status: 404 });
      ptyEnd(session, 129);
      return new Response(`{"type":"complete"}\n`);
    }
    // Passive status reads must not execute a command or start a service.
    if (req.method === "GET" && /^\/v1\/sprites\/ravix-[a-z0-9]+$/.test(url.pathname))
      return Response.json({ status: asleep.has(url.pathname.split("/").at(-1)!) ? "warm" : "running" });
    const match = /^\/v1\/sprites\/([^/]+)\/(proxy|exec|services)(?:\/([^/]+))?(?:\/(start|stop))?$/.exec(url.pathname);
    if (!match) return new Response("missing", { status: 404 });
    if (match[2] === "proxy") return server.upgrade(req, { data: { sprite: match[1] } }) ? undefined : new Response("upgrade", { status: 400 });
    if (match[2] === "exec") {
      const wake = asleep.get(match[1]!);
      if (wake) {
        const ms = wakeDelay.get(match[1]!) ?? 0;
        wakeDelay.delete(match[1]!);
        if (ms) await Bun.sleep(ms);
        asleep.delete(match[1]!); wake();
      }
      const argv = url.searchParams.getAll("cmd");
      const script = argv[0] === "sh" ? argv.at(-1) ?? "" : "";
      if (/__ravix_git__|git push -u origin HEAD/.test(script)) {
        const [out, code] = gitExec(match[1]!, script);
        return new Response(Buffer.concat([Buffer.from([1]), Buffer.from(out), Buffer.from([3, code])]));
      }
      // The Changes tab's untracked-files read (`Diff.untracked_command/1`),
      // told from the Files tab's metadata read by its five-value payload.
      // Only a worktree named for it has one, so every other track's Changes
      // stays what the Fountain mock's diff says.
      const payload = /base64\.b64decode\("[^"]+"\)\)' (\S+)/.exec(script)?.[1];
      const read = payload ? JSON.parse(atob(payload)) : null;
      if (read?.length === 5 && /untracked/.test(read[0])) {
        const diff = "diff --git a/docs/NOTES.md b/docs/NOTES.md\nnew file mode 100644\n--- /dev/null\n+++ b/docs/NOTES.md\n@@ -0,0 +1,3 @@\n+# Notes\n+\n+Untracked, and now listed.\n";
        const out = JSON.stringify({ available: true, diff, large: [], truncated: false });
        return new Response(Buffer.concat([Buffer.from([1]), Buffer.from(out), Buffer.from([3, 0])]));
      }
      const logs = argv[0] === "tail" ? [...services.values()].find(s => argv.at(-1)?.includes(s.name))?.logs || "" : "";
      const stats = argv[0] === "sh" && argv.at(-1)?.includes("/sys/fs/cgroup/cpu.stat");
      const output = stats ? [
        "t0=10", "t1=11", "cg0=0", "cg1=300000", "nproc=2", "cpumax=200000 100000",
        "memcur=1108246528", "memmax=8589934592", "df=20971520 3344148 /",
      ].join("\n") : logs;
      return new Response(Buffer.concat([Buffer.from([1]), Buffer.from(output), Buffer.from([3, 0])]));
    }
    const key = `${match[1]}/${match[3]}`;
    let service = services.get(key);
    if (req.method === "PUT") {
      const body = await req.json() as { dir: string; env: { PORT: string } } & Record<string, unknown>;
      if (service) {
        await stop(service);
        // A redefinition is the new definition, as on Sprites.
        Object.assign(service, { dir: body.dir, port: Number(body.env.PORT), definition: body });
      } else {
        const appRoot = mkdtempSync(join(root, "app-"));
        service = { name: match[3]!, sprite: match[1]!, dir: body.dir, root: appRoot, port: Number(body.env.PORT), hostPort: 0, definition: body, status: "stopped", logs: "", version: 1 };
        writeFileSync(join(appRoot, "main.js"), "if(import.meta.hot)import.meta.hot.accept();");
        writeFileSync(join(appRoot, "vite.config.mjs"), 'export default {server:{allowedHosts:[".preview.localhost"]}}');
        render(service); services.set(key, service);
      }
      await start(service); return Response.json({ type: "started" });
    }
    if (!service) return new Response("missing", { status: 404 });
    if (req.method === "DELETE") { await stop(service); services.delete(key); rmSync(service.root, { recursive: true, force: true }); return new Response(null, { status: 204 }); }
    if (match[4] === "stop") await stop(service);
    if (match[4] === "start") await start(service);
    // The definition back with the state, as Sprites answers: without it Ravix
    // could never see a running service as already defined, so every ensure
    // (the reconciler's, every fifteen seconds, while somebody looked)
    // deleted and redefined it -- a Vite restart for nothing.
    return Response.json({ ...service.definition, name: service.name, state: { status: service.status, restart_count: 0 } });
  },
  websocket: {
    open(ws) {
      const session = ws.data.pty ? ptys.get(ws.data.pty) : undefined;
      if (!session) return;
      session.ws?.close(1000);
      session.ws = ws;
      ws.send(JSON.stringify({ type: "session_info", session_id: session.id, tty: true }));
      if (ws.data.attach) ws.send(new TextEncoder().encode(session.output));
      else ptyWrite(session, prompt(session));
    },
    message(ws, message) {
      if (ws.data.pty) {
        const session = ptys.get(ws.data.pty);
        // Text frames are control messages (resize); binary frames are typing.
        if (!session?.alive) return;
        if (typeof message !== "string") return ptyInput(session, new TextDecoder().decode(message));
        try {
          const control = JSON.parse(message);
          if (control.type === "resize") { session.cols = control.cols; session.rows = control.rows; }
        } catch { /* not a control message */ }
        return;
      }
      if (!ws.data.tcp) {
        try {
          const init = JSON.parse(String(message));
          // This sprite's service on that port, and nobody else's.
          const target = [...services.values()].find(s => s.sprite === ws.data.sprite && s.port === init.port && s.status === "running");
          if (init.host !== "127.0.0.1" || !target) { ws.close(); return; }
          const tcp = connect(target.hostPort, "127.0.0.1", () => ws.send(JSON.stringify({ status: "connected" })));
          ws.data.tcp = tcp;
          tcp.on("data", chunk => { if (ws.send(chunk) === -1) tcp.pause(); });
          tcp.on("error", () => ws.close()); tcp.on("close", () => ws.close());
        } catch { ws.close(); }
      } else { ws.data.tcp.write(message); if (ws.data.tcp.writableLength > 2 * 1024 * 1024) ws.close(); }
    },
    drain(ws) { ws.data.tcp?.resume(); },
    close(ws) {
      ws.data.tcp?.destroy();
      const session = ws.data.pty ? ptys.get(ws.data.pty) : undefined;
      if (session?.ws === ws) session.ws = undefined;
    },
  },
});
process.on("exit", () => { for (const s of services.values()) s.process?.kill(); server.stop(true); rmSync(root, { recursive: true, force: true }); });
console.log(`mock Sprites services and private tunnel on http://localhost:${server.port}`);
