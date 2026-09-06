import { afterEach, expect, test } from "bun:test";
import { mkdtemp, realpath, rm, mkdir, writeFile, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseRuntimeConfig, verifyRuntimeBuild, androidNode, expoStartupAction } from "./runtime-experiment";
import { AndroidExperiment } from "./adapters/experiment";
import { digestBytes } from "./snapshot";
import { command } from "./process";

const cleanup: string[] = [];
afterEach(async () => { for (const path of cleanup.splice(0)) await rm(path, { recursive: true, force: true }); });
const sample = { expectedAccount: "switchyard", buildDirectory: "/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041", artifactSha256: "a".repeat(64) };

test("runtime config requires an explicit dedicated build and pinned artifact", () => {
  expect(parseRuntimeConfig(sample)).toEqual(sample);
  for (const patch of [{ expectedAccount: "root" }, { buildDirectory: "/Users/jake/app" }, { buildDirectory: sample.buildDirectory + "/../other" }, { artifactSha256: "latest" }, { artifactSha256: "a".repeat(63) }]) expect(() => parseRuntimeConfig({ ...sample, ...patch })).toThrow();
});

test("runtime refuses altered APKs, failed reports and linked build files", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "sy-runtime-"))); cleanup.push(root);
  const worktree = join(root, "worktree"); await mkdir(worktree);
  await writeFile(join(worktree, "App.tsx"), "const GREETING = 'Hello';\n");
  const bytes = Buffer.from("fixture apk"); const apk = join(root, "app-debug.apk");
  const config = { ...sample, buildDirectory: root, artifactSha256: digestBytes(bytes) };
  const report = { kind: "android-build-experiment", account: "switchyard", applicationId: "com.managoat.switchyard.hello", architecture: "arm64-v8a", error: null, sourceDigest: "b".repeat(64), phases: [{ name: "verify-artifact", passed: true }], artifact: { path: apk, sha256: config.artifactSha256, size: bytes.length } };
  await writeFile(apk, bytes); await writeFile(join(root, "report.json"), JSON.stringify(report));
  expect((await verifyRuntimeBuild(config)).source).toContain("'Hello'");
  await writeFile(apk, "tampered apk"); await expect(verifyRuntimeBuild(config)).rejects.toThrow("digest");
  await writeFile(apk, bytes);
  await writeFile(join(root, "report.json"), JSON.stringify({ ...report, error: "build failed" }));
  await expect(verifyRuntimeBuild(config)).rejects.toThrow("successful matching");
  await writeFile(join(root, "report.json"), JSON.stringify(report));
  await rm(apk); await symlink(join(worktree, "App.tsx"), apk);
  await expect(verifyRuntimeBuild(config)).rejects.toThrow("Invalid build file");
});

test("Android selectors match whole XML attributes and reject empty or invalid bounds", () => {
  const xml = '<node text="Other" content-desc="Your name" bounds="[10,20][110,80]"/><node text="Call backend" bounds="[0,0][0,0]"/>';
  expect(androidNode(xml, "content-desc", "Your name")).toEqual({ x: 60, y: 50 });
  expect(androidNode(xml, "text", "Your name")).toBeNull();
  expect(androidNode(xml, "content-desc", "Your")).toBeNull();
  expect(androidNode(xml, "text", "Call backend")).toBeNull();
  expect(androidNode('<node text="A &amp; B" bounds="[0,0][40,60]"/>', "text", "A & B")).toEqual({ x: 20, y: 30 });
  expect(androidNode('<node text="A" bounds="[0,0][99999,60]"/>', "text", "A")).toBeNull();
});

test("native app operations refuse input before device ownership is verified", async () => {
  const calls: string[][] = [];
  const adapter = new AndroidExperiment({ platform: "android", stateDirectory: "/unused", emulatorPort: 5580, systemImage: "system-images;android-35;google_apis;arm64-v8a", deviceType: "pixel_7", scrcpyVersion: "4.1" }, "test", "/unused", { sdk: null, adb: "adb", avdmanager: "avdmanager", emulator: "emulator", scrcpy: "scrcpy", idb: "idb", xcrun: "xcrun" }, async argv => { calls.push(argv); throw new Error("unexpected command"); });
  for (const operation of [() => adapter.installHello("/apk"), () => adapter.forward(8081), () => adapter.launchHello(8081), () => adapter.tap(10, 20), () => adapter.readHierarchy(), () => adapter.appendHelloName(), () => adapter.scrollHello()]) await expect(operation()).rejects.toThrow("ownership");
  expect(calls).toEqual([]);
});

