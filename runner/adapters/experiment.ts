import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendFile, chmod, lstat, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { checked, command, type Command, type CommandOptions } from "../process";
import { acquireExperiment, writePrivateJson } from "../state";
import { toolPaths, toolEnvironment, type ToolPaths } from "../doctor";
import { iosLive } from "../ios-live";
import { scrcpyLive } from "../scrcpy-live";

export type ExperimentConfig = {
  stateDirectory: string;
  platform: "android";
  systemImage: string;
  deviceType: string;
  /** Even console port reserved for this experiment. Never adopts its occupant. */
  emulatorPort: number;
  scrcpyVersion: string;
} | {
  stateDirectory: string;
  platform: "ios";
  runtime: string;
  deviceType: string;
};

export function parseExperimentConfig(value: unknown): ExperimentConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Expected experiment config object");
  const v = value as Record<string, unknown>;
  if (typeof v.stateDirectory !== "string" || !v.stateDirectory.startsWith("/") || /[\0\r\n]/.test(v.stateDirectory)) throw new Error("Choose an absolute private stateDirectory");
  if (typeof v.deviceType !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,149}$/.test(v.deviceType)) throw new Error("Choose an installed deviceType from doctor");
  if (v.platform === "android") {
    if (typeof v.systemImage !== "string" || !/^system-images;android-\d+;[a-zA-Z0-9_.-]+;(arm64-v8a|x86_64)$/.test(v.systemImage)) throw new Error("Choose an installed Android system image and ABI");
    if (typeof v.emulatorPort !== "number" || !Number.isInteger(v.emulatorPort) || v.emulatorPort < 5554 || v.emulatorPort > 5682 || v.emulatorPort % 2) throw new Error("emulatorPort must be an even port from 5554 to 5682");
    if (typeof v.scrcpyVersion !== "string" || !/^\d+\.\d+(?:\.\d+)?$/.test(v.scrcpyVersion)) throw new Error("Pin scrcpyVersion to the installed binary for this experiment");
    return { stateDirectory: v.stateDirectory, platform: v.platform, deviceType: v.deviceType, systemImage: v.systemImage, emulatorPort: v.emulatorPort, scrcpyVersion: v.scrcpyVersion };
  }
  if (v.platform === "ios") {
    if (typeof v.runtime !== "string" || !/^com\.apple\.CoreSimulator\.SimRuntime\.iOS-[\d-]+$/.test(v.runtime)) throw new Error("Choose an installed iOS runtime from doctor");
    if (!v.deviceType.startsWith("com.apple.CoreSimulator.SimDeviceType.")) throw new Error("Choose an iOS deviceType from doctor");
    return { stateDirectory: v.stateDirectory, platform: v.platform, deviceType: v.deviceType, runtime: v.runtime };
  }
  throw new Error("platform must be android or ios");
}

interface OwnedAdapter {
  boot(): Promise<void>;
  prepare(): Promise<void>;
  screenshot(path: string): Promise<void>;
  input(): Promise<void>;
  record(path: string): Promise<void>;
  stop(): Promise<void>;
}

/** Short-lived, isolated capture/input experiment. It deliberately does not
 * implement a production session or claim that an mp4 proves browser latency. */
