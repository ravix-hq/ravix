import { access, readFile, readdir } from "node:fs/promises";
import { constants } from "node:fs";
import { arch, cpus, hostname, platform, release, totalmem, userInfo } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { command, type Command } from "./process";

export interface Probe { available: boolean; output: string; error: string | null; elapsedMs: number; timeoutMs: number }
export interface DoctorReport {
  version: 1;
  recordedAt: string;
  host: { name: string; account: string; platform: string; architecture: string; osRelease: string; cpu: string; cores: number; memoryBytes: number };
  tools: Record<string, Probe>;
  android: { sdk: string | null; profiles: string[]; systemImages: string[]; prerequisites: boolean; blockers: string[] };
  ios: { runtimes: { id: string; name: string; version: string }[]; deviceTypes: { id: string; name: string }[]; prerequisites: boolean; blockers: string[] };
  livePreviewVerified: false;
}

export interface ToolPaths { adb: string; emulator: string; avdmanager: string; scrcpy: string; idb: string; xcrun: string; sdk: string | null; javaHome?: string; idbCompanion?: string }
async function executable(path: string): Promise<boolean> {
  try { await access(path, constants.X_OK); return true; } catch { return false; }
}
async function locate(name: string, candidates: string[], env: NodeJS.ProcessEnv): Promise<string> {
  for (const path of [...candidates, ...(env.PATH ?? "").split(delimiter).filter(Boolean).map(dir => join(dir, name))]) {
    if (await executable(path)) return path;
  }
  return name;
}
export async function toolPaths(env: NodeJS.ProcessEnv = process.env): Promise<ToolPaths> {
  const sdk = env.ANDROID_HOME || env.ANDROID_SDK_ROOT || (env.HOME ? join(env.HOME, "Library/Android/sdk") : null);
  const localBin = env.HOME ? join(env.HOME, ".local/bin") : "";
  const javaHome = env.JAVA_HOME || (await executable("/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin/java") ? "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" : undefined);
  const [adb, emulator, avdmanager, scrcpy, idb, xcrun, idbCompanion] = await Promise.all([
    locate("adb", sdk ? [join(sdk, "platform-tools/adb")] : [], env),
    locate("emulator", sdk ? [join(sdk, "emulator/emulator")] : [], env),
    locate("avdmanager", sdk ? [join(sdk, "cmdline-tools/latest/bin/avdmanager")] : [], env),
    locate("scrcpy", [], env), locate("idb", localBin ? [join(localBin, "idb")] : [], env), locate("xcrun", [], env),
    locate("idb_companion", localBin ? [join(localBin, "idb_companion")] : [], env),
  ]);
  return { adb, emulator, avdmanager, scrcpy, idb, xcrun, sdk, javaHome, idbCompanion };
}

/** Tool-local environment: no shell profile edits or system Java symlinks. */
export function toolEnvironment(tools: ToolPaths, base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const directories = [tools.javaHome && join(tools.javaHome, "bin"), tools.adb, tools.emulator, tools.idb, tools.idbCompanion]
    .filter((path): path is string => !!path && path.startsWith("/"))
    .map(path => path === join(tools.javaHome ?? "", "bin") ? path : dirname(path));
  return { ...base, ...(tools.sdk ? { ANDROID_HOME: tools.sdk } : {}), ...(tools.javaHome ? { JAVA_HOME: tools.javaHome } : {}), PATH: [...new Set(directories), base.PATH ?? ""].join(delimiter) };
}

export async function installedSystemImages(sdk: string | null): Promise<string[]> {
  if (!sdk) return [];
  const directories = async (path: string) => (await readdir(path, { withFileTypes: true }).catch(() => [])).filter(entry => entry.isDirectory()).map(entry => entry.name);
  const images: string[] = [];
  for (const api of await directories(join(sdk, "system-images"))) {
    if (!/^android-\d+$/.test(api)) continue;
    for (const vendor of await directories(join(sdk, "system-images", api))) {
      for (const abi of await directories(join(sdk, "system-images", api, vendor))) {
        const properties = await readFile(join(sdk, "system-images", api, vendor, abi, "source.properties"), "utf8").catch(() => "");
        if (/^Pkg\.Revision\s*=/m.test(properties)) images.push(`system-images;${api};${vendor};${abi}`);
      }
    }
  }
  return images.sort();
}

/** Read-only inventory. No adb devices (which starts a daemon), boot, install,
 * license acceptance, pairing or downloads. Tool presence is never readiness. */
