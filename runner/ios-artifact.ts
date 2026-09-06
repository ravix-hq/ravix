import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open, readdir, realpath } from 'node:fs/promises';
import { join } from 'node:path';

/** Identity for the owned simulator bundle, including executable permission.
 * No links, special files or unbounded bundle walks are accepted. */
export async function iosArtifact(path: string) {
  if (await realpath(path) !== path || !(await lstat(path)).isDirectory()) throw new Error('Invalid iOS app directory');
  const hash = createHash('sha256').update('switchyard-ios-app-v1\0');
  let size = 0, files = 0, entries = 0;
  const walk = async (relative: string, depth: number): Promise<void> => {
    if (depth > 32) throw new Error('iOS app nesting exceeds limit');
    for (const name of (await readdir(join(path, relative))).sort()) {
      if (++entries > 50000) throw new Error("iOS app exceeds entry limits");
      if (/[\x00-\x1f\x7f]/.test(name)) throw new Error('Invalid iOS bundle entry');
      const entry = relative ? `${relative}/${name}` : name, full = join(path, entry), stat = await lstat(full);
      if (stat.isSymbolicLink()) throw new Error('iOS app contains a link');
      if (stat.isDirectory()) { hash.update(`directory\0${entry}\0`); await walk(entry, depth + 1); continue; }
      if (!stat.isFile() || stat.size > 256 * 1024 * 1024 || ++files > 50000 || (size += stat.size) > 1024 * 1024 * 1024) throw new Error('iOS app exceeds file limits');
      hash.update(`file\0${entry}\0${stat.mode & 0o111}\0${stat.size}\0`);
      const file = await open(full, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const before = await file.stat();
        if (before.ino !== stat.ino || before.dev !== stat.dev || before.size !== stat.size || before.mtimeMs !== stat.mtimeMs) throw new Error('iOS app changed during verification');
        const buffer = Buffer.alloc(64 * 1024);
        let read = 0;
        while (true) {
          const chunk = await file.read(buffer, 0, buffer.length, null);
          if (!chunk.bytesRead) break;
          read += chunk.bytesRead;
          if (read > stat.size) throw new Error('iOS app changed during verification');
          hash.update(buffer.subarray(0, chunk.bytesRead));
        }
        const after = await file.stat();
        if (read !== stat.size || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs || after.ctimeMs !== stat.ctimeMs) throw new Error('iOS app changed during verification');
      } finally { await file.close(); }
    }
  };
  await walk('', 0);
  if (!files) throw new Error('Empty iOS app');
  return { path, sha256: hash.digest('hex'), size, files, format: 'ios-simulator-app' as const };
}
