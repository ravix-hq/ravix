import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative } from "node:path";
import { checked, command, type Command } from "./process";

// Deliberately small first-experiment format. No tar extraction, links, ignored
// inputs or installed dependencies. Production source transfer is a later layer.
export const SNAPSHOT_LIMITS = { files: 5000, fileBytes: 8 * 1024 * 1024, totalBytes: 32 * 1024 * 1024, jsonBytes: 48 * 1024 * 1024 };
type SourceFile = { path: string; mode: 0o644 | 0o755; size: number; sha256: string; data: string };
export interface SourceSnapshot { version: 1; digest: string; files: SourceFile[] }
export const digestBytes = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
const omitted = new Set([".git", ".agents", ".codex", ".claude", ".ssh", ".aws", ".local", "node_modules", ".expo", ".gradle", "pods", "dist", "build", "artifacts", ".next", ".cache", "coverage", ".npmrc", ".yarnrc", ".yarnrc.yml"]);

function validPath(path: string) {
  return path.length > 0 && path.length <= 1000 && !isAbsolute(path) && !/[\x00-\x1f\\:]/.test(path)
    && path.split("/").every(part => part && part !== "." && part !== "..");
}
function eligible(path: string) {
  return !path.split("/").some(part => omitted.has(part.toLowerCase())
    || (part.toLowerCase().startsWith(".env") && part.toLowerCase() !== ".env.example")
    || /\.(?:pem|key|p12|p8|jks|mobileprovision)$/i.test(part));
}
function snapshotDigest(files: SourceFile[]) {
  return digestBytes(JSON.stringify(files.map(({ path, mode, size, sha256 }) => ({ path, mode, size, sha256 }))));
}

/** Validate the entire manifest and all content before creating any output. */
export function parseSnapshot(value: unknown): SourceSnapshot {
  if (!value || typeof value !== "object") throw new Error("Invalid source snapshot");
  const v = value as SourceSnapshot;
  if (v.version !== 1 || !Array.isArray(v.files) || v.files.length > SNAPSHOT_LIMITS.files || !/^[a-f0-9]{64}$/.test(v.digest)) throw new Error("Invalid source manifest");
  const names = new Set<string>();
  let total = 0;
  const files = v.files.map(file => {
    if (!file || typeof file.path !== "string" || !validPath(file.path) || !eligible(file.path)) throw new Error("Disallowed source path");
    const normalized = file.path.normalize("NFC").toLowerCase();
    if (names.has(normalized)) throw new Error("Duplicate or case-colliding source paths");
    names.add(normalized);
    if ((file.mode !== 0o644 && file.mode !== 0o755) || !Number.isSafeInteger(file.size) || file.size < 0 || file.size > SNAPSHOT_LIMITS.fileBytes) throw new Error("Invalid source file metadata");
    if (typeof file.data !== "string" || file.data.length > Math.ceil(SNAPSHOT_LIMITS.fileBytes / 3) * 4) throw new Error("Source file exceeds limit");
    const bytes = Buffer.from(file.data, "base64");
    if (bytes.length !== file.size || bytes.toString("base64") !== file.data || digestBytes(bytes) !== file.sha256) throw new Error("Source file hash or size mismatch");
    total += bytes.length;
    if (total > SNAPSHOT_LIMITS.totalBytes) throw new Error("Source snapshot exceeds 32 MiB");
    return { path: file.path, mode: file.mode, size: file.size, sha256: file.sha256, data: file.data };
  }).sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  for (const name of names) {
    let parent = dirname(name);
    while (parent !== ".") {
      if (names.has(parent)) throw new Error("Source file conflicts with a parent directory");
      parent = dirname(parent);
    }
  }
  if (snapshotDigest(files) !== v.digest) throw new Error("Source snapshot digest mismatch");
  return { version: 1, digest: v.digest, files };
}

/** Tracked edits/deletions + eligible untracked files; no commit is required.
 * Two complete reads must agree, including membership, permissions and bytes.
 * This detects observed churn; it is not an atomic filesystem snapshot. */