export async function experiment(config: ExperimentConfig, signal?: AbortSignal, run: Command = command, paths?: ToolPaths) {
  const tools = paths ?? await toolPaths();
  const invoke = run;
  const owned = await acquireExperiment(config.stateDirectory);
  run = async (argv, options) => {
    const started = Date.now();
    try {
      const result = await invoke(argv, { env: toolEnvironment(tools), ...options });
      await appendFile(join(owned.directory, "commands.jsonl"), JSON.stringify({ argv, started, elapsedMs: Date.now() - started, code: result.code,
        stdout: argv.includes("screencap") ? "[PNG]" : result.stdout.toString().slice(-4000), stderr: result.stderr.toString().slice(-4000) }) + "\n", { mode: 0o600 });
      return result;
    } catch (error) {
      await appendFile(join(owned.directory, "commands.jsonl"), JSON.stringify({ argv, started, elapsedMs: Date.now() - started, error: String(error) }) + "\n", { mode: 0o600 });
      throw error;
    }
  };
  const manifestPath = join(owned.directory, "report.json");
  const report = { version: 1, platform: config.platform, config, startedAt: new Date().toISOString(),
    phases: [] as { name: string; elapsedMs: number; passed: boolean; error?: string }[],
    capture: "not-run", input: "not-run", cleanup: "not-run", browserVerified: false, expoVerified: false, error: null as string | null };
  const phase = async (name: string, work: () => Promise<void>) => {
    const start = Date.now();
    try { await work(); report.phases.push({ name, elapsedMs: Date.now() - start, passed: true }); }
    catch (error) { report.phases.push({ name, elapsedMs: Date.now() - start, passed: false, error: String(error) }); throw error; }
    finally { await writePrivateJson(manifestPath, report); }
  };
  const adapter = config.platform === "android"
    ? new AndroidExperiment(config, owned.id, owned.directory, tools, run, signal)
    : new IosExperiment(config, owned.id, owned.directory, tools, run, signal);
  try {
    await writePrivateJson(manifestPath, report);
    await phase("boot", () => adapter.boot());
    await phase("prepare-input-screen", () => adapter.prepare());
    await phase("screenshot-before", () => adapter.screenshot(join(owned.directory, "before.png")));
    await phase("capture-and-input", async () => {
      // Capture stays running while the independently bounded input path acts.
      const results = await Promise.allSettled([
        (async () => {
          report.capture = "recording";
          try {
            await adapter.record(join(owned.directory, "capture.mp4"));
            const file = await lstat(join(owned.directory, "capture.mp4"));
            if (!file.isFile() || file.size < 100 || file.size > 64 * 1024 * 1024) throw new Error("Capture empty or exceeded 64 MiB experiment limit");
            await chmod(join(owned.directory, "capture.mp4"), 0o600);
            report.capture = "recorded-needs-decoder-and-visual-review";
          } catch (error) { report.capture = "failed"; throw error; }
        })(),
        (async () => {
          report.input = "running";
          try {
            await Bun.sleep(1500); signal?.throwIfAborted(); await adapter.input();
            report.input = "commands-accepted-needs-visual-review";
          } catch (error) { report.input = "failed"; throw error; }
        })(),
      ]);
      for (const result of results) if (result.status === "rejected") throw result.reason;
    });
    await phase("screenshot-after", () => adapter.screenshot(join(owned.directory, "after.png")));
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
    if (report.phases.some(p => p.name === "screenshot-before" && p.passed)) {
      await phase("screenshot-failure", () => adapter.screenshot(join(owned.directory, "failure.png"))).catch(() => {});
    }
  }
  finally {
    try { await phase("cleanup", () => adapter.stop()); report.cleanup = "complete"; }
    catch (error) { report.cleanup = `failed: ${String(error)}`; report.error ??= report.cleanup; }
    await writePrivateJson(manifestPath, report);
    // Preserve the lock when cleanup is uncertain, so the next run cannot hide it.
    if (report.cleanup === "complete") await owned.release();
  }
  return { directory: owned.directory, report };
}

