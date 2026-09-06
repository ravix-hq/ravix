import { afterEach, expect, test } from 'bun:test';
import { chmod, lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { archiveCompletedRuntime } from './archive-runtime';
import { acquireExperiment } from './state';

const roots: string[] = [];
afterEach(async () => { for (const path of roots.splice(0)) await rm(path, { recursive: true, force: true }); });
async function root() { const path = await realpath(await mkdtemp(join(tmpdir(), 'sy-archive-'))); roots.push(path); return path; }
async function fixture(root: string, patch: Record<string, unknown> = {}) {
  const directory = join(root, `experiment-${crypto.randomUUID()}`);
  await mkdir(directory, { mode: 0o700 });
  await writeFile(join(directory, 'report.json'), JSON.stringify({ version: 1, kind: 'ios-sprite-preview-experiment', account: 'fixture', cleanup: 'complete', error: 'failed startup', ...patch }), { mode: 0o600 });
  return directory;
}

test('archiving frees runtime slots while preserving complete evidence and a path manifest', async () => {
  const path = await root();
  const directories = await Promise.all(Array.from({ length: 10 }, () => fixture(path)));
  const before = await readFile(join(directories[0]!, 'report.json'));
  await writeFile(join(directories[0]!, 'frame.png'), Buffer.from([0, 1, 2, 255]), { mode: 0o600 });
  await expect(acquireExperiment(path)).rejects.toThrow('Ten experiment');
  const result = await archiveCompletedRuntime(path, 'fixture');
  expect(result.archived).toHaveLength(10); expect(result.skipped).toEqual([]);
  const first = result.archived.find(item => item.from === directories[0])!;
  expect(await readFile(join(first.to, 'report.json'))).toEqual(before);
  expect(await readFile(join(first.to, 'frame.png'))).toEqual(Buffer.from([0, 1, 2, 255]));
  expect(JSON.parse(await readFile(join(result.directory!, 'archive.json'), 'utf8'))).toEqual(result);
  expect((await lstat(result.directory!)).mode & 0o777).toBe(0o700);
  const next = await acquireExperiment(path); await next.release();
});

test('an active or stale experiment lock prevents archiving', async () => {
  const path = await root(), directory = await fixture(path), active = await acquireExperiment(path);
  await expect(archiveCompletedRuntime(path, 'fixture')).rejects.toThrow('owns this directory');
  expect((await lstat(directory)).isDirectory()).toBe(true);
  expect((await lstat(join(path, 'experiment.lock'))).isFile()).toBe(true);
  await active.release();
});

test('incomplete, foreign, build, un-restored, malformed and linked evidence stays in place', async () => {
  const path = await root();
  const skipped = await Promise.all([
    fixture(path, { cleanup: 'pending' }), fixture(path, { account: 'another' }),
    fixture(path, { kind: 'ios-build-experiment' }), fixture(path, { kind: 'android-local-runtime-experiment', sourceRestored: false }),
  ]);
  const malformed = await fixture(path); await writeFile(join(malformed, 'report.json'), '{'); skipped.push(malformed);
  const shared = await fixture(path); await chmod(join(shared, 'report.json'), 0o644); skipped.push(shared);
  const linked = await fixture(path); await rm(join(linked, 'report.json')); await symlink(join(skipped[0]!, 'report.json'), join(linked, 'report.json')); skipped.push(linked);
  const outside = await root(), link = join(path, `experiment-${crypto.randomUUID()}`); await symlink(outside, link); skipped.push(link);
  const result = await archiveCompletedRuntime(path, 'fixture');
  expect(result.directory).toBeNull(); expect(result.archived).toEqual([]); expect(result.skipped).toHaveLength(skipped.length);
  for (const directory of skipped) expect(await lstat(directory)).toBeDefined();
  const next = await acquireExperiment(path); await next.release();
});
