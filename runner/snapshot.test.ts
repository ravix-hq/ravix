import { afterEach, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { checked, command, type Command } from "./process";
import { digestBytes, exportSnapshot, extractSnapshot, parseSnapshot } from "./snapshot";
import { buildEnvironment, parseBuildConfig } from "./build-experiment";

const cleanup: string[] = [];
afterEach(async () => { for (const path of cleanup.splice(0)) await rm(path, { recursive: true, force: true }); });
async function repository() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "sy-snapshot-"))); cleanup.push(root);
  await checked(command, ["git", "init", "-q", root]);
  return root;
}

test("snapshot preserves working-copy edits, deletions, untracked sources and workspace files", async () => {
  const root = await repository();
  await mkdir(join(root, "packages/lib"), { recursive: true });
  await writeFile(join(root, "App.tsx"), "old");
  await writeFile(join(root, "deleted.ts"), "delete me");
  await writeFile(join(root, "packages/lib/index.ts"), "shared");
  await checked(command, ["git", "-C", root, "add", "."]);
  await writeFile(join(root, "App.tsx"), "uncommitted");
  await rm(join(root, "deleted.ts"));
  await writeFile(join(root, "new.ts"), "untracked");
  await chmod(join(root, "new.ts"), 0o755);
  await writeFile(join(root, ".env"), "PRIVATE_TOKEN=excluded");
  await mkdir(join(root, "node_modules"));
  await writeFile(join(root, "node_modules/native.node"), "wrong platform");
  const snapshot = await exportSnapshot(root);
  expect(snapshot.files.map(f => f.path)).toEqual(["App.tsx", "new.ts", "packages/lib/index.ts"]);
  const stage = join(root, "stage");
  await extractSnapshot(snapshot, stage);
  expect(await readFile(join(stage, "App.tsx"), "utf8")).toBe("uncommitted");
  expect(await readFile(join(stage, "packages/lib/index.ts"), "utf8")).toBe("shared");
  expect(snapshot.files.find(f => f.path === "new.ts")?.mode).toBe(0o755);
  await expect(extractSnapshot(snapshot, stage)).rejects.toThrow();
});

test("snapshot refuses links and retries observed source churn", async () => {
  const root = await repository();
  await writeFile(join(root, "App.tsx"), "first");
  let scans = 0;
  const changing: Command = async (argv, options) => {
    if (argv.includes("ls-files")) await writeFile(join(root, "App.tsx"), `edit-${++scans}`);
    return command(argv, options);
  };
  await expect(exportSnapshot(root, changing)).rejects.toThrow("Source changed during export");
  expect(scans).toBe(6);
  await symlink("/etc/hosts", join(root, "escape"));
  await expect(exportSnapshot(root)).rejects.toThrow("links and special files");
});

test("manifest rejects traversal, tampering and Mac case/parent collisions before extraction", async () => {
  const root = await repository();
  await writeFile(join(root, "file.ts"), "fixture");
  const snapshot = await exportSnapshot(root);
  const original = snapshot.files[0]!;
  for (const path of ["../escape", "/outside", "a/../../outside", "a\\outside", ".git/config", ".GIT/config", "a//b", ".env", "a/./b"]) {
    expect(() => parseSnapshot({ ...snapshot, files: [{ ...original, path }] })).toThrow();
  }
  expect(() => parseSnapshot({ ...snapshot, files: [{ ...original, data: Buffer.from("changed").toString("base64") }] })).toThrow("hash or size mismatch");
  expect(() => parseSnapshot({ ...snapshot, files: [original, { ...original, path: "FILE.ts" }] })).toThrow("case-colliding");
  expect(() => parseSnapshot({ ...snapshot, files: [original, { ...original, path: "file.ts/child" }] })).toThrow("parent directory");
  const invalid = { ...snapshot, files: [{ ...original, sha256: digestBytes("wrong") }] };
  await expect(extractSnapshot(invalid, join(root, "untouched"))).rejects.toThrow();
  await expect(readFile(join(root, "untouched/file.ts"))).rejects.toThrow();
});

test("build experiment environment excludes invoking credentials and scopes temporary/cache state", () => {
  const account = userInfo().username;
  const config = { snapshot: "/private/tmp/source.json", stateDirectory: "/private/tmp/build", expectedAccount: account };
  expect(parseBuildConfig(config)).toEqual(config);
  expect(() => parseBuildConfig({ ...config, expectedAccount: "--root" })).toThrow();
  expect(() => parseBuildConfig({ ...config, snapshot: "relative" })).toThrow();
  const env = buildEnvironment({ sdk: "/sdk", adb: "/sdk/platform-tools/adb", emulator: "/sdk/emulator/emulator", avdmanager: "avdmanager", idb: "idb", xcrun: "xcrun", scrcpy: "scrcpy", javaHome: "/java" }, "/runner", "/build");
  expect(env.HOME).toBe("/runner"); expect(env.GRADLE_USER_HOME).toBe("/build/gradle");
  expect(env.npm_config_userconfig).toBe("/build/npmrc"); expect(env.TMPDIR).toBe("/build/tmp");
  expect(env.JAVA_HOME).toBe("/java"); expect(env.SSH_AUTH_SOCK).toBeUndefined();
  expect(env.GITHUB_TOKEN).toBeUndefined(); expect(env.NODE_OPTIONS).toBeUndefined();
});
