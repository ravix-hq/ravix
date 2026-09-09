import type { Sql } from './sql';
import type { RunnerCapabilities } from '../shared/runners';
import { RUNNER } from '../shared/runners';
import type { NativePlatform } from '../shared/native-preview';
export interface RegisteredRunner {
    id: string;
    owner: string;
    name: string;
    tokenHash: string;
    projects: string[];
    capabilities: RunnerCapabilities;
    epoch: number;
    lastSeen: number;
    revoked: boolean;
}
export interface NativeRequest {
    id: string;
    jobId: string;
    targetId: string;
    runnerId: string;
    platform: NativePlatform;
    requestId: string;
    generation: number;
    epoch: number;
    phase: string;
    desired: 'run' | 'stop';
    leaseUntil: number;
    deadline: number;
    lastViewer: number;
    createdAt: number;
    error: string | null;
    artifactSha256: string;
    buildIdentity: string;
    trackId: string;
    projectId: string;
    userId: string;
    sessionHash: string;
    projectRevision: number;
    agentId: string;
    workdir: string;
}
type Context = Pick<NativeRequest, 'trackId' | 'projectId' | 'userId' | 'sessionHash' | 'projectRevision' | 'agentId' | 'workdir'>;
const terminal = (phase: string) => ['Stopped', 'Failed'].includes(phase);
/** Persisted intent and transactional capacity; socket objects never enter the database.
 *
 * Every read-modify-write here runs in a transaction. They were written when
 * the store was synchronous and nothing could interleave; the transaction
 * (serialised, see `sql.ts`) keeps that true now that they await. */
