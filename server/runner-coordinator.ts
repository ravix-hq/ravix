import type { Server, ServerWebSocket } from 'bun';
import type { AppContext } from './context';
import { authenticate, trackAccess, requireOwner } from './context';
import { cookieValue, SESSION_COOKIE, HttpError, json } from './http';
import { randomToken, sha256 } from './crypto';
import { RUNNER, parseRunnerCapabilities, type RunnerInfo, type RunnerWork } from '../shared/runners';
import type { NativeInfo, NativePlatform } from '../shared/native-preview';
import type { NativeRequest } from './runner-store';
export interface RunnerPeer {
    runnerControl: true;
    runnerId: string;
    epoch: number;
    count: number;
    period: number;
    hello: boolean;
    owned: {
        id: string;
        generation: number;
    } | null;
}
interface Engine {
    spawn(request: NativeRequest, pairHash: string): void;
    stop(id: string, reason?: string): Promise<void>;
    info(id: string): NativeInfo | null;
    busy(): boolean;
}
const terminal = (phase: string) => ['Failed', 'Stopped'].includes(phase);
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(v);
async function body(req: Request) {
    const chunks: Uint8Array[] = [];
    let size = 0;
    const reader = req.body?.getReader();
    if (reader)
        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done)
                    break;
                size += value.byteLength;
                if (size > 8192) {
                    await reader.cancel();
                    throw new HttpError(413, 'too_large');
                }
                chunks.push(value);
            }
        }
        finally {
            reader.releaseLock();
        }
    try {
        const v = JSON.parse(Buffer.concat(chunks).toString() || '{}');
        if (!v || typeof v !== 'object' || Array.isArray(v))
            throw Error();
        return v as Record<string, unknown>;
    }
    catch {
        throw new HttpError(400, 'invalid_json');
    }
}
/** Durable queue around the proven native engine; only the runner receives work credentials. */
export class RunnerCoordinator {
    private peers = new Map<string, ServerWebSocket<RunnerPeer>>();
    private ticking = false;
    constructor(private ctx: AppContext, private engine: Engine) { }
    start() { this.ctx.db.runners.recover(); }
    private enabled(projectId: string) { const p = this.ctx.db.project(projectId); return !!this.ctx.config.nativePreviewExperiment && !!this.ctx.sprites && !!this.ctx.fountain && p?.repoFullName === 'managoat/switchyard-expo-hello' && !p.archivedAt; }
    list(projectId: string): RunnerInfo[] { return this.ctx.db.runners.runners().filter(r => r.projects.includes(projectId)).map(r => ({ id: r.id, name: r.name, projects: [projectId], revoked: r.revoked, online: !r.revoked && this.peers.has(r.id) && Date.now() - r.lastSeen < RUNNER.leaseMs, capabilities: r.capabilities })); }
    authorized(s: NativeRequest) {
        const user = this.ctx.db.sessionUser(s.sessionHash), r = this.ctx.db.runners.runner(s.runnerId), track = this.ctx.db.track(s.trackId), project = this.ctx.db.project(s.projectId);
        return !!user && user.id === s.userId && !!r && !r.revoked && r.owner === s.userId && r.projects.includes(s.projectId) && !!track && !track.closedAt && track.workdir === s.workdir && !!project && !project.archivedAt && project.userId === s.userId && project.rev === s.projectRevision && project.agentId === s.agentId && this.enabled(project.id);
    }
    current(id: string, generation: number, epoch: number) { const s = this.ctx.db.runners.request(id), r = s && this.ctx.db.runners.runner(s.runnerId); return !!s && !!r && this.authorized(s) && s.desired === 'run' && s.generation === generation && s.epoch === epoch && r.epoch === epoch && s.leaseUntil > Date.now() && s.deadline > Date.now() && !['Queued', 'Reconciling', 'Stopping', 'Stopped', 'Failed'].includes(s.phase); }
    info(s: NativeRequest): NativeInfo {
        const actual = !['Queued', 'Reconciling'].includes(s.phase) ? this.engine.info(s.id) : null;
        return { id: s.id, trackId: s.trackId, platform: s.platform, phase: s.phase, error: s.error, expiresAt: s.deadline, runnerOnline: this.list(s.projectId).some(r => r.id === s.runnerId && r.online), video: actual?.video ?? null, frames: actual?.frames ?? 0, queuePosition: this.ctx.db.runners.position(s.id), runnerId: s.runnerId, generation: s.generation };
    }
    async pair(req: Request, trackId: string) {
        const user = await authenticate(this.ctx, req), { project, role } = trackAccess(this.ctx, user, trackId);
        requireOwner(role, 'register a native runner');
        if (req.headers.get('origin') !== this.ctx.config.publicUrl)
            throw new HttpError(403, 'origin');
        if (!this.enabled(project.id))
            throw new HttpError(501, 'native_unavailable');
        const code = randomToken();
        try {
            this.ctx.db.runners.pair(await sha256(code), user.id, [project.id]);
        }
        catch (e) {
            throw new HttpError(429, 'pairing_limit', String(e));
        }
        return json({ data: { code, expiresAt: Date.now() + RUNNER.pairingMs } }, 200, { 'cache-control': 'no-store' });
    }
    async register(req: Request) {
        if (!this.ctx.config.nativePreviewExperiment || req.headers.has('origin') || new URL(req.url).search)
            throw new HttpError(401, 'runner_auth');
        const v = await body(req);
        if (typeof v.code !== 'string' || !/^[\w-]{43}$/.test(v.code) || typeof v.name !== 'string' || !/^[\w .-]{1,80}$/.test(v.name))
            throw new HttpError(400, 'invalid_runner');
        let capabilities;
        try {
            capabilities = parseRunnerCapabilities(v.capabilities);
        }
        catch (e) {
            throw new HttpError(400, 'invalid_capabilities', String(e));
        }
        const token = randomToken();
        let runner;
        try {
            runner = this.ctx.db.runners.register(await sha256(v.code), await sha256(token), v.name, capabilities);
        }
        catch {
            throw new HttpError(401, 'pairing_expired', 'Create a fresh runner pairing code.');
        }
        if (!runner.projects.every(id => this.enabled(id) && this.ctx.db.project(id)?.userId === runner.owner)) {
            this.ctx.db.runners.revoke(runner.id);
            throw new HttpError(403, 'project_access_ended');
        }
        return json({ data: { id: runner.id, token, version: RUNNER.version } }, 200, { 'cache-control': 'no-store' });
    }
    async revoke(req: Request, id: string) {
        const user = await authenticate(this.ctx, req), r = this.ctx.db.runners.runner(id);
        if (!r || r.owner !== user.id)
            throw new HttpError(404, 'not_found');
        if (req.headers.get('origin') !== this.ctx.config.publicUrl)
            throw new HttpError(403, 'origin');
        this.ctx.db.runners.revoke(id);
        this.peers.get(id)?.close(1008, 'Runner revoked');
        await this.tick();
        return json({ data: { ok: true } });
    }
    enqueue(req: Request, trackId: string, platform: NativePlatform, requestId: string, runnerId?: string) {
        if (!uuid(requestId))
            throw new HttpError(400, 'request_id', 'A UUID request ID is required');
        const sessionHash = cookieValue(req, SESSION_COOKIE);
        if (!sessionHash)
            throw new HttpError(401, 'unauthenticated');
        return (async () => {
            const user = await authenticate(this.ctx, req), { track, project, role } = trackAccess(this.ctx, user, trackId);
            requireOwner(role, 'start a native preview');
            if (req.headers.get('origin') !== this.ctx.config.publicUrl)
                throw new HttpError(403, 'origin');
            if (!this.enabled(project.id) || track.closedAt)
                throw new HttpError(409, 'native_unavailable');
            if (runnerId !== undefined && !uuid(runnerId))
                throw new HttpError(400, 'invalid_runner');
            const runner = this.list(project.id).find(r => !r.revoked && (!runnerId || r.id === runnerId) && r.capabilities.builds.some(b => b.platform === platform));
            if (!runner)
                throw new HttpError(409, 'runner_unavailable', 'Register a runner supporting this platform first.');
            const expected = platform === 'ios' ? this.ctx.config.nativeHelloIosSha256 : '6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82';
            if (runner.capabilities.builds.find(b => b.platform === platform)?.artifactSha256 !== expected)
                throw new HttpError(409, 'build_required', 'This runner does not have the verified Hello build.');
            let s;
            try {
                s = this.ctx.db.runners.enqueue({ trackId, projectId: project.id, userId: user.id, sessionHash: await sha256(sessionHash), projectRevision: project.rev, agentId: project.agentId, workdir: track.workdir }, runner.id, platform, requestId);
            }
            catch (e) {
                throw new HttpError(409, 'native_busy', String(e));
            }
            void this.tick().catch(error => console.error('Native scheduler:', error));
            return this.info(s);
        })();
    }
    async stop(id: string) { this.ctx.db.runners.stop(id); await this.tick(); }
    async upgrade(req: Request, server: Server<RunnerPeer>) {
        const match = /^\/api\/native\/runners\/([a-f0-9-]{36})\/control$/.exec(new URL(req.url).pathname);
        if (!match || req.method !== 'GET' || req.headers.get('upgrade')?.toLowerCase() !== 'websocket' || req.headers.has('origin') || new URL(req.url).search || !this.ctx.config.nativePreviewExperiment)
            return new Response('Unauthorized', { status: 401 });
        const token = /^Bearer ([\w-]{43})$/.exec(req.headers.get('authorization') ?? '')?.[1], r = this.ctx.db.runners.runner(match[1]!);
        if (!token || !r || r.revoked || await sha256(token) !== r.tokenHash)
            return new Response('Unauthorized', { status: 401 });
        if (this.ctx.db.runners.runner(r.id)?.revoked)
            return new Response('Unauthorized', { status: 401 });
        if (server.upgrade(req, { data: { runnerControl: true, runnerId: r.id, epoch: 0, count: 0, period: Date.now(), hello: false, owned: null } }))
            return;
        return new Response('Upgrade failed', { status: 400 });
    }
    readonly websocket = {
        open: (ws: ServerWebSocket<RunnerPeer>) => {
            const prior = this.peers.get(ws.data.runnerId), r = this.ctx.db.runners.connect(ws.data.runnerId);
            ws.data.epoch = r.epoch;
            this.peers.set(r.id, ws);
            prior?.close(1008, 'Runner connection superseded');
            ws.send(JSON.stringify({ type: 'connected', version: RUNNER.version, epoch: r.epoch, heartbeatMs: RUNNER.heartbeatMs, leaseMs: RUNNER.leaseMs }));
        },
        message: (ws: ServerWebSocket<RunnerPeer>, data: string | Buffer) => {
            try {
                if (typeof data !== 'string' || data.length > 8192 || this.peers.get(ws.data.runnerId) !== ws)
                    throw Error('Invalid runner message');
                if (Date.now() - ws.data.period >= 60000) {
                    ws.data.count = 0;
                    ws.data.period = Date.now();
                }
                if (++ws.data.count > 120)
                    throw Error('Runner message rate exceeded');
                const v = JSON.parse(data);
                if (!this.ctx.db.runners.heartbeat(ws.data.runnerId, ws.data.epoch))
                    throw Error('Stale runner');
                if (v.type === 'hello' || v.type === 'heartbeat') {
                    if (v.owned !== null && (!v.owned || !uuid(v.owned.id) || !Number.isSafeInteger(v.owned.generation) || v.owned.generation < 1))
                        throw Error('Invalid owned job');
                    ws.data.hello = true;
                    ws.data.owned = v.owned;
                    if (v.owned) {
                        const s = this.ctx.db.runners.requests().find(s => s.jobId === v.owned.id);
                        if (!s || !this.authorized(s) || !this.ctx.db.runners.renew(s.id, ws.data.runnerId, ws.data.epoch, v.owned.generation))
                            ws.send(JSON.stringify({ type: 'cancel', id: v.owned.id, generation: v.owned.generation }));
                    }
                    ws.send(JSON.stringify({ type: 'heartbeat', epoch: ws.data.epoch, leaseMs: RUNNER.leaseMs }));
                }
                else if (v.type === 'complete') {
                    if (!uuid(v.sessionId) || !Number.isSafeInteger(v.generation) || v.cleanup !== 'complete' || (v.error !== null && typeof v.error !== 'string'))
                        throw Error('Invalid completion');
                    const accepted = this.ctx.db.runners.complete(v.sessionId, ws.data.runnerId, ws.data.epoch, v.generation, v.error?.slice(-2000) ?? null);
                    ws.send(JSON.stringify({ type: 'completed', sessionId: v.sessionId, generation: v.generation, accepted }));
                    if (accepted)
                        ws.data.owned = null;
                }
                else
                    throw Error('Unknown runner message');
                void this.tick().catch(error => console.error('Native scheduler:', error));
            }
            catch (e) {
                ws.close(1008, String(e).slice(0, 120));
            }
        },
        close: (ws: ServerWebSocket<RunnerPeer>) => { if (this.peers.get(ws.data.runnerId) === ws) {
            this.peers.delete(ws.data.runnerId);
            this.ctx.db.runners.disconnect(ws.data.runnerId, ws.data.epoch);
        } },
    };
    async tick() {
        if (this.ticking)
            return;
        this.ticking = true;
        try {
            for (const s of this.ctx.db.runners.requests()) {
                if (terminal(s.phase))
                    continue;
                if (!this.authorized(s))
                    this.ctx.db.runners.stop(s.id, 'Track or runner access ended');
                const current = this.ctx.db.runners.request(s.id)!;
                if (current.phase === 'Stopping' || current.phase === 'Reconciling' || (current.phase !== 'Queued' && current.leaseUntil <= Date.now()))
                    await this.engine.stop(s.id, current.error ?? (current.phase === 'Stopping' ? undefined : 'Runner assignment ended'));
                else if (current.phase !== 'Queued') {
                    const actual = this.engine.info(s.id);
                    if (actual && terminal(actual.phase))
                        this.ctx.db.runners.stop(s.id, actual.error);
                    else if (actual && actual.phase !== 'Awaiting runner') {
                        current.phase = actual.phase;
                        this.ctx.db.runners.save(current);
                    }
                }
            }
            this.ctx.db.runners.reconcile();
            if (this.engine.busy())
                return;
            for (const [id, ws] of this.peers) {
                if (!ws.data.hello || ws.data.owned)
                    continue;
                const s = this.ctx.db.runners.assign(id, ws.data.epoch);
                if (!s)
                    continue;
                const code = randomToken(), hash = await sha256(code);
                if (this.peers.get(id) !== ws || !this.current(s.id, s.generation, s.epoch))
                    continue;
                try {
                    this.engine.spawn(s, hash);
                }
                catch (error) {
                    this.ctx.db.runners.stop(s.id, String(error));
                    continue;
                }
                const work: RunnerWork = { id: s.jobId, sessionId: s.id, targetId: s.targetId, generation: s.generation, epoch: s.epoch, platform: s.platform, artifactSha256: s.artifactSha256, deadline: s.deadline, pairingCode: code };
                ws.data.owned = { id: work.id, generation: work.generation };
                ws.send(JSON.stringify({ type: 'work', work }));
                break;
            }
        }
        finally {
            this.ticking = false;
        }
    }
    shutdown() { for (const ws of this.peers.values())
        ws.close(1012, 'Server restarting'); this.peers.clear(); }
}
