/** Local Sprites fixture. The service API is simulated; each app is a real
 * Node/Vite process so browser exercises cover HTTP and actual HMR traffic. */
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, type Socket } from "node:net";
import type { Subprocess } from "bun";

interface Service { name: string; dir: string; root: string; port: number; status: string; logs: string; process?: Subprocess; version: number; }
const services = new Map<string, Service>();
// Ports on the "machine" that are not run-script services: what an agent
// starts by hand (`startMachineApp`). Listed by the port listing and allowed
// through the tunnel, so the Preview tab's port picker has something real.
const machinePorts = new Set((process.env.MOCK_MACHINE_PORTS || "").split(",").map(Number).filter(Boolean));
const machineApps = new Map<number, Subprocess>();
const root = mkdtempSync(join(tmpdir(), "ravix-preview-mock-"));
const vite = new URL("../node_modules/vite/bin/vite.js", import.meta.url).pathname;
function render(service: Service) {
  const label = service.dir.replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  writeFileSync(join(service.root, "index.html"), `<!doctype html><html><head><meta charset="utf-8"><title>Track preview</title><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="font:20px system-ui;padding:32px;background:#f4f1e9;color:#252c28"><h1>Live track · version ${service.version}</h1><p>${label}</p><p>A saved correction updates this app, even after closing Ravix.</p><script type="module" src="/main.js"></script></body></html>`);
}
/** An agent's own dev server on `port`, as a real Vite process. */
export function startMachineApp(port: number): boolean {
  if (!machinePorts.has(port) || machineApps.get(port)?.exitCode === null) return machinePorts.has(port);
  const appRoot = mkdtempSync(join(root, "machine-"));
  writeFileSync(join(appRoot, "vite.config.mjs"), 'export default {server:{allowedHosts:[".localhost"]}}');
  writeFileSync(join(appRoot, "index.html"), `<!doctype html><html><head><meta charset="utf-8"><title>Dev server</title><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="font:20px system-ui;padding:32px;background:#eef3f8;color:#1d2733"><h1>Agent's dev server · :${port}</h1><p>Started by the agent on the track's machine, outside the run script.</p><p><a href="/docs/">Docs</a></p></body></html>`);
  machineApps.set(port, Bun.spawn(["node", vite, appRoot, "--host", "127.0.0.1", "--port", String(port), "--strictPort"], { stdout: "ignore", stderr: "ignore" }));
  return true;
}
const listening = (port: number) => new Promise<boolean>(resolve => {
  const probe = connect(port, "127.0.0.1", () => { probe.destroy(); resolve(true); });
  probe.on("error", () => resolve(false));
});
export function updateMockPreview(workdir: string) {
  for (const service of services.values()) if (service.dir === workdir || service.dir.startsWith(`${workdir}/`)) { service.version++; render(service); }
}
async function stop(service: Service) {
  service.status = "stopped";
  const process = service.process; service.process = undefined;
  process?.kill(); if (process) await process.exited;
}
async function start(service: Service) {
  if (service.process && service.process.exitCode === null) return;
  service.status = "running";
  const process = Bun.spawn(["node", vite, service.root, "--host", "127.0.0.1", "--port", String(service.port), "--strictPort"], { stdout: "pipe", stderr: "pipe" });
  service.process = process;
  for (const output of [process.stdout, process.stderr]) void (async () => {
    for await (const chunk of output as ReadableStream<Uint8Array>) service.logs = (service.logs + new TextDecoder().decode(chunk)).slice(-32_000);
  })();
  void process.exited.then(() => { if (service.process === process) { service.process = undefined; service.status = "stopped"; } });
}
const server = Bun.serve<{ tcp?: Socket }>({ port: Number(process.env.MOCK_SPRITES_PORT || 8794), hostname: "127.0.0.1", idleTimeout: 0,
  async fetch(req, server) {
    if (req.headers.get("authorization") !== "Bearer sprites_mock") return new Response("unauthorized", { status: 401 });
    const url = new URL(req.url);
    // Passive status reads must not execute a command or start a service.
    if (req.method === "GET" && /^\/v1\/sprites\/ravix-[a-z0-9]+$/.test(url.pathname))
      return Response.json({ status: "running" });
    const match = /^\/v1\/sprites\/([^/]+)\/(proxy|exec|services)(?:\/([^/]+))?(?:\/(start|stop))?$/.exec(url.pathname);
    if (!match) return new Response("missing", { status: 404 });
    if (match[2] === "proxy") return server.upgrade(req, { data: {} }) ? undefined : new Response("upgrade", { status: 400 });
    if (match[2] === "exec") {
      const argv = url.searchParams.getAll("cmd");
      // `Ravix.Previews.Lifecycle.listening/1`: what `ss -H -ltn` would print.
      if (argv.at(-1)?.includes("ravix:listening")) {
        const ports = [...new Set([...services.values()].filter(s => s.status === "running").map(s => s.port).concat([...machinePorts]))];
        const open = (await Promise.all(ports.map(async port => (await listening(port)) ? port : null))).filter(Boolean);
        const output = open.map(port => `LISTEN 0      511        127.0.0.1:${port}      0.0.0.0:*`).join("\n");
        return new Response(Buffer.concat([Buffer.from([1]), Buffer.from(output), Buffer.from([3, 0])]));
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
      const body = await req.json() as { dir: string; env: { PORT: string } };
      if (service) await stop(service);
      else {
        const appRoot = mkdtempSync(join(root, "app-"));
        service = { name: match[3]!, dir: body.dir, root: appRoot, port: Number(body.env.PORT), status: "stopped", logs: "", version: 1 };
        writeFileSync(join(appRoot, "main.js"), "if(import.meta.hot)import.meta.hot.accept();");
        writeFileSync(join(appRoot, "vite.config.mjs"), 'export default {server:{allowedHosts:[".localhost"]}}');
        render(service); services.set(key, service);
      }
      await start(service); return Response.json({ type: "started" });
    }
    if (!service) return new Response("missing", { status: 404 });
    if (req.method === "DELETE") { await stop(service); services.delete(key); rmSync(service.root, { recursive: true, force: true }); return new Response(null, { status: 204 }); }
    if (match[4] === "stop") await stop(service);
    if (match[4] === "start") await start(service);
    return Response.json({ name: service.name, state: { status: service.status, restart_count: 0 } });
  },
  websocket: {
    message(ws, message) {
      if (!ws.data.tcp) {
        try {
          const init = JSON.parse(String(message));
          const known = machinePorts.has(init.port) || [...services.values()].some(s => s.port === init.port && s.status === "running");
          if (init.host !== "127.0.0.1" || !known) { ws.close(); return; }
          const tcp = connect(init.port, "127.0.0.1", () => ws.send(JSON.stringify({ status: "connected" })));
          ws.data.tcp = tcp;
          tcp.on("data", chunk => { if (ws.send(chunk) === -1) tcp.pause(); });
          tcp.on("error", () => ws.close()); tcp.on("close", () => ws.close());
        } catch { ws.close(); }
      } else { ws.data.tcp.write(message); if (ws.data.tcp.writableLength > 2 * 1024 * 1024) ws.close(); }
    },
    drain(ws) { ws.data.tcp?.resume(); },
    close(ws) { ws.data.tcp?.destroy(); },
  },
});
process.on("exit", () => { for (const s of services.values()) s.process?.kill(); for (const app of machineApps.values()) app.kill(); server.stop(true); rmSync(root, { recursive: true, force: true }); });
console.log(`mock Sprites services and private tunnel on http://localhost:${server.port}`);
