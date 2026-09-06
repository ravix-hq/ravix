import { lstat, open, readdir, readFile, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { userInfo } from 'node:os';
import { randomUUID } from 'node:crypto';
import { privateDirectory, writePrivateJson } from './state';

const runtimeKinds = new Set(['android-local-runtime-experiment', 'android-sprite-preview-experiment', 'ios-sprite-preview-experiment']);

/** Move completed evidence intact, under the same lock used by runtime startup. */
export async function archiveCompletedRuntime(statePath: string, account: string) {
  const root = await privateDirectory(statePath), lockPath = join(root, 'experiment.lock');
  const lock = await open(lockPath, 'wx', 0o600).catch(() => { throw Error('An experiment owns this directory. Finish it or inspect its lock before archiving.'); });
  const report = { directory: null as string | null, archived: [] as { from: string; to: string }[], skipped: [] as { directory: string; reason: string }[] };
  try {
    await lock.writeFile(JSON.stringify({ operation: 'archive-runtime', pid: process.pid, startedAt: new Date().toISOString() }) + '\n');
    const candidates: string[] = [];
    for (const name of (await readdir(root)).sort()) {
      if (!/^experiment-[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(name)) continue;
      const directory = join(root, name);
      try {
        await privateDirectory(directory);
        const path = join(directory, 'report.json'), stat = await lstat(path);
        if (!stat.isFile() || stat.size > 1024 * 1024 || stat.uid !== process.getuid?.() || (stat.mode & 0o077)) throw Error('Report must be a private, owned regular file');
        const result = JSON.parse(await readFile(path, 'utf8'));
        if (result.version !== 1 || result.account !== account || !runtimeKinds.has(result.kind) || result.cleanup !== 'complete') throw Error('Report does not confirm completed runtime cleanup');
        if (result.kind === 'android-local-runtime-experiment' && result.sourceRestored !== true) throw Error('Local runtime source restoration is unconfirmed');
        candidates.push(name);
      } catch (error) { report.skipped.push({ directory, reason: error instanceof Error ? error.message : String(error) }); }
    }
    if (!candidates.length) return report;
    const archiveRoot = await privateDirectory(join(root, 'archived'));
    report.directory = await privateDirectory(join(archiveRoot, `batch-${randomUUID()}`));
    const manifest = join(report.directory, 'archive.json');
    await writePrivateJson(manifest, report);
    for (const name of candidates) {
      const from = join(root, name), to = join(report.directory, name);
      await rename(from, to);
      report.archived.push({ from, to });
      await writePrivateJson(manifest, report);
    }
    return report;
  } finally { await lock.close(); await rm(lockPath); }
}

if (import.meta.main) {
  const user = userInfo();
  if (process.argv.length !== 3 || user.uid === 0 || user.username !== process.argv[2]) throw Error('Run as the dedicated runner account');
  console.log(JSON.stringify(await archiveCompletedRuntime(join(user.homedir, '.local/share/switchyard/runtime'), user.username), null, 2));
}
