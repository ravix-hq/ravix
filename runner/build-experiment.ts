import { arch, platform, userInfo } from "node:os";
import { chmod, copyFile, cp, lstat, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { command, type Command } from "./process";
import { doctor, toolEnvironment, toolPaths, type ToolPaths } from "./doctor";
import { acquireExperiment, writePrivateJson } from "./state";
import { digestBytes, extractSnapshot, loadSnapshot } from "./snapshot";

import { withIosBuildRuntime, type IosBuildRuntimeSelection } from "./ios-build-runtime";
import { iosArtifact } from "./ios-artifact";

export interface BuildExperimentConfig { snapshot: string; stateDirectory: string; expectedAccount: string; platform?: "android" | "ios" }
const APPLICATION_ID = "com.managoat.switchyard.hello";

export function parseBuildConfig(value: unknown): BuildExperimentConfig {
  const v = value as BuildExperimentConfig | null;
  if (!v || typeof v !== "object" || typeof v.expectedAccount !== "string" || !/^[a-z][a-z0-9_-]{0,31}$/.test(v.expectedAccount)) throw new Error("Select the dedicated build account");
  for (const path of [v.snapshot, v.stateDirectory]) if (typeof path !== "string" || !path.startsWith("/") || /[\x00-\x1f]/.test(path)) throw new Error("Use absolute snapshot and private state paths");
  if (v.platform !== undefined && v.platform !== "android" && v.platform !== "ios") throw new Error("Choose android or ios");
  return { snapshot: v.snapshot, stateDirectory: v.stateDirectory, expectedAccount: v.expectedAccount, ...(v.platform ? {platform: v.platform} : {}) };
}

/** Allowlist the build environment: never inherit provider tokens, SSH agent
 * sockets, Git configuration or the invoking account's SDK overrides. */
export function buildEnvironment(paths: ToolPaths, home: string, directory: string): NodeJS.ProcessEnv {
  return {
    ...toolEnvironment(paths, { HOME: home, PATH: `${home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: "en_US.UTF-8" }),
    CI: "1", EXPO_NO_TELEMETRY: "1", EXPO_NO_GIT_STATUS: "1",
    GRADLE_USER_HOME: join(directory, "gradle"), TMPDIR: join(directory, "tmp"),
    npm_config_cache: join(directory, "npm-cache"), npm_config_userconfig: join(directory, "npmrc"),
  };
}

/** Owned Android APK or iOS simulator artifact experiment. No device selection, Metro, install or
 * launch commands are used. It must run as the chosen standard Mac account. */
export async function buildExperiment(config: BuildExperimentConfig, signal?: AbortSignal, run: Command = command) {
  const user = userInfo(), target = config.platform ?? "android";
  if (platform() !== "darwin" || arch() !== "arm64") throw new Error("This experiment targets the provisioned Apple Silicon Mac");
  if (user.username !== config.expectedAccount || user.uid === 0) throw new Error(`Run this build as the dedicated ${config.expectedAccount} account`);
  const snapshot = await loadSnapshot(config.snapshot);
  const packageFile = snapshot.files.find(f => f.path === "package.json");
  const appFile = snapshot.files.find(f => f.path === "app.json");
  const lockFile = snapshot.files.find(f => f.path === "package-lock.json");
  if (!packageFile || !appFile || !lockFile) throw new Error("Fixture requires package.json, app.json and package-lock.json at repository root");
  const pkg = JSON.parse(Buffer.from(packageFile.data, "base64").toString());
  const app = JSON.parse(Buffer.from(appFile.data, "base64").toString());
  if (pkg.name !== "switchyard-expo-hello" || !pkg.dependencies?.["expo-dev-client"] || (target === "ios" ? app.expo?.ios?.bundleIdentifier : app.expo?.android?.package) !== APPLICATION_ID) throw new Error("This experiment only builds the Switchyard Hello Expo development-client fixture");

  const paths = await toolPaths({ HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` });
  const owned = await acquireExperiment(config.stateDirectory);
  const worktree = join(owned.directory, "worktree");
  const env: NodeJS.ProcessEnv = { ...buildEnvironment(paths, user.homedir, owned.directory), COCOAPODS_DISABLE_STATS: "true", RCT_NO_LAUNCH_PACKAGER: "1" };
  const deadline = AbortSignal.timeout(45 * 60_000);
  const activeSignal = AbortSignal.any([deadline, ...(signal ? [signal] : [])]);
  const report = {
    version: 1, kind: `${target}-build-experiment`, account: user.username, platform: target, architecture: target === "ios" ? "arm64" : "arm64-v8a",
    startedAt: new Date().toISOString(), sourceDigest: snapshot.digest, lockfileDigest: lockFile.sha256,
    applicationId: APPLICATION_ID, phases: [] as { name: string; startedAt: string; elapsedMs: number | null; passed: boolean | null; error?: string }[],
    iosRuntime: null as IosBuildRuntimeSelection | null,
    artifact: null as null | { path: string; sha256: string; size: number },
    nativeRuntimeVerified: false, metroVerified: false, browserVerified: false, error: null as string | null,
  };
  const save = () => writePrivateJson(join(owned.directory, "report.json"), report);
  const phase = async (name: string, action: () => Promise<void>) => {
    activeSignal.throwIfAborted();
    const start = Date.now();
    const entry = { name, startedAt: new Date().toISOString(), elapsedMs: null, passed: null } as typeof report.phases[number];
    report.phases.push(entry); await save(); console.log(`Build: ${name}`);
    try { await action(); entry.passed = true; }
    catch (error) { entry.passed = false; entry.error = String(error); throw error; }
    finally { entry.elapsedMs = Date.now() - start; await save(); }
  };
  const exec = async (name: string, argv: string[], cwd: string, timeoutMs: number) => {
    try {
      const result = await run(argv, { cwd, env, signal: activeSignal, timeoutMs, maxBytes: 8 * 1024 * 1024 });
      await writeFile(join(owned.directory, `${name}.log`), Buffer.concat([result.stdout, result.stderr]), { mode: 0o600 });
      if (result.code !== 0) throw new Error(`${name} failed (${result.code}): ${Buffer.concat([result.stdout, result.stderr]).toString().slice(-3000)}`);
      return result.stdout;
    } catch (error) {
      await writeFile(join(owned.directory, `${name}-error.log`), String(error), { mode: 0o600 });
      throw error;
    }
  };
  try {
    await phase("inventory", async () => {
      const inventory = await doctor(run, paths);
      await writePrivateJson(join(owned.directory, "doctor.json"), inventory);
      if (!inventory[target].prerequisites) throw new Error(inventory[target].blockers.join("\n"));
    });
    await phase("stage-source", async () => {
      await extractSnapshot(snapshot, worktree);
      await mkdir(env.TMPDIR!, { mode: 0o700 });
      await writeFile(env.npm_config_userconfig!, "", { mode: 0o600 });
    });
    await phase("install-dependencies", async () => {
      await exec("npm-ci", ["npm", "ci", "--no-audit", "--no-fund"], worktree, 10 * 60_000);
    });
    if (target === "android") {
    await phase("generate-android", async () => {
      await exec("expo-prebuild", ["node", join(worktree, "node_modules/expo/bin/cli"), "prebuild", "--platform", "android", "--no-install"], worktree, 5 * 60_000);
    });
    await phase("compile-android", async () => {
      await exec("gradle", ["/bin/bash", "./gradlew", ":app:assembleDebug", "--no-daemon", "--console=plain", "--max-workers=2", "-PreactNativeArchitectures=arm64-v8a", "-Dorg.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8"], join(worktree, "android"), 30 * 60_000);
    });
    await phase("verify-artifact", async () => {
      const apk = join(worktree, "android/app/build/outputs/apk/debug/app-debug.apk");
      if (await realpath(apk) !== apk) throw new Error("Artifact path uses a link");
      const stat = await lstat(apk);
      if (!stat.isFile() || stat.size < 1024 || stat.size > 512 * 1024 * 1024) throw new Error("APK missing or exceeds 512 MiB experiment limit");
      if (!paths.sdk) throw new Error("Android SDK unavailable");
      const badging = await exec("apk-badging", [join(paths.sdk, "build-tools/36.0.0/aapt2"), "dump", "badging", apk], worktree, 30_000);
      if (!badging.toString().includes(`package: name='${APPLICATION_ID}'`) || !/^native-code:.*'arm64-v8a'/m.test(badging.toString())) throw new Error("APK package identity or ABI does not match the fixture");
      const destination = join(owned.directory, "app-debug.apk");
      await copyFile(apk, destination); await chmod(destination, 0o600);
      report.artifact = { path: destination, size: stat.size, sha256: digestBytes(await readFile(destination)) };
    });
    } else {
      const ios = join(worktree, "ios"), derived = join(owned.directory, "derived-data");
      let workspace = "", scheme = "";
      await phase("generate-ios", async () => {
        await exec("expo-prebuild", ["node", join(worktree, "node_modules/expo/bin/cli"), "prebuild", "--platform", "ios", "--no-install"], worktree, 5 * 60_000);
        const candidates = (await readdir(ios)).filter(name => name.endsWith(".xcodeproj"));
        if (candidates.length !== 1) throw new Error("Expected one generated iOS application project");
        scheme = candidates[0]!.slice(0, -".xcodeproj".length);
        workspace = join(ios, `${scheme}.xcworkspace`);
      });
      await phase("install-pods", async () => {
        await exec("pod-install", ["pod", "install"], ios, 15 * 60_000);
      });
      console.log("Build: select-ios-runtime");
      await withIosBuildRuntime({run, xcrun: paths.xcrun, env, signal: activeSignal}, async selection => {
        report.iosRuntime = selection;
        await save();
        await phase("check-ios-destination", async () => {
          await exec("xcode-destination", ["xcodebuild", "-workspace", workspace, "-scheme", scheme, "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-showBuildSettings", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"], ios, 60_000);
        });
        await phase("compile-ios", async () => {
          await exec("xcodebuild", ["xcodebuild", "-workspace", workspace, "-scheme", scheme, "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived, "-resultBundlePath", join(owned.directory, "build.xcresult"), "-jobs", "2", "-quiet", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build"], ios, 30 * 60_000);
        });
      });
      await phase("verify-artifact", async () => {
        const products = join(derived, "Build/Products/Debug-iphonesimulator");
        const apps = (await readdir(products)).filter(name => name.endsWith(".app"));
        if (apps.length !== 1) throw new Error("Expected one simulator app product");
        const source = join(products, apps[0]!), plist = join(source, "Info.plist");
        const value = async (key: string) => (await exec(`plist-${key}`, ["plutil", "-extract", key, "raw", "-o", "-", plist], ios, 15_000)).toString().trim();
        if (await value("CFBundleIdentifier") !== APPLICATION_ID || await value("DTPlatformName") !== "iphonesimulator") throw new Error("iOS app identity or platform mismatch");
        const executable = await value("CFBundleExecutable");
        if (!/^[a-zA-Z0-9_-]+$/.test(executable)) throw new Error("Invalid simulator executable name");
        const binary = join(source, executable);
        const abi = (await exec("app-architectures", ["lipo", "-archs", binary], ios, 15_000)).toString().trim();
        const build = (await exec("app-platform", ["xcrun", "vtool", "-show-build", binary], ios, 15_000)).toString();
        if (abi !== "arm64" || !/platform\s+IOSSIMULATOR/.test(build)) throw new Error("Expected an arm64 simulator executable");
        await iosArtifact(source);
        const destination = join(owned.directory, "SwitchyardHello.app");
        await cp(source, destination, {recursive: true, errorOnExist: true, force: false});
        report.artifact = await iosArtifact(destination);
      });
    }
  } catch (error) { report.error = error instanceof Error ? error.message : String(error); }
  finally {
    await save();
    // Subprocess execution has settled before the acquisition is released.
    // Sources/logs/artifact remain private for diagnosis; no cache eviction yet.
    await owned.release();
  }
  return { directory: owned.directory, report };
}
