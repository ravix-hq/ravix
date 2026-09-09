import { expect, test } from 'bun:test';
import { testSql } from './sql';
import { RunnerStore } from './runner-store';
import { RUNNER, parseRunnerCapabilities } from '../shared/runners';
const capabilities = parseRunnerCapabilities({ version: 1, capacity: { sessions: 1, builds: 1 }, builds: [{ platform: 'android', architecture: 'arm64-v8a', profile: 'pixel_7', runtime: 'system-images;android-35;google_apis;arm64-v8a', toolchain: 'android-35', artifactSha256: 'a'.repeat(64), sourceDigest: 'b'.repeat(64), lockfileDigest: 'c'.repeat(64) }] });
async function fixture() {
    const sql = await testSql();
    await sql.exec('CREATE TABLE users(id TEXT PRIMARY KEY); CREATE TABLE tracks(id TEXT PRIMARY KEY); INSERT INTO users VALUES (\'owner\'); INSERT INTO tracks VALUES (\'one\'),(\'two\');');
    const store = new RunnerStore(sql);
    await store.init();
    await store.pair('pair', 'owner', ['project'], 1000);
    const runner = await store.register('pair', 'hashed-token', 'Mac', capabilities, 1001);
    const context = (trackId = 'one') => ({ trackId, projectId: 'project', userId: 'owner', sessionHash: 'hash', projectRevision: 1, agentId: 'agent', workdir: '/work/' + trackId });
    return { store, runner, context, sql };
}
test('single-use expiring pairing persists only credential verifier', async () => {
    const { store, runner } = await fixture();
    expect((await store.runner(runner.id))?.tokenHash).toBe('hashed-token');
    await expect(store.register('pair', 'other', 'Mac', capabilities, 1002)).rejects.toThrow('consumed');
    await store.pair('late', 'owner', ['project'], 1000);
    await expect(store.register('late', 'other', 'Mac', capabilities, 1000 + RUNNER.pairingMs)).rejects.toThrow('expired');
});
test('two tracks queue FIFO behind one slot; retry does not create work', async () => {
    const { store, runner, context } = await fixture(), r = await store.connect(runner.id, 2000);
    const one = await store.enqueue(context(), r.id, 'android', 'request-one', 2000), two = await store.enqueue(context('two'), r.id, 'android', 'request-two', 2001);
    expect((await store.enqueue(context(), r.id, 'android', 'request-one', 2002)).id).toBe(one.id);
    await expect(store.enqueue(context(), r.id, 'android', 'different', 2002)).rejects.toThrow('active');
    expect(two.targetId).not.toBe(one.targetId);
    expect(one.buildIdentity).toBe(JSON.stringify(capabilities.builds[0]));
    expect(await store.position(two.id)).toBe(2);
    const work = (await store.assign(r.id, r.epoch, 2003))!;
    expect(work.id).toBe(one.id);
    expect(work.generation).toBe(1);
    expect(await store.assign(r.id, r.epoch, 2004)).toBeNull();
    await store.stop(one.id);
    expect(await store.assign(r.id, r.epoch, 2005)).toBeNull();
    expect(await store.complete(one.id, r.id, r.epoch, work.generation, null)).toBe(true);
    expect((await store.enqueue(context(), r.id, 'android', 'request-one', 2006)).phase).toBe('Stopped');
    expect((await store.assign(r.id, r.epoch, 2007))?.id).toBe(two.id);
});
test('restart retains queue, quarantines old assignment, and fences epochs and generations', async () => {
    const { store, runner, context, sql } = await fixture(), r = await store.connect(runner.id, 2000);
    const one = await store.enqueue(context(), r.id, 'android', 'one', 2000);
    await store.enqueue(context('two'), r.id, 'android', 'two', 2001);
    const work = (await store.assign(r.id, r.epoch, 2010))!;
    const recovered = new RunnerStore(sql);
    await recovered.init();
    await recovered.recover(2020);
    const next = await recovered.connect(r.id, 2030);
    expect(next.epoch).toBe(r.epoch + 1);
    expect(await recovered.renew(one.id, r.id, r.epoch, work.generation, 2040)).toBe(false);
    expect(await recovered.complete(one.id, r.id, r.epoch, work.generation, null)).toBe(false);
    expect(await recovered.assign(r.id, next.epoch, 2040)).toBeNull();
    await recovered.reconcile(work.leaseUntil);
    await recovered.heartbeat(r.id, next.epoch, work.leaseUntil);
    const replacement = (await recovered.assign(r.id, next.epoch, work.leaseUntil))!;
    expect(replacement.id).toBe(one.id);
    expect(replacement.generation).toBe(2);
    expect(await recovered.renew(one.id, r.id, next.epoch, 1, work.leaseUntil + 1)).toBe(false);
    expect(await recovered.renew(one.id, r.id, next.epoch, 2, work.leaseUntil + 1)).toBe(true);
    expect(await recovered.requests()).toHaveLength(2);
});
test('revocation, wrong owner/project, stale heartbeat and idle requests cannot consume a slot', async () => {
    const { store, runner, context } = await fixture(), r = await store.connect(runner.id, 2000);
    await expect(store.enqueue({ ...context(), userId: 'other' }, r.id, 'android', 'wrong')).rejects.toThrow('unavailable');
    await expect(store.enqueue({ ...context(), projectId: 'other' }, r.id, 'android', 'wrong')).rejects.toThrow('unavailable');
    const one = await store.enqueue(context(), r.id, 'android', 'one', 2000);
    expect(await store.assign(r.id, r.epoch, 2000 + RUNNER.leaseMs)).toBeNull();
    await store.reconcile(2000 + 5 * 60000 + 1);
    expect((await store.request(one.id))?.phase).toBe('Failed');
    await store.revoke(r.id);
    expect(await store.heartbeat(r.id, r.epoch)).toBe(false);
    await expect(store.enqueue(context(), r.id, 'android', 'two')).rejects.toThrow('unavailable');
});
test('stopping a queued target is immediate; target remains pinned to its original Mac', async () => {
    const { store, runner, context } = await fixture();
    const one = await store.enqueue(context(), runner.id, 'android', 'one', 2000);
    await store.stop(one.id);
    expect((await store.request(one.id))?.phase).toBe('Stopped');
    await store.pair('second', 'owner', ['project'], 2000);
    const other = await store.register('second', 'second-token', 'other Mac', capabilities, 2001);
    await expect(store.enqueue(context(), other.id, 'android', 'two', 2002)).rejects.toThrow('another runner');
    expect((await store.enqueue(context(), runner.id, 'android', 'three', 2003)).targetId).toBe(one.targetId);
});

test('disconnect fences channels and holds capacity until the cleanup lease expires',async()=>{
    const {store,runner,context}=await fixture(),r=await store.connect(runner.id,2000);
    const one=await store.enqueue(context(),r.id,'android','one',2000),work=(await store.assign(r.id,r.epoch,2001))!;
    await store.disconnect(r.id,r.epoch);
    expect((await store.request(one.id))?.phase).toBe('Reconciling');
    expect(await store.renew(one.id,r.id,r.epoch,work.generation,2002)).toBe(false);
    expect(await store.assign(r.id,r.epoch,2003)).toBeNull();
    const next=await store.connect(r.id,2010);await store.disconnect(r.id,r.epoch);
    expect((await store.runner(r.id))?.lastSeen).toBe(2010);
    await store.reconcile(work.leaseUntil);await store.heartbeat(r.id,next.epoch,work.leaseUntil);
    expect((await store.assign(r.id,next.epoch,work.leaseUntil))?.generation).toBe(2);
});
