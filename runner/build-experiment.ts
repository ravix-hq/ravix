import { arch, platform, userInfo } from "node:os";
import { chmod, copyFile, lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { command, type Command } from "./process";
import { doctor, toolEnvironment, toolPaths, type ToolPaths } from "./doctor";
import { acquireExperiment, writePrivateJson } from "./state";
import { digestBytes, extractSnapshot, loadSnapshot } from "./snapshot";

export interface BuildExperimentConfig { snapshot: string; stateDirectory: string; expectedAccount: string }
const APPLICATION_ID = "com.managoat.switchyard.hello";

export function parseBuildConfig(value: unknown): BuildExperimentConfig {
  const v = value as BuildExperimentConfig | null;
  if (!v || typeof v !== "object" || typeof v.expectedAccount !== "string" || !/^[a-z][a-z0-9_-]{0,31}$/.test(v.expectedAccount)) throw new Error("Select the dedicated build account");
  for (const path of [v.snapshot, v.stateDirectory]) if (typeof path !== "string" || !path.startsWith("/") || /[\x00-\x1f]/.test(path)) throw new Error("Use absolute snapshot and private state paths");
  return { snapshot: v.snapshot, stateDirectory: v.stateDirectory, expectedAccount: v.expectedAccount };
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

/** First Android artifact experiment. No device selection, Metro, install or
 * launch commands are used. It must run as the chosen standard Mac account. */
export async function buildExperiment(config: BuildExperimentConfig, signal?: AbortSignal, run: Command = command) {
  const user = userInfo();
  if (platform() !== "darwin" || arch() !== "arm64") throw new Error("This experiment targets the provisioned Apple Silicon Mac");
  if (user.username !== config.expectedAccount || user.uid === 0) throw new Error(`Run this build as the dedicated ${config.expectedAccount} account`);
  const snapshot = await loadSnapshot(config.snapshot);
  const packageFile = snapshot.files.find(f => f.path === "package.json");
  const appFile = snapshot.files.find(f => f.path === "app.json");
  const lockFile = snapshot.files.find(f => f.path === "package-lock.json");
  if (!packageFile || !appFile || !lockFile) throw new Error("Fixture requires package.json, app.json and package-lock.json at repository root");
  const pkg = JSON.parse(Buffer.from(packageFile.data, "base64").toString());
  const app = JSON.parse(Buffer.from(appFile.data, "base64").toString());
  if (pkg.name !== "switchyard-expo-hello" || !pkg.dependencies?.["expo-dev-client"] || app.expo?.android?.package !== APPLICATION_ID) throw new Error("This experiment only builds the Switchyard Hello Expo development-client fixture");

  const owned = await acquireExperiment(config.stateDirectory);
  const worktree = join(owned.directory, "worktree");
  const paths = await toolPaths({ HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` });
  const env = buildEnvironment(paths, user.homedir, owned.directory);
  const deadline = AbortSignal.timeout(45 * 60_000);
  const activeSignal = AbortSignal.any([deadline, ...(signal ? [signal] : [])]);
  const report = {
    version: 1, kind: "android-build-experiment", account: user.username, platform: "android", architecture: "arm64-v8a",
    startedAt: new Date().toISOString(), sourceDigest: snapshot.digest, lockfileDigest: lockFile.sha256,
    applicationId: APPLICATION_ID, phases: [] as { name: string; startedAt: string; elapsedMs: number | null; passed: boolean | null; error?: string }[],
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
      if (!inventory.android.prerequisites) throw new Error(inventory.android.blockers.join("\n"));
    });
    await phase("stage-source", async () => {
      await extractSnapshot(snapshot, worktree);
      await mkdir(env.TMPDIR!, { mode: 0o700 });
      await writeFile(env.npm_config_userconfig!, "", { mode: 0o600 });
    });
    await phase("install-dependencies", async () => {
      await exec("npm-ci", ["npm", "ci", "--no-audit", "--no-fund"], worktree, 10 * 60_000);
    });
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
  } catch (error) { report.error = error instanceof Error ? error.message : String(error); }
  finally {
    await save();
    // Subprocess execution has settled before the acquisition is released.
    // Sources/logs/artifact remain private for diagnosis; no cache eviction yet.
    await owned.release();
  }
  return { directory: owned.directory, report };
}