test("Metro preload binds numeric and object listen forms only to loopback", async () => {
  const result = await command(["node", "--require", join(import.meta.dir, "scripts/metro-loopback.cjs"), "-e", `
    const net = require('node:net');
    Promise.all([0, {port: 0, host: '0.0.0.0'}].map(option => new Promise(resolve => {
      const server = net.createServer();
      server.listen(option, () => { const host = server.address().address; server.close(() => resolve(host)); });
    }))).then(hosts => console.log(JSON.stringify(hosts)));
  `]);
  expect(result.code).toBe(0);
  expect(JSON.parse(result.stdout.toString())).toEqual(["127.0.0.1", "127.0.0.1"]);
});

test("Hello install, forwards and deep link stay scoped to the newly created Android device", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "sy-runtime-adapter-"))); cleanup.push(root);
  const calls: string[][] = [];
  let name = "";
  const ok = (output = "") => ({ code: 0, stdout: Buffer.from(output), stderr: Buffer.alloc(0) });
  const adapter = new AndroidExperiment({ platform: "android", stateDirectory: root, emulatorPort: 5580, systemImage: "system-images;android-35;google_apis;arm64-v8a", deviceType: "pixel_7", scrcpyVersion: "4.1" }, "test-owned", root, { sdk: null, adb: "adb", avdmanager: "avdmanager", emulator: "emulator", scrcpy: "scrcpy", idb: "idb", xcrun: "xcrun" }, async (argv, options) => {
    calls.push(argv);
    if (argv[0] === "scrcpy") return ok("scrcpy 4.1\n");
    if (argv.includes("create")) name = argv[argv.indexOf("--name") + 1]!;
    if (argv[0] === "emulator") return new Promise((_, reject) => options!.signal!.addEventListener("abort", () => reject(new Error("cancelled")), { once: true }));
    if (argv.includes("name")) return ok(name + "\nOK");
    if (argv.includes("getprop")) return ok("1");
    return ok();
  }, undefined, { HOME: root, PATH: "/usr/bin" });
  try {
    await adapter.boot();
    await adapter.installHello("/private/build/app-debug.apk");
    await adapter.forward(19281); await adapter.launchHello(19281);
    await expect(adapter.forward(503)).rejects.toThrow("port");
    await expect(adapter.tap(-1, 2)).rejects.toThrow("coordinates");
    const deviceCalls = calls.filter(c => c[0] === "adb" && c[1] !== "devices");
    expect(deviceCalls.every(c => c[1] === "-s" && c[2] === "emulator-5580")).toBe(true);
    expect(deviceCalls.some(c => c.includes("--no-rebind") && c.at(-1) === "tcp:19281")).toBe(true);
    expect(deviceCalls.some(c => c.includes("switchyard-hello://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A19281") && c.at(-1) === "com.managoat.switchyard.hello")).toBe(true);
  } finally { await adapter.stop(); }
  expect(calls.some(c => c.includes("kill-server") || c.includes("--remove-all"))).toBe(false);
  expect(calls.at(-1)).toEqual(["avdmanager", "delete", "avd", "--name", name]);
});

test("Expo onboarding advances to the developer menu, which must close before the greeting", () => {
  const node = (text: string, bounds: string, description = "") => `<node text="${text}" content-desc="${description}" package="com.managoat.switchyard.hello" bounds="${bounds}" />`;
  // Header and onboarding bounds observed in the failed native run. The main
  // menu's header moves to the top when Continue expands it (SDK 54 AppInfo).
  const header = node("Switchyard Hello", "[221,1770][552,1821]") + node("Runtime version: exposdk:54.0.0", "[221,1832][750,1877]");
  const onboarding = header + node("This is the developer menu. It gives you access to useful tools in your development builds.", "[63,1960][1017,2070]") + node("", "[949,1803][991,1845]", "Close") + node("Continue", "[464,2229][617,2274]");
  const menu = header + node("Connected to:", "[105,400][700,450]") + node("Reload", "[180,625][340,675]") + node("Go home", "[650,625][850,675]") + node("", "[949,221][991,263]", "Close");
  const app = node("Hello, world!", "[63,150][850,270]");
  expect([onboarding, menu, app].map(expoStartupAction)).toEqual([
    { action: "continue-onboarding", x: 541, y: 2252 },
    { action: "close-developer-menu", x: 970, y: 242 },
    null,
  ]);
  expect(androidNode(app, "text", "Hello, world!", "com.managoat.switchyard.hello")).not.toBeNull();
  // Never infer a startup overlay from generic app controls, another package,
  // or header text without the known menu content.
  expect(expoStartupAction(node("Continue", "[0,0][80,80]") + node("", "[90,0][170,80]", "Close"))).toBeNull();
  expect(expoStartupAction(menu.replaceAll('package="com.managoat.switchyard.hello"', 'package="com.android.settings"'))).toBeNull();
  expect(expoStartupAction(header + node("", "[0,0][80,80]", "Close"))).toBeNull();
  expect(expoStartupAction(menu.replace('text="Runtime version: exposdk:54.0.0"', 'text="Runtime version: unknown"'))).toBeNull();
});