export class RunnerStore {
    constructor(private db: Sql) {}
    async init() {
        await this.db.exec(`CREATE TABLE IF NOT EXISTS native_runner_pairings (hash TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id), projects TEXT NOT NULL, expires BIGINT NOT NULL);
      CREATE TABLE IF NOT EXISTS native_runners (id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id), token_hash TEXT NOT NULL UNIQUE, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS native_targets (id TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES tracks(id), platform TEXT NOT NULL, runner_id TEXT NOT NULL REFERENCES native_runners(id), UNIQUE(track_id, platform));
      CREATE TABLE IF NOT EXISTS native_requests (seq INTEGER GENERATED ALWAYS AS IDENTITY, id TEXT PRIMARY KEY, target_id TEXT NOT NULL REFERENCES native_targets(id), runner_id TEXT NOT NULL REFERENCES native_runners(id), request_id TEXT NOT NULL, record TEXT NOT NULL, UNIQUE(target_id, request_id));`);
    }
    pair(hash: string, owner: string, projects: string[], now = Date.now()) {
        return this.db.transaction(async () => {
            await this.db.run('DELETE FROM native_runner_pairings WHERE expires <= $1', [now]);
            const [pending] = await this.db.query<{ n: number }>('SELECT COUNT(*) AS n FROM native_runner_pairings WHERE owner=$1', [owner]);
            if ((pending?.n ?? 0) >= 5)
                throw Error('Five pairings are already pending');
            await this.db.run('INSERT INTO native_runner_pairings VALUES ($1,$2,$3,$4)', [hash, owner, JSON.stringify(projects), now + RUNNER.pairingMs]);
        });
    }
    register(pairHash: string, tokenHash: string, name: string, capabilities: RunnerCapabilities, now = Date.now()) {
        return this.db.transaction(async () => {
            const [pair] = await this.db.query<{ owner: string; projects: string; expires: number }>('SELECT * FROM native_runner_pairings WHERE hash=$1', [pairHash]);
            if (!pair || pair.expires <= now)
                throw Error('Pairing expired or already consumed');
            if ((await this.runners()).filter(r => r.owner === pair.owner && !r.revoked).length >= 8)
                throw Error('Eight runners are already registered');
            const runner: RegisteredRunner = { id: crypto.randomUUID(), owner: pair.owner, name, tokenHash, projects: JSON.parse(pair.projects), capabilities, epoch: 0, lastSeen: 0, revoked: false };
            await this.db.run('INSERT INTO native_runners VALUES ($1,$2,$3,$4)', [runner.id, runner.owner, tokenHash, JSON.stringify(runner)]);
            await this.db.run('DELETE FROM native_runner_pairings WHERE hash=$1', [pairHash]);
            return runner;
        });
    }
    async runners(): Promise<RegisteredRunner[]> { return (await this.db.query<{ record: string }>('SELECT record FROM native_runners')).map(r => JSON.parse(r.record)); }
    async runner(id: string): Promise<RegisteredRunner | null> { const [row] = await this.db.query<{ record: string }>('SELECT record FROM native_runners WHERE id=$1', [id]); return row ? JSON.parse(row.record) as RegisteredRunner : null; }
    private async saveRunner(r: RegisteredRunner) { await this.db.run('UPDATE native_runners SET record=$1 WHERE id=$2', [JSON.stringify(r), r.id]); }
    async requests(): Promise<NativeRequest[]> { return (await this.db.query<{ record: string }>('SELECT record FROM native_requests ORDER BY seq')).map(r => JSON.parse(r.record)); }
    async request(id: string): Promise<NativeRequest | null> { const [row] = await this.db.query<{ record: string }>('SELECT record FROM native_requests WHERE id=$1', [id]); return row ? JSON.parse(row.record) as NativeRequest : null; }
    async save(s: NativeRequest) { await this.db.run('UPDATE native_requests SET record=$1 WHERE id=$2', [JSON.stringify(s), s.id]); }
    async current(trackId: string) { return (await this.requests()).filter(s => s.trackId === trackId).at(-1) ?? null; }
    connect(id: string, now = Date.now()) {
        return this.db.transaction(async () => {
            const r = await this.runner(id);
            if (!r || r.revoked)
                throw Error('Runner revoked');
            r.epoch++;
            r.lastSeen = now;
            await this.saveRunner(r);
            for (const s of (await this.requests()).filter(s => s.runnerId === id && !terminal(s.phase) && s.phase !== 'Queued')) {
                s.phase = 'Reconciling';
                await this.save(s);
            }
            return r;
        });
    }
    disconnect(id: string, epoch: number) {
        return this.db.transaction(async () => {
            const r = await this.runner(id);
            if (!r || r.epoch !== epoch)
                return;
            r.lastSeen = 0;
            await this.saveRunner(r);
            for (const s of await this.requests())
                if (s.runnerId === id && !terminal(s.phase) && s.phase !== 'Queued') {
                    s.phase = 'Reconciling';
                    await this.save(s);
                }
        });
    }
    heartbeat(id: string, epoch: number, now = Date.now()) {
        return this.db.transaction(async () => {
            const r = await this.runner(id);
            if (!r || r.revoked || r.epoch !== epoch)
                return false;
            r.lastSeen = now;
            await this.saveRunner(r);
            return true;
        });
    }
    revoke(id: string) {
        return this.db.transaction(async () => {
            const r = await this.runner(id);
            if (!r)
                return;
            r.revoked = true;
            r.epoch++;
            await this.saveRunner(r);
            for (const s of (await this.requests()).filter(s => s.runnerId === id && !terminal(s.phase)))
                await this.stop(s.id, 'Runner revoked');
        });
    }
    enqueue(context: Context, runnerId: string, platform: NativePlatform, requestId: string, now = Date.now()) {
        return this.db.transaction(async () => {
            const runner = await this.runner(runnerId), build = runner?.capabilities.builds.find(b => b.platform === platform);
            if (!runner || runner.revoked || runner.owner !== context.userId || !runner.projects.includes(context.projectId) || !build)
                throw Error('Runner unavailable for this project and platform');
            let [target] = await this.db.query<{ id: string; runner_id: string }>('SELECT id, runner_id FROM native_targets WHERE track_id=$1 AND platform=$2', [context.trackId, platform]);
            if (!target) {
                target = { id: crypto.randomUUID(), runner_id: runnerId };
                await this.db.run('INSERT INTO native_targets VALUES ($1,$2,$3,$4)', [target.id, context.trackId, platform, runnerId]);
            }
            if (target.runner_id !== runnerId)
                throw Error('This target belongs to another runner; restore that runner before resuming');
            const requests = await this.requests(), duplicate = requests.find(s => s.targetId === target!.id && s.requestId === requestId);
            if (duplicate)
                return duplicate;
            const active = requests.find(s => s.trackId === context.trackId && !terminal(s.phase));
            if (active)
                throw Error('This target already has an active request');
            if (requests.filter(s => s.runnerId === runnerId && !terminal(s.phase)).length >= RUNNER.queueLimit)
                throw Error('Runner queue is full');
            if (requests.filter(s => s.projectId === context.projectId).length >= 1000)
                throw Error('Native request history reached its project limit; review retained evidence before continuing');
            const s: NativeRequest = { ...context, id: crypto.randomUUID(), jobId: crypto.randomUUID(), targetId: target.id, runnerId, platform, requestId, generation: 0, epoch: 0, phase: 'Queued', desired: 'run', leaseUntil: 0, deadline: now + 30 * 60000, lastViewer: now, createdAt: now, error: null, artifactSha256: build.artifactSha256, buildIdentity: JSON.stringify(build) };
            await this.db.run('INSERT INTO native_requests (id, target_id, runner_id, request_id, record) VALUES ($1,$2,$3,$4,$5)', [s.id, s.targetId, runnerId, requestId, JSON.stringify(s)]);
            return s;
        });
    }
    assign(runnerId: string, epoch: number, now = Date.now()) {
        return this.db.transaction(async () => {
            const r = await this.runner(runnerId);
            if (!r || r.revoked || r.epoch !== epoch || now - r.lastSeen >= RUNNER.leaseMs)
                return null;
            const requests = (await this.requests()).filter(s => s.runnerId === runnerId && !terminal(s.phase));
            if (requests.some(s => s.phase !== 'Queued'))
                return null;
            const s = requests.find(s => s.desired === 'run' && s.deadline > now);
            if (!s)
                return null;
            s.phase = 'Assigned';
            s.generation++;
            s.epoch = epoch;
            s.leaseUntil = now + RUNNER.leaseMs;
            await this.save(s);
            return s;
        });
    }
    renew(id: string, runnerId: string, epoch: number, generation: number, now = Date.now()) {
        return this.db.transaction(async () => {
            const s = await this.request(id), r = await this.runner(runnerId);
            if (!s || !r || r.revoked || r.epoch !== epoch || s.runnerId !== runnerId || s.epoch !== epoch || s.generation !== generation || s.desired !== 'run' || s.leaseUntil <= now || s.deadline <= now || ['Queued', 'Reconciling', 'Stopping', 'Stopped', 'Failed'].includes(s.phase))
                return false;
            s.leaseUntil = Math.min(now + RUNNER.leaseMs, s.deadline);
            await this.save(s);
            return true;
        });
    }
    stop(id: string, error: string | null = null) {
        return this.db.transaction(async () => {
            const s = await this.request(id);
            if (!s || terminal(s.phase))
                return;
            s.desired = 'stop';
            s.error = error;
            if (s.phase === 'Queued')
                s.phase = error ? 'Failed' : 'Stopped';
            else
                s.phase = 'Stopping';
            await this.save(s);
        });
    }
    complete(id: string, runnerId: string, epoch: number, generation: number, error: string | null) {
        return this.db.transaction(async () => {
            const s = await this.request(id), r = await this.runner(runnerId);
            if (!s || !r || r.revoked || r.epoch !== epoch || s.epoch !== epoch || s.runnerId !== runnerId || s.generation !== generation || terminal(s.phase))
                return false;
            s.error ??= error;
            s.desired = 'stop';
            s.phase = s.error ? 'Failed' : 'Stopped';
            s.leaseUntil = 0;
            await this.save(s);
            return true;
        });
    }
    recover(now = Date.now()) {
        return this.db.transaction(async () => {
            for (const s of await this.requests())
                if (!terminal(s.phase) && s.phase !== 'Queued') {
                    s.phase = 'Reconciling';
                    s.leaseUntil = Math.min(s.leaseUntil, now + RUNNER.leaseMs);
                    await this.save(s);
                }
            for (const r of await this.runners()) {
                r.lastSeen = 0;
                await this.saveRunner(r);
            }
        });
    }
    reconcile(now = Date.now()) {
        return this.db.transaction(async () => {
            for (const s of await this.requests()) {
                if (terminal(s.phase))
                    continue;
                if (s.deadline <= now || now - s.lastViewer > 5 * 60000)
                    await this.stop(s.id, s.deadline <= now ? 'Session deadline reached' : 'Preview idle');
                const current = (await this.request(s.id))!;
                if (current.phase !== 'Queued' && current.leaseUntil <= now) {
                    current.phase = current.desired === 'run' ? 'Queued' : current.error ? 'Failed' : 'Stopped';
                    current.leaseUntil = 0;
                    await this.save(current);
                }
            }
        });
    }
    touch(id: string, now = Date.now()) {
        return this.db.transaction(async () => {
            const s = await this.request(id);
            if (s && !terminal(s.phase)) {
                s.lastViewer = now;
                await this.save(s);
            }
        });
    }
    async position(id: string) { const s = await this.request(id); return !s || s.phase !== 'Queued' ? null : (await this.requests()).filter(r => r.runnerId === s.runnerId && r.phase === 'Queued').findIndex(r => r.id === id) + 1; }
}