export async function doctor(run: Command = command, paths?: ToolPaths): Promise<DoctorReport> {
  const tools = paths ?? await toolPaths();
  const probes: Record<string, string[]> = {
    os: ["sw_vers"], node: ["node", "--version"], bun: ["bun", "--version"], java: ["java", "-version"],
    adb: [tools.adb, "version"], emulator: [tools.emulator, "-version"],
    acceleration: [tools.emulator, "-accel-check"], androidProfiles: [tools.emulator, "-list-avds"],
    avdmanager: [tools.avdmanager, "list", "device", "-c"], scrcpy: [tools.scrcpy, "--version"],
    xcode: ["xcodebuild", "-version"], iosRuntimes: [tools.xcrun, "simctl", "list", "runtimes", "--json"],
    iosDeviceTypes: [tools.xcrun, "simctl", "list", "devicetypes", "--json"],
    idb: [tools.idb, "--help"], idbCompanion: [tools.idbCompanion ?? "idb_companion", "--version"],
    cocoaPods: ["pod", "--version"],
  };
  const emulatorProbeNames = new Set(["emulator", "acceleration", "androidProfiles"]);
  const probe = async ([name, argv]: [string, string[]]): Promise<[string, Probe]> => {
    const timeoutMs = emulatorProbeNames.has(name) ? 60_000 : 15_000;
    const started = Date.now();
    try {
      const result = await run(argv, { env: toolEnvironment(tools), timeoutMs, maxBytes: 512 * 1024 });
      const output = (name === "iosRuntimes" || name === "iosDeviceTypes" ? result.stdout : Buffer.concat([result.stdout, result.stderr])).toString("utf8").trim();
      return [name, { available: result.code === 0, output, error: result.code === 0 ? null : `Exit ${result.code}: ${result.stderr.toString("utf8").trim().slice(-2000)}`, elapsedMs: Date.now() - started, timeoutMs }];
    } catch (error) {
      return [name, { available: false, output: "", error: error instanceof Error ? error.message : String(error), elapsedMs: Date.now() - started, timeoutMs }];
    }
  };
  // The new account timed out during concurrent emulator startup probes.
  // Serialize calls to that executable and allow a longer bounded diagnostic
  // window. A timeout still fails readiness; this does not assume its cause.
  const entries = Object.entries(probes);
  const [otherResults, emulatorResults] = await Promise.all([
    Promise.all(entries.filter(([name]) => !emulatorProbeNames.has(name)).map(probe)),
    (async () => {
      const results: [string, Probe][] = [];
      for (const entry of entries.filter(([name]) => emulatorProbeNames.has(name))) results.push(await probe(entry));
      return results;
    })(),
  ]);
  const byName = Object.fromEntries([...otherResults, ...emulatorResults]);
  const parse = (name: string): Record<string, unknown> => {
    if (!byName[name]?.available) return {};
    try { return JSON.parse(byName[name]!.output) as Record<string, unknown>; }
    catch { byName[name]!.available = false; byName[name]!.error = "Tool did not return valid JSON"; return {}; }
  };
  const runtimeData = parse("iosRuntimes").runtimes;
  const deviceData = parse("iosDeviceTypes").devicetypes;
  const runtimes = (Array.isArray(runtimeData) ? runtimeData : []).filter(r => r?.isAvailable === true && typeof r.identifier === "string" && r.identifier.includes(".iOS-")).map(r => ({ id: String(r.identifier), name: String(r.name), version: String(r.version) }));
  const deviceTypes = (Array.isArray(deviceData) ? deviceData : []).filter(d => typeof d?.identifier === "string" && /^iPhone|^iPad/.test(d.name)).map(d => ({ id: String(d.identifier), name: String(d.name) }));
  const profiles = byName.androidProfiles?.available ? byName.androidProfiles.output.split(/\r?\n/).filter(p => /^[A-Za-z0-9_.-]+$/.test(p)) : [];
  const missing = (names: string[]) => names.filter(name => !byName[name]?.available).map(name => `${name}: ${byName[name]?.error ?? "unavailable"}`);
  const androidBlockers = missing(["node", "java", "adb", "emulator", "acceleration", "avdmanager", "scrcpy"]);
  const iosBlockers = missing(["node", "xcode", "iosRuntimes", "iosDeviceTypes", "idb", "idbCompanion", "cocoaPods"]);
  if (platform() !== "darwin") { androidBlockers.push("This milestone requires the selected Mac runner"); iosBlockers.push("iOS simulators require macOS"); }
  const systemImages = await installedSystemImages(tools.sdk);
  if (!systemImages.length) androidBlockers.push("No installed Android system image");
  if (byName.iosRuntimes?.available && !runtimes.length) iosBlockers.push("No available iOS simulator runtime");
  if (byName.iosDeviceTypes?.available && !deviceTypes.length) iosBlockers.push("No iOS device types");
  return {
    version: 1, recordedAt: new Date().toISOString(),
    host: { name: hostname(), account: userInfo().username, platform: platform(), architecture: arch(), osRelease: release(), cpu: cpus()[0]?.model ?? "unknown", cores: cpus().length, memoryBytes: totalmem() },
    tools: byName,
    android: { sdk: tools.sdk, profiles, systemImages, prerequisites: androidBlockers.length === 0, blockers: androidBlockers },
    ios: { runtimes, deviceTypes, prerequisites: iosBlockers.length === 0, blockers: iosBlockers },
    livePreviewVerified: false,
  };
}