export class AndroidExperiment implements OwnedAdapter {
  private controller = new AbortController();
  private running: Promise<void> | undefined;
  private created = false;
  private verified = false;
  private readonly name: string;
  private readonly serial: string;
  private readonly env: NodeJS.ProcessEnv;
  constructor(private config: Extract<ExperimentConfig, { platform: "android" }>, id: string, private directory: string, private tools: ToolPaths, private run: Command, private signal?: AbortSignal, environment = process.env, private lifetimeMs = 300_000) {
    this.name = `switchyard-${id}`; this.serial = `emulator-${config.emulatorPort}`;
    this.env = { ...toolEnvironment(tools, environment), ANDROID_USER_HOME: join(directory, "android"), ANDROID_AVD_HOME: join(directory, "avds") };
  }
  private exec(argv: string[], options: CommandOptions = {}) { return checked(this.run, argv, { env: this.env, signal: AbortSignal.any([this.controller.signal, ...(this.signal ? [this.signal] : [])]), ...options }); }
  private adb(...args: string[]) { return this.exec([this.tools.adb, "-s", this.serial, ...args]); }
  private async hierarchy() {
    const path = `/sdcard/switchyard-${crypto.randomUUID()}.xml`;
    // uiautomator can exit zero while printing an error and leaving an older
    // file untouched. Require a fresh successful dump before consuming it.
    const output = (await this.adb("shell", "uiautomator", "dump", path)).toString();
    if (!output.includes(`dumped to: ${path}`)) throw new Error("Android UI hierarchy unavailable");
    return (await this.adb("shell", "cat", path)).toString();
  }
  async boot() {
    const version = (await this.exec([this.tools.scrcpy, "--version"])).toString();
    if (!new RegExp(`^scrcpy ${this.config.scrcpyVersion.replaceAll(".", "\\.")}(?:\\s|$)`).test(version)) throw new Error("scrcpy does not match the configured experiment version");
    // A serial occupied by any other process is unavailable; never attach to it.
    const devices = (await this.exec([this.tools.adb, "devices"])).toString();
    if (devices.split(/\r?\n/).some(line => line.startsWith(`${this.serial}\t`))) throw new Error("Selected emulator port is occupied");
    await mkdir(this.env.ANDROID_USER_HOME!, { mode: 0o700 });
    await mkdir(this.env.ANDROID_AVD_HOME!, { mode: 0o700 });
    await this.exec([this.tools.avdmanager, "create", "avd", "--name", this.name, "--path", join(this.directory, "avds", this.name), "--package", this.config.systemImage, "--device", this.config.deviceType], { timeoutMs: 60_000, input: "no\n" });
    this.created = true;
    // A foreground child with no window. Its process group is terminated on
    // cancellation; no `adb kill-server` or guessed serial kill is used.
    this.running = this.exec([this.tools.emulator, "-avd", this.name, "-port", String(this.config.emulatorPort), "-no-window", "-no-audio", "-no-snapshot", "-no-boot-anim", "-memory", "4096", "-cores", "4", "-gpu", "host", "-feature", "-Vulkan"],
      { signal: AbortSignal.any([this.controller.signal, ...(this.signal ? [this.signal] : [])]), timeoutMs: this.lifetimeMs, maxBytes: 4 * 1024 * 1024 }).then(() => { throw new Error("Emulator exited before the experiment completed"); });
    void this.running.catch(() => {});
    await Promise.race([this.exec([this.tools.adb, "-s", this.serial, "wait-for-device"], { timeoutMs: 120_000 }), this.running]);
    const identity = (await this.adb("emu", "avd", "name")).toString().split(/\r?\n/)[0];
    if (identity !== this.name) throw new Error("Emulator identity does not belong to this experiment");
    this.verified = true;
    const deadline = Date.now() + 120_000;
    while ((await this.adb("shell", "getprop", "sys.boot_completed")).toString().trim() !== "1") {
      this.signal?.throwIfAborted();
      if (Date.now() >= deadline) throw new Error("Android boot timed out");
      await Promise.race([Bun.sleep(1000), this.running]);
    }
  }
  async prepare() {
    this.assertOwned();
    await this.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP");
    await this.adb("shell", "wm", "dismiss-keyguard");
    // The first boot can launch Home after am start has already returned OK.
    // Wait for actual Settings content before admitting input/capture evidence.
    const deadline = Date.now() + 90_000;
    while (Date.now() < deadline) {
      await this.exec([this.tools.adb, "-s", this.serial, "shell", "am", "start", "-W", "-a", "android.settings.SETTINGS"], { timeoutMs: 30_000 });
      await Bun.sleep(1500);
      try {
        const xml = await this.hierarchy();
        if (xml.includes('package="com.android.settings"') && /text="(?:Settings|Search settings|Network &amp; internet)"/.test(xml)) {
          await Bun.write(join(this.directory, "screen.xml"), xml, { mode: 0o600 });
          return;
        }
      } catch (error) { if (this.signal?.aborted) throw error; }
    }
    throw new Error("Android did not render the Settings input screen within 90 seconds");
  }
  private assertOwned() { if (!this.verified) throw new Error("Device ownership has not been verified"); }
  async installHello(apk: string) {
    this.assertOwned();
    await this.exec([this.tools.adb, "-s", this.serial, "install", "-g", apk], { timeoutMs: 120_000 });
  }
  async forward(port: number) {
    this.assertOwned();
    if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid loopback port");
    await this.adb("reverse", "--no-rebind", `tcp:${port}`, `tcp:${port}`);
  }
  async launchHello(port: number) {
    this.assertOwned();
    if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid Metro port");
    await this.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP");
    await this.adb("shell", "wm", "dismiss-keyguard");
    await this.exec([this.tools.adb, "-s", this.serial, "shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d",
      `switchyard-hello://expo-development-client/?url=${encodeURIComponent(`http://127.0.0.1:${port}`)}`, "com.managoat.switchyard.hello"], { timeoutMs: 30_000 });
  }
  async readHierarchy() { this.assertOwned(); return this.hierarchy(); }
  async tap(x: number, y: number) {
    this.assertOwned();
    if (![x, y].every(n => Number.isInteger(n) && n >= 0 && n <= 16384)) throw new Error("Invalid tap coordinates");
    await this.adb("shell", "input", "tap", String(x), String(y));
  }
  async appendHelloName() {
    this.assertOwned();
    await this.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END");
    await this.adb("shell", "input", "text", "runner");
    await this.adb("shell", "input", "keyevent", "KEYCODE_BACK");
  }
  async scrollHello() {
    this.assertOwned();
    await this.adb("shell", "input", "swipe", "500", "1800", "500", "500", "600");
  }
  async screenshot(path: string) {
    this.assertOwned(); const bytes = await this.exec([this.tools.adb, "-s", this.serial, "exec-out", "screencap", "-p"], { maxBytes: 16 * 1024 * 1024 });
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error("Android screenshot was not PNG");
    await Bun.write(path, bytes, { mode: 0o600 });
  }
  async input() {
    this.assertOwned();
    await this.adb("shell", "input", "swipe", "500", "1800", "500", "500", "600");
    await Bun.sleep(1000);
    await this.screenshot(join(this.directory, "swipe.png"));
    await this.adb("shell", "input", "swipe", "500", "500", "500", "1800", "600");
    await Bun.sleep(1000);
    // Search moves as the Settings header collapses. Read its current bounds
    // instead of accepting text input sent to an unfocused screen.
    const xml = await this.hierarchy();
    await Bun.write(join(this.directory, "input-screen.xml"), xml, { mode: 0o600 });
    await Bun.write(join(this.directory, "display.txt"), await this.adb("shell", "wm", "size"), { mode: 0o600 });
    const search = xml.match(/<node\b[^>]*text="Search settings"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if (!search) throw new Error("Settings search bounds unavailable for the input experiment");
    const [, left, top, right, bottom] = search.map(Number);
    await this.adb("shell", "input", "tap", String(Math.round((left! + right!) / 2)), String(Math.round((top! + bottom!) / 2)));
    await Bun.sleep(3000);
    await this.screenshot(join(this.directory, "tap.png"));
    await this.adb("shell", "input", "text", "switchyard");
    await Bun.sleep(3000);
    const after = await this.hierarchy();
    await Bun.write(join(this.directory, "input-after.xml"), after, { mode: 0o600 });
    if (!after.includes('text="switchyard"')) throw new Error("Android did not show the injected Settings search text");
  }
  async record(path: string) {
    this.assertOwned();
    await this.exec([this.tools.scrcpy, "--serial", this.serial, "--no-window", "--no-playback", "--no-audio", "--no-control", "--video-codec=h264", "--video-bit-rate=4000000", "--max-size=1280", "--max-fps=30", "--time-limit=20", `--record=${path}`], { timeoutMs: 35_000 });
  }
  async live(options: Pick<Parameters<typeof scrcpyLive>[0], "metadata" | "frame" | "failed">) {
    this.assertOwned();
    return scrcpyLive({ ...options, adb: this.tools.adb, serial: this.serial, run: this.run, env: this.env,
      signal: AbortSignal.any([this.controller.signal, ...(this.signal ? [this.signal] : [])]) });
  }
  async stop() {
    this.controller.abort(); await this.running?.catch(() => {});
    if (this.created) await checked(this.run, [this.tools.avdmanager, "delete", "avd", "--name", this.name], { env: this.env });
  }
}

export class IosExperiment implements OwnedAdapter {
  private udid: string | undefined;
  private controller = new AbortController();
  private companion: Promise<Buffer> | undefined;
  private readonly set: string;
  private socket = "";
  private socketDirectory?: string;
  constructor(private config: Extract<ExperimentConfig, { platform: "ios" }>, private id: string, private directory: string, private tools: ToolPaths, private run: Command, private signal?: AbortSignal, private env?: NodeJS.ProcessEnv, private lifetimeMs = 90_000) {
    this.set = join(directory, "simulators");
  }
  private sim(...args: string[]) { return checked(this.run, [this.tools.xcrun, "simctl", "--set", this.set, ...args], { env: this.env, signal: this.signal, timeoutMs: 120_000 }); }
  private idb(...args: string[]) { return checked(this.run, [this.tools.idb, "--no-prune-dead-companion", "--companion", this.socket, ...args], { env: this.env, signal: this.signal }); }
  async boot() {
    // Private set + explicit UDID on every operation; never `booted` or `all`.
    await checked(this.run, [this.tools.idbCompanion ?? "idb_companion", "--version"], { env: this.env });
    await checked(this.run, [this.tools.idb, "--help"], { env: this.env });
    this.socketDirectory = await mkdtemp(join(process.platform === "darwin" ? "/private/tmp" : tmpdir(), "sy-idb-"));
    await chmod(this.socketDirectory, 0o700);
    this.socket = join(this.socketDirectory, "idb.sock");
    await mkdir(this.set, { mode: 0o700 });
    const udid = (await this.sim("create", `Switchyard-${this.id}`, this.config.deviceType, this.config.runtime)).toString().trim();
    if (!/^[A-Fa-f0-9-]{36}$/.test(udid)) throw new Error("simctl returned an invalid device ID");
    this.udid = udid;
    await writePrivateJson(join(this.directory, "device.json"), { udid, set: this.set, socketDirectory: this.socketDirectory });
    await this.sim("boot", udid); await this.sim("bootstatus", udid, "-b");
    this.companion = checked(this.run, [this.tools.idbCompanion ?? "idb_companion", "--udid", udid, "--device-set-path", this.set, "--only", "simulator", "--grpc-domain-sock", this.socket],
      { env: this.env, signal: AbortSignal.any([this.controller.signal, ...(this.signal ? [this.signal] : [])]), timeoutMs: this.lifetimeMs, maxBytes: 4 * 1024 * 1024 });
    void this.companion.catch(() => {});
    for (let attempt = 0; ; attempt++) {
      this.signal?.throwIfAborted();
      try { await this.idb("describe"); break; }
      catch (error) { if (attempt === 10) throw error; await Promise.race([Bun.sleep(500), this.companion.then(() => { throw new Error("idb companion exited"); })]); }
    }
  }
  private ownedUdid() { if (!this.udid) throw Error("No owned simulator"); return this.udid; }
  async installHello(path: string) { await this.sim("install", this.ownedUdid(), path); }
  async forward(port: number) { if (!Number.isInteger(port) || port < 1024 || port > 65535) throw Error("Unexpected simulator service port"); }
  async launchHello(port: number) {
    await this.forward(port);
    await this.sim("launch", this.ownedUdid(), "com.managoat.switchyard.hello");
    await this.sim("openurl", this.ownedUdid(), `switchyard-hello://expo-development-client/?url=${encodeURIComponent(`http://127.0.0.1:${port}`)}`);
  }
  async readHierarchy() { this.ownedUdid(); return (await this.idb("ui", "describe-all", "--json")).toString(); }
  async tap(x: number, y: number) { this.ownedUdid(); await this.idb("ui", "tap", String(x), String(y)); }
  async live(options: Pick<Parameters<typeof iosLive>[0], "metadata" | "frame" | "failed">) {
    return iosLive({ ...options, idb: this.tools.idb, socket: this.socket, udid: this.ownedUdid(), env: this.env ?? process.env,
      signal: AbortSignal.any([this.controller.signal, ...(this.signal ? [this.signal] : [])]) });
  }
  async prepare() {
    if (!this.udid) throw new Error("No owned simulator");
    await this.sim("launch", this.udid, "com.apple.Preferences");
    await Bun.sleep(3000);
    await Bun.write(join(this.directory, "screen.json"), await this.idb("describe", "--json"), { mode: 0o600 });
  }
  async screenshot(path: string) {
    if (!this.udid) throw new Error("No owned simulator");
    await this.sim("io", this.udid, "screenshot", "--type=png", path);
    const file = await lstat(path);
    if (!file.isFile() || file.size > 16 * 1024 * 1024) throw new Error("iOS screenshot exceeded 16 MiB");
    await chmod(path, 0o600);
    const bytes = await readFile(path);
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error("iOS screenshot was not PNG");
  }
  async input() {
    if (!this.udid) throw new Error("No owned simulator");
    await this.idb("ui", "swipe", "200", "700", "200", "300", "--duration", "0.6");
    await Bun.sleep(1000);
    await this.screenshot(join(this.directory, "swipe.png"));
    await this.idb("ui", "swipe", "200", "300", "200", "700", "--duration", "0.6");
    await Bun.sleep(1000);
    await this.idb("ui", "tap", "200", "180");
    await Bun.sleep(1000);
    await this.idb("ui", "text", "switchyard");
  }
  async record(path: string) {
    await checked(this.run, [this.tools.idb, "--no-prune-dead-companion", "--companion", this.socket, "record-video", path], { env: this.env, signal: this.signal, interruptAfterMs: 20_000, timeoutMs: 35_000 });
  }
  async stop() {
    this.controller.abort(); await this.companion?.catch(() => {});
    if (this.udid) {
      const argv = [this.tools.xcrun, "simctl", "--set", this.set];
      // Shutdown may report already stopped; deletion must succeed to clear lock.
      await this.run([...argv, "shutdown", this.udid], { env: this.env });
      await checked(this.run, [...argv, "delete", this.udid], { env: this.env });
    }
    if (this.socketDirectory) await rm(this.socketDirectory, { recursive: true });
  }
}
