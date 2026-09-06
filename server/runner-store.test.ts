import { afterEach, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { RunnerStore } from './runner-store';
import { RUNNER, parseRunnerCapabilities } from '../shared/runners';
const cleanup: (() => void)[] = [];
afterEach(() => { for (const fn of cleanup.splice(0).reverse())
    fn(); });
const capabilities = parseRunnerCapabilities({ version: 1, capacity: { sessions: 1, builds: 1 }, builds: [{ platform: 'android', architecture: 'arm64-v8a', profile: 'pixel_7', runtime: 'system-images;android-35;google_apis;arm64-v8a', toolchain: 'android-35', artifactSha256: 'a'.repeat(64), sourceDigest: 'b'.repeat(64), lockfileDigest: 'c'.repeat(64) }] });
function fixture() {
    const directory = mkdtempSync(join(tmpdir(), 'sy-queue-')), path = join(directory, 'db.sqlite');
    const db = new Database(path);
    db.exec('PRAGMA foreign_keys=ON; CREATE TABLE users(id TEXT PRIMARY KEY); CREATE TABLE tracks(id TEXT PRIMARY KEY); INSERT INTO users VALUES (\'owner\'); INSERT INTO tracks VALUES (\'one\'),(\'two\');');
    cleanup.push(() => { db.close(); rmSync(directory, { recursive: true, force: true }); });
    const store = new RunnerStore(db);
    store.pair('pair', 'owner', ['project'], 1000);
    const runner = store.register('pair', 'hashed-token', 'Mac', capabilities, 1001);
    const context = (trackId = 'one') => ({ trackId, projectId: 'project', userId: 'owner', sessionHash: 'hash', projectRevision: 1, agentId: 'agent', workdir: '/work/' + trackId });
    return { store, runner, context, path };
}
test('single-use expiring pairing persists only credential verifier', () => {
    const { store, runner } = fixture();
    expect(store.runner(runner.id)?.tokenHash).toBe('hashed-token');
    expect(() => store.register('pair', 'other', 'Mac', capabilities, 1002)).toThrow('consumed');
    store.pair('late', 'owner', ['project'], 1000);
    expect(() => store.register('late', 'other', 'Mac', capabilities, 1000 + RUNNER.pairingMs)).toThrow('expired');
});
test('two tracks queue FIFO behind one slot; retry does not create work', () => {
    const { store, runner, context } = fixture(), r = store.connect(runner.id, 2000);
    const one = store.enqueue(context(), r.id, 'android', 'request-one', 2000), two = store.enqueue(context('two'), r.id, 'android', 'request-two', 2001);
    expect(store.enqueue(context(), r.id, 'android', 'request-one', 2002).id).toBe(one.id);
    expect(() => store.enqueue(context(), r.id, 'android', 'different', 2002)).toThrow('active');
    expect(two.targetId).not.toBe(one.targetId);
    expect(one.buildIdentity).toBe(JSON.stringify(capabilities.builds[0]));
    expect(store.position(two.id)).toBe(2);
    const work = store.assign(r.id, r.epoch, 2003)!;
    expect(work.id).toBe(one.id);
    expect(work.generation).toBe(1);
    expect(store.assign(r.id, r.epoch, 2004)).toBeNull();
    store.stop(one.id);
    expect(store.assign(r.id, r.epoch, 2005)).toBeNull();
    expect(store.complete(one.id, r.id, r.epoch, work.generation, null)).toBe(true);
    expect(store.enqueue(context(), r.id, 'android', 'request-one', 2006).phase).toBe('Stopped');
    expect(store.assign(r.id, r.epoch, 2007)?.id).toBe(two.id);
});
test('restart retains queue, quarantines old assignment, and fences epochs and generations', () => {
    const { store, runner, context, path } = fixture(), r = store.connect(runner.id, 2000);
    const one = store.enqueue(context(), r.id, 'android', 'one', 2000);
    store.enqueue(context('two'), r.id, 'android', 'two', 2001);
    const work = store.assign(r.id, r.epoch, 2010)!;
    const secondDb = new Database(path);
    try {
        const recovered = new RunnerStore(secondDb);
        recovered.recover(2020);
        const next = recovered.connect(r.id, 2030);
        expect(next.epoch).toBe(r.epoch + 1);
        expect(recovered.renew(one.id, r.id, r.epoch, work.generation, 2040)).toBe(false);
        expect(recovered.complete(one.id, r.id, r.epoch, work.generation, null)).toBe(false);
        expect(recovered.assign(r.id, next.epoch, 2040)).toBeNull();
        recovered.reconcile(work.leaseUntil);
        recovered.heartbeat(r.id, next.epoch, work.leaseUntil);
        const replacement = recovered.assign(r.id, next.epoch, work.leaseUntil)!;
        expect(replacement.id).toBe(one.id);
        expect(replacement.generation).toBe(2);
        expect(recovered.renew(one.id, r.id, next.epoch, 1, work.leaseUntil + 1)).toBe(false);
        expect(recovered.renew(one.id, r.id, next.epoch, 2, work.leaseUntil + 1)).toBe(true);
        expect(recovered.requests()).toHaveLength(2);
    }
    finally {
        secondDb.close();
    }
});
test('revocation, wrong owner/project, stale heartbeat and idle requests cannot consume a slot', () => {
    const { store, runner, context } = fixture(), r = store.connect(runner.id, 2000);
    expect(() => store.enqueue({ ...context(), userId: 'other' }, r.id, 'android', 'wrong')).toThrow('unavailable');
    expect(() => store.enqueue({ ...context(), projectId: 'other' }, r.id, 'android', 'wrong')).toThrow('unavailable');
    const one = store.enqueue(context(), r.id, 'android', 'one', 2000);
    expect(store.assign(r.id, r.epoch, 2000 + RUNNER.leaseMs)).toBeNull();
    store.reconcile(2000 + 5 * 60000 + 1);
    expect(store.request(one.id)?.phase).toBe('Failed');
    store.revoke(r.id);
    expect(store.heartbeat(r.id, r.epoch)).toBe(false);
    expect(() => store.enqueue(context(), r.id, 'android', 'two')).toThrow('unavailable');
});
test('stopping a queued target is immediate; target remains pinned to its original Mac', () => {
    const { store, runner, context } = fixture();
    const one = store.enqueue(context(), runner.id, 'android', 'one', 2000);
    store.stop(one.id);
    expect(store.request(one.id)?.phase).toBe('Stopped');
    store.pair('second', 'owner', ['project'], 2000);
    const other = store.register('second', 'second-token', 'other Mac', capabilities, 2001);
    expect(() => store.enqueue(context(), other.id, 'android', 'two', 2002)).toThrow('another runner');
    expect(store.enqueue(context(), runner.id, 'android', 'three', 2003).targetId).toBe(one.targetId);
});

test('disconnect fences channels and holds capacity until the cleanup lease expires',()=>{
    const {store,runner,context}=fixture(),r=store.connect(runner.id,2000);
    const one=store.enqueue(context(),r.id,'android','one',2000),work=store.assign(r.id,r.epoch,2001)!;
    store.disconnect(r.id,r.epoch);
    expect(store.request(one.id)?.phase).toBe('Reconciling');
    expect(store.renew(one.id,r.id,r.epoch,work.generation,2002)).toBe(false);
    expect(store.assign(r.id,r.epoch,2003)).toBeNull();
    const next=store.connect(r.id,2010);store.disconnect(r.id,r.epoch);
    expect(store.runner(r.id)?.lastSeen).toBe(2010);
    store.reconcile(work.leaseUntil);store.heartbeat(r.id,next.epoch,work.leaseUntil);
    expect(store.assign(r.id,next.epoch,work.leaseUntil)?.generation).toBe(2);
});
