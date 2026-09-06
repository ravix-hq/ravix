import { arch, platform, userInfo } from "node:os";
import { appendFile, lstat, mkdir, open, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { join, basename } from "node:path";
import { createServer } from "node:net";
import { AndroidExperiment } from "./adapters/experiment";
import { command, type Command } from "./process";
import { toolPaths, toolEnvironment } from "./doctor";
import { acquireExperiment, privateDirectory, writePrivateJson } from "./state";
import { digestBytes } from "./snapshot";

const APPLICATION_ID = "com.managoat.switchyard.hello";
export interface RuntimeConfig { expectedAccount: string; buildDirectory: string; artifactSha256: string }
export function parseRuntimeConfig(value: unknown): RuntimeConfig {
  const v = value as RuntimeConfig | null;
  if (!v || typeof v !== "object" || typeof v.expectedAccount !== "string" || !/^[a-z][a-z0-9_-]{0,31}$/.test(v.expectedAccount)) throw new Error("Select the dedicated runner account");
  if (typeof v.buildDirectory !== "string" || !new RegExp(`^/Users/${v.expectedAccount}/\\.local/share/switchyard/builds/experiment-[a-f0-9-]{36}$`).test(v.buildDirectory)) throw new Error("Choose an explicit build in the dedicated account");
  if (typeof v.artifactSha256 !== "string" || !/^[a-f0-9]{64}$/.test(v.artifactSha256)) throw new Error("Pin the verified APK SHA-256");
  return { expectedAccount: v.expectedAccount, buildDirectory: v.buildDirectory, artifactSha256: v.artifactSha256 };
}

/** Only consumes private build evidence. Never chooses the most recent build. */
export async function verifyRuntimeBuild(config: RuntimeConfig) {
  await privateDirectory(config.buildDirectory);
  const boundedFile = async (path: string, max: number) => {
    const stat = await lstat(path);
    if (!stat.isFile() || stat.size > max || await realpath(path) !== path) throw new Error(`Invalid build file: ${basename(path)}`);
    return readFile(path);
  };
  const report = JSON.parse((await boundedFile(join(config.buildDirectory, "report.json"), 1024 * 1024)).toString());
  const apk = join(config.buildDirectory, "app-debug.apk");
  if (report.kind !== "android-build-experiment" || report.account !== config.expectedAccount || report.applicationId !== APPLICATION_ID || report.architecture !== "arm64-v8a" || report.error !== null || report.artifact?.path !== apk || report.artifact?.sha256 !== config.artifactSha256 || !report.phases?.some((p: { name: string; passed: boolean }) => p.name === "verify-artifact" && p.passed === true)) throw new Error("Build report does not identify a successful matching Hello APK");
  const bytes = await boundedFile(apk, 512 * 1024 * 1024);
  if (bytes.length !== report.artifact.size || digestBytes(bytes) !== config.artifactSha256) throw new Error("APK does not match the pinned build digest");
  const worktree = join(config.buildDirectory, "worktree");
  if (await realpath(worktree) !== worktree) throw new Error("Build worktree must not use links");
  const source = (await boundedFile(join(worktree, "App.tsx"), 1024 * 1024)).toString();
  if (source.split("const GREETING = 'Hello';").length !== 2) throw new Error("Hello source changed; inspect the staged worktree before running");
  return { apk, worktree, source, sourceDigest: String(report.sourceDigest) };
}

// Parse only the small subset emitted by uiautomator; no XML entities are
// expanded. The caller matches a whole attribute, never a substring of a node.
export function androidNode(xml: string, attribute: "resource-id" | "text" | "content-desc", value: string, packageName?: string) {
  const escaped = value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  const nodes = xml.match(/<node\b[^>]*>/g) ?? [];
  for (const node of nodes) {
    if (packageName && !node.includes(` package="${packageName}"`)) continue;
    if (!node.includes(` ${attribute}="${escaped}"`)) continue;
    const bounds = node.match(/ bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if (!bounds) continue;
    const [left, top, right, bottom] = bounds.slice(1).map(Number) as [number, number, number, number];
    if (right > left && bottom > top && right <= 16384 && bottom <= 16384) return { x: Math.round((left + right) / 2), y: Math.round((top + bottom) / 2) };
  }
  return null;
}

/** SDK 54 onboarding's Continue opens the menu; Close reveals the app.
 * Require the fixture's Expo header and known overlay content, so ordinary
 * app buttons or another package's dialogs cannot trigger these startup taps. */
export function expoStartupAction(xml: string) {
  const text = (value: string) => androidNode(xml, "text", value, APPLICATION_ID);
  if (!text("Switchyard Hello") || !text("Runtime version: exposdk:54.0.0")) return null;
  if (text("This is the developer menu. It gives you access to useful tools in your development builds.")) {
    const point = text("Continue");
    return point ? { action: "continue-onboarding" as const, ...point } : null;
  }
  if (!text("Connected to:") || !text("Reload") || !text("Go home")) return null;
  const point = androidNode(xml, "content-desc", "Close", APPLICATION_ID);
  return point ? { action: "close-developer-menu" as const, ...point } : null;
}

async function freePort() {
  const server = createServer();
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("No local Metro port");
  await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return address.port;
}

/** Local runtime preflight, not Sprite forwarding or a browser session. */
export async function runtimeExperiment(config: RuntimeConfig, signal?: AbortSignal, invoke: Command = command) {
  const user = userInfo();
  if (platform() !== "darwin" || arch() !== "arm64" || user.uid === 0 || user.username !== config.expectedAccount) throw new Error(`Run as the dedicated ${config.expectedAccount} Apple Silicon account`);
  const build = await verifyRuntimeBuild(config);
  // Protect the temporary edit even against a second run using another state root.
  const buildLockPath = join(config.buildDirectory, "runtime.lock");
  const buildLock = await open(buildLockPath, "wx", 0o600).catch(() => { throw new Error("This build has a runtime lock; inspect its evidence before recovery"); });
  let owned: Awaited<ReturnType<typeof acquireExperiment>>;
  try { owned = await acquireExperiment(join(user.homedir, ".local/share/switchyard/runtime")); }
  catch (error) { await buildLock.close(); await rm(buildLockPath); throw error; }
  await buildLock.writeFile(JSON.stringify({ directory: owned.directory, pid: process.pid })); await buildLock.close();
  const controller = new AbortController();
  const active = AbortSignal.any([controller.signal, AbortSignal.timeout(15 * 60_000), ...(signal ? [signal] : [])]);
  const env = { ...toolEnvironment(await toolPaths({ HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` }), {
    HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: "en_US.UTF-8",
  }), EXPO_NO_TELEMETRY: "1", EXPO_OFFLINE: "1", EXPO_NO_DOTENV: "1", TMPDIR: join(owned.directory, "tmp") };
  const paths = await toolPaths(env);
  const report = {
    version: 1, kind: "android-local-runtime-experiment", account: user.username, startedAt: new Date().toISOString(), buildDirectory: config.buildDirectory,
    artifactSha256: config.artifactSha256, sourceDigest: build.sourceDigest, runtimeAppDigest: "",
    phases: [] as { name: string; elapsedMs: number; passed: boolean; error?: string }[],
    startupActions: [] as { action: string; x: number; y: number }[],
    nativeRuntimeVerified: false, localMetroVerified: false, localBackendVerified: false, fastRefreshVerified: false,
    spriteMetroVerified: false, browserVerified: false, sourceRestored: false, cleanup: "not-run", error: null as string | null,
  };
  const save = () => writePrivateJson(join(owned.directory, "report.json"), report);
  const run: Command = async (argv, options) => {
    const started = Date.now();
    try {
      const result = await invoke(argv, { env, ...options });
      await appendFile(join(owned.directory, "commands.jsonl"), JSON.stringify({ argv, elapsedMs: Date.now() - started, code: result.code,
        stdout: argv.includes("screencap") ? "[PNG]" : result.stdout.toString().slice(-8000), stderr: result.stderr.toString().slice(-8000) }) + "\n", { mode: 0o600 });
      return result;
    } catch (error) {
      await appendFile(join(owned.directory, "commands.jsonl"), JSON.stringify({ argv, elapsedMs: Date.now() - started, error: String(error) }) + "\n", { mode: 0o600 });
      throw error;
    }
  };
  const adapter = new AndroidExperiment({ platform: "android", stateDirectory: owned.directory, emulatorPort: 5580, deviceType: "pixel_7", systemImage: "system-images;android-35;google_apis;arm64-v8a", scrcpyVersion: "4.1" }, owned.id, owned.directory, paths, run, active, env, 15 * 60_000);
  const phase = async (name: string, action: () => Promise<void>, cleanup = false) => {
    if (!cleanup) active.throwIfAborted();
    console.log(`Runtime: ${name}`); const start = Date.now();
    try { await action(); report.phases.push({ name, elapsedMs: Date.now() - start, passed: true }); }
    catch (error) { report.phases.push({ name, elapsedMs: Date.now() - start, passed: false, error: String(error) }); throw error; }
    finally { await save(); }
  };
  let metro: Promise<never> | undefined;
  let backend: ReturnType<typeof Bun.serve> | undefined;
  let edited = false;
  // RN groups an accessible button's children. Include the counter in the
  // fixture's label so UI hierarchy assertions can observe the rendered state.
  const runtimeSource = build.source.replace('accessibilityLabel="Increment counter"', 'accessibilityLabel={`Increment counter. Tap count: ${count}`}');
  const changedSource = runtimeSource.replace("const GREETING = 'Hello';", "const GREETING = 'Hello refreshed';");
  let backendRequests = 0;
  const backendMessage = `Local runner response ${owned.id.slice(0, 8)}`;
  const waitForNode = async (name: string, attribute: "resource-id" | "text" | "content-desc", value: string, timeoutMs = 60_000, allowStartupActions = false) => {
    const end = Date.now() + timeoutMs;
    let lastError = "";
    while (Date.now() < end) {
      active.throwIfAborted();
      try {
        const xml = await adapter.readHierarchy();
        lastError = "";
        await writeFile(join(owned.directory, `${name}.xml`), xml, { mode: 0o600 });
        const node = androidNode(xml, attribute, value, APPLICATION_ID);
        if (node) return node;
        const next = allowStartupActions ? expoStartupAction(xml) : null;
        if (next && report.startupActions.length < 3) {
          const evidence = `startup-${report.startupActions.length + 1}`;
          await writeFile(join(owned.directory, `${evidence}.xml`), xml, { mode: 0o600 });
          await adapter.screenshot(join(owned.directory, `${evidence}.png`));
          await adapter.tap(next.x, next.y);
          report.startupActions.push(next); await save();
        }
      } catch (error) { lastError = String(error); }
      await Promise.race([Bun.sleep(1000), ...(metro ? [metro] : [])]);
    }
    throw new Error(`App did not show ${name}: ${value}. ${lastError}`);
  };
  const tap = async (name: string, attribute: "resource-id" | "text" | "content-desc", value: string) => {
    const node = await waitForNode(name, attribute, value); await adapter.tap(node.x, node.y);
  };
  try {
    await save(); await mkdir(env.TMPDIR, { mode: 0o700 });
    await writeFile(join(owned.directory, "App.original.tsx"), build.source, { mode: 0o600 });
    await phase("prepare-observable-fixture", async () => {
      if (runtimeSource === build.source) throw new Error("Fixture counter label changed; review the runtime fixture");
      if (await readFile(join(build.worktree, "App.tsx"), "utf8") !== build.source) throw new Error("Staged source changed before runtime preparation");
      edited = true;
      await writeFile(join(build.worktree, "App.tsx"), runtimeSource);
      report.runtimeAppDigest = digestBytes(Buffer.from(runtimeSource));
    });
    let metroPort = 0;
    await phase("start-local-services", async () => {
      backend = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
        if (request.method !== "GET" || new URL(request.url).pathname !== "/hello") return new Response("Not found", { status: 404 });
        backendRequests++; return Response.json({ message: backendMessage });
      } });
      metroPort = await freePort();
      // CI must remain unset: SDK 54 disables Metro watching in CI mode.
      // With piped stdio Expo refuses interactive fallback to another port.
      metro = run(["node", "--require", join(import.meta.dir, "scripts/metro-loopback.cjs"), join(build.worktree, "node_modules/expo/bin/cli"), "start", "--dev-client", "--localhost", "--port", String(metroPort)], {
        cwd: build.worktree, env: { ...env, EXPO_PUBLIC_API_URL: `http://127.0.0.1:${backend.port}`, EXPO_PACKAGER_PROXY_URL: `http://127.0.0.1:${metroPort}` },
        signal: active, timeoutMs: 15 * 60_000, maxBytes: 8 * 1024 * 1024,
      }).then(result => { throw new Error(`Metro exited (${result.code}): ${result.stderr.toString().slice(-2000)}`); });
      void metro.catch(() => {});
      const end = Date.now() + 90_000;
      while (true) {
        active.throwIfAborted();
        try {
          const response = await fetch(`http://127.0.0.1:${metroPort}/status`, { signal: AbortSignal.any([active, AbortSignal.timeout(2000)]) });
          if (await response.text() === "packager-status:running") break;
        } catch { /* Retry bounded startup only. */ }
        if (Date.now() > end) throw new Error("Metro did not become ready");
        await Promise.race([Bun.sleep(500), metro]);
      }
    });
    await phase("boot-owned-emulator", () => adapter.boot());
    await phase("install-apk", () => adapter.installHello(build.apk));
    await phase("forward-local-services", async () => {
      await adapter.forward(metroPort); await adapter.forward(backend!.port!);
    });
    await phase("launch-app", () => adapter.launchHello(metroPort));
    await phase("wait-for-greeting", async () => {
      await waitForNode("greeting", "text", "Hello, world!", 180_000, true);
      await adapter.screenshot(join(owned.directory, "before.png"));
      report.nativeRuntimeVerified = true; report.localMetroVerified = true;
    });
    await phase("tap-and-text", async () => {
      await tap("increment", "content-desc", "Increment counter. Tap count: 0");
      await waitForNode("counter", "content-desc", "Increment counter. Tap count: 1");
      await tap("name", "content-desc", "Your name"); await adapter.appendHelloName();
      await waitForNode("typed-name", "text", "Hello, worldrunner!");
      await adapter.screenshot(join(owned.directory, "input.png"));
    });
    await phase("local-backend", async () => {
      await tap("call-backend", "content-desc", "Call backend");
      await waitForNode("backend-response", "text", backendMessage);
      if (!backendRequests) throw new Error("No request reached the owned backend");
      report.localBackendVerified = true;
    });
    await phase("fast-refresh", async () => {
      if (await readFile(join(build.worktree, "App.tsx"), "utf8") !== runtimeSource) throw new Error("Staged source changed during runtime check");
      edited = true; await writeFile(join(build.worktree, "App.tsx"), changedSource);
      // No launch, reload or key event here: observe HMR with React state intact.
      await waitForNode("refreshed-greeting", "text", "Hello refreshed, worldrunner!");
      await waitForNode("preserved-counter", "content-desc", "Increment counter. Tap count: 1");
      report.fastRefreshVerified = true;
      await adapter.screenshot(join(owned.directory, "refreshed.png"));
    });
    await phase("capture-and-scroll", async () => {
      const outcomes = await Promise.allSettled([
        adapter.record(join(owned.directory, "capture.mp4")),
        (async () => {
          await Bun.sleep(1500);
          for (let i = 0; i < 6; i++) {
            await adapter.scrollHello(); await Bun.sleep(500);
            const xml = await adapter.readHierarchy();
            if (androidNode(xml, "text", "You reached the end.", APPLICATION_ID)) {
              await writeFile(join(owned.directory, "scroll-end.xml"), xml, { mode: 0o600 });
              await adapter.screenshot(join(owned.directory, "scroll.png")); return;
            }
          }
          throw new Error("Scroll did not reach the fixture's end");
        })(),
      ]);
      for (const result of outcomes) if (result.status === "rejected") throw result.reason;
      const video = await lstat(join(owned.directory, "capture.mp4"));
      if (!video.isFile() || video.size < 100 || video.size > 64 * 1024 * 1024) throw new Error("Capture outside experiment size limits");
    });
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    await adapter.screenshot(join(owned.directory, "failure.png")).catch(() => {});
  } finally {
    controller.abort(); await metro?.catch(() => {}); await backend?.stop(true);
    const failures: string[] = [];
    try {
      await phase("restore-source", async () => {
        if (edited) {
          const current = await readFile(join(build.worktree, "App.tsx"), "utf8");
          if (current !== changedSource && current !== runtimeSource && current !== build.source) throw new Error("Source changed externally; original retained as App.original.tsx; manual recovery required");
          await writeFile(join(build.worktree, "App.tsx"), build.source);
        }
        report.sourceRestored = true;
      }, true);
    } catch (error) { failures.push(String(error)); }
    try { await phase("stop-owned-emulator", () => adapter.stop(), true); }
    catch (error) { failures.push(String(error)); }
    report.cleanup = failures.length ? failures.join("\n") : "complete";
    if (failures.length) report.error ??= report.cleanup;
    await save();
    if (!failures.length) { await rm(buildLockPath); await owned.release(); }
  }
  return { directory: owned.directory, report };
}