export async function exportSnapshot(source: string, run: Command = command): Promise<SourceSnapshot> {
  const root = await realpath(source);
  const gitRoot = (await checked(run, ["git", "-C", root, "rev-parse", "--show-toplevel"])).toString().trim();
  if (await realpath(gitRoot) !== root) throw new Error("Export the whole repository root to preserve workspace dependencies");
  const scan = async () => {
    const list = (await checked(run, ["git", "-c", "core.fsmonitor=false", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"], { maxBytes: 2 * 1024 * 1024 })).toString();
    const paths = [...new Set(list.split("\0").filter(Boolean))].sort();
    if (paths.length > SNAPSHOT_LIMITS.files) throw new Error("Source file count exceeds experiment limit");
    const files: SourceFile[] = [];
    let total = 0;
    for (const path of paths) {
      if (!validPath(path)) throw new Error("Invalid source path");
      if (!eligible(path)) continue;
      const full = join(root, path);
      const before = await lstat(full).catch(error => { if (error.code === "ENOENT") return null; throw error; });
      if (!before) continue; // A tracked deletion is absent from the clean stage.
      if (!before.isFile() || before.isSymbolicLink()) throw new Error(`Source links and special files are unsupported: ${path}`);
      const resolved = await realpath(full);
      const within = relative(root, resolved);
      if (within === ".." || within.startsWith("../") || resolved !== full) throw new Error(`Source path escapes or uses a link: ${path}`);
      if (before.size > SNAPSHOT_LIMITS.fileBytes || total + before.size > SNAPSHOT_LIMITS.totalBytes) throw new Error("Source snapshot exceeds size limits");
      const fd = await open(full, constants.O_RDONLY | constants.O_NOFOLLOW);
      let bytes: Buffer;
      try {
        const opened = await fd.stat();
        if (!opened.isFile() || opened.ino !== before.ino || opened.size !== before.size) throw new Error("Source changed during export");
        // Bound the read even if a writer grows this file after stat.
        const buffer = Buffer.alloc(before.size + 1);
        let read = 0;
        while (read < buffer.length) {
          const result = await fd.read(buffer, read, buffer.length - read, read);
          if (!result.bytesRead) break;
          read += result.bytesRead;
        }
        bytes = buffer.subarray(0, read);
        const after = await fd.stat();
        if (bytes.length !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs || await realpath(full) !== full) throw new Error("Source changed during export");
      } finally { await fd.close(); }
      total += bytes.length;
      files.push({ path, mode: before.mode & 0o111 ? 0o755 : 0o644, size: bytes.length, sha256: digestBytes(bytes), data: bytes.toString("base64") });
    }
    return parseSnapshot({ version: 1, digest: snapshotDigest(files), files });
  };
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const first = await scan(), second = await scan();
      if (first.digest === second.digest) return second;
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes("Source changed during export") || attempt === 2) throw error;
    }
  }
  throw new Error("Source changed during export; retry after writes settle");
}

export async function loadSnapshot(path: string): Promise<SourceSnapshot> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > SNAPSHOT_LIMITS.jsonBytes) throw new Error("Snapshot file exceeds limit or is not regular");
    const buffer = Buffer.alloc(stat.size + 1);
    let read = 0;
    while (read < buffer.length) {
      const result = await file.read(buffer, read, buffer.length - read, read);
      if (!result.bytesRead) break;
      read += result.bytesRead;
    }
    if (read !== stat.size) throw new Error("Snapshot changed while reading");
    return parseSnapshot(JSON.parse(buffer.subarray(0, read).toString()));
  } finally { await file.close(); }
}

export async function extractSnapshot(snapshot: SourceSnapshot, destination: string) {
  const validated = parseSnapshot(snapshot);
  // Destination must be new and inside an existing runner-owned private parent.
  const parent = await realpath(dirname(destination));
  if (parent !== dirname(destination)) throw new Error("Snapshot destination must have a real parent path");
  await mkdir(destination, { mode: 0o700 });
  for (const file of validated.files) {
    const path = join(destination, file.path);
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    await writeFile(path, Buffer.from(file.data, "base64"), { flag: "wx", mode: file.mode });
  }
}
