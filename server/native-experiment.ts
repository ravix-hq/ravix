import type { Server, ServerWebSocket } from 'bun';
import type { AppContext } from './context';
import { authenticate, requireOwner, trackAccess } from './context';
import { cookieValue, SESSION_COOKIE, errorResponse, HttpError } from './http';
import { randomToken, sha256 } from './crypto';
import { machineOf, spriteFor } from './tracks';
import { spriteTunnel, previewClient } from './sprites-tunnel';
import { createNativeForwardGateway, type NativeForwardPeer } from './native-forward-gateway';
import { RunnerCoordinator, type RunnerPeer } from './runner-coordinator';
import type { NativeRequest } from './runner-store';
import type { NativeServiceReservation } from './native-experiment-store';
import { NATIVE, nativeFrame, parseNativeInput, type NativeInfo, type NativePlatform, type NativeVideo } from '../shared/native-preview';
import loopbackSource from '../runner/scripts/metro-loopback.cjs' with { type: 'text' };
const FIXTURE = 'managoat/switchyard-expo-hello';
const NATIVE_HASHES = {
    'assets/adaptive-icon.png': '5f4c0a732b6325bf4071d9124d2ae67e037cb24fcc9c482ef82bea742109a3b8',
    'assets/icon.png': '74c64047eb557b1341bba7a2831eedde9ddb705e6451a9ad9f5552bf558f13de',
    'assets/splash-icon.png': '5f4c0a732b6325bf4071d9124d2ae67e037cb24fcc9c482ef82bea742109a3b8',
    'app.json': 'b31d9e75385ef28f8e165f34fd785eb4bbce32f35e6f3c7eb73777c0e44de112',
    'package.json': '8803aec50376c488f48473fc275f4c14e40daac38928c00ae2a8ddc398ecca19',
    'package-lock.json': 'f6b006e3c5d6271b6bbd9c0b81e84ed11f5f4c3d2c5b783e6fa41e2766d2e5ac',
};
const APK_SHA = '6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82';
async function nativeBody(req: Request, empty = false): Promise<Record<string, unknown>> {
    const reader = req.body?.getReader(), chunks: Uint8Array[] = [];
    let size = 0;
    if (reader) {
        try {
            while (true) {
                const {done, value} = await reader.read();
                if (done) break;
                size += value.byteLength;
                if (size > 1024) { await reader.cancel(); throw new HttpError(413, 'too_large'); }
                chunks.push(value);
            }
        } finally { reader.releaseLock(); }
    }
    if (!size && empty) return {};
    let value: unknown;
    try { value = JSON.parse(Buffer.concat(chunks).toString()); }
    catch { throw new HttpError(400, 'invalid_json'); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new HttpError(400, 'invalid_json');
    return value as Record<string, unknown>;
}
const managers = new WeakMap<AppContext, NativeExperiments>();
export function nativeExperiments(ctx: AppContext) { let m = managers.get(ctx); if (!m) {
    m = new NativeExperiments(ctx);
    managers.set(ctx, m);
} return m; }
interface Session {
    managed?: {generation: number; epoch: number};
    platform: NativePlatform;
    artifactSha256: string;
    metroPort: number;
    backendPort: number;
    id: string;
    trackId: string;
    userId: string;
    sessionHash: string;
    projectId: string;
    projectRevision: number;
    workdir: string;
    agentId: string;
    pairHash: string | null;
    pairUntil: number;
    tokenHash: string | null;
    expiresAt: number;
    leaseUntil: number;
    lastViewer: number;
    phase: string;
    error: string | null;
    cleanupError?: string;
    controller: AbortController;
    reservation?: NativeServiceReservation;
    pending?: Promise<void>;
    runner?: ServerWebSocket<NativePeer>;
    producer?: ServerWebSocket<NativePeer>;
    viewers: Set<ServerWebSocket<NativePeer>>;
    input?: ServerWebSocket<NativePeer>;
    video: NativeVideo | null;
    config?: Buffer;
    frames: number;
    lastFrame: number;
    appReady: boolean;
    stopping?: Promise<void>;
    lastCheck: number;
    checking?: Promise<void>;
}
interface NativePeer {
    role: 'runner' | 'video' | 'view' | 'input';
    session: Session;
    userId?: string;
    sessionHash?: string;
    waiting: boolean;
    count: number;
    period: number;
}
export type NativeSocketData = NativePeer | NativeForwardPeer | RunnerPeer;
const serviceName = (id: string, kind: string) => `sy-native-${id}-${kind}`;
const quote = (s: string) => "'" + s.replaceAll("'", "'\\''") + "'";
/** Opt-in gate-2 fixture: one active native experiment, no durable runner
 * registration. Each claim is single-use and ends on disconnect or lease loss. */
export class NativeExperiments {
    fetch(req: Request, server: Server<NativeSocketData>) {
        const path = new URL(req.url).pathname;
        if (path.startsWith('/api/native/runners/')) return this.coordinator.upgrade(req, server as unknown as Server<RunnerPeer>);
        if (/^\/api\/native\/sessions\/[^/]+\/forward\//.test(path))
            return this.forward.fetch(req, server as unknown as Server<NativeForwardPeer>);
        return this.upgrade(req, server as unknown as Server<NativePeer>);
    }
    readonly websocket = {
        maxPayloadLength: NATIVE.frameBytes + 12,
        backpressureLimit: 1024 * 1024,
        closeOnBackpressureLimit: true,
        idleTimeout: 60,
        open: (ws: ServerWebSocket<NativeSocketData>) => { if ('runnerControl' in ws.data) this.coordinator.websocket.open(ws as ServerWebSocket<RunnerPeer>);
        else if ('assignment' in ws.data)
            this.forward.websocket.open(ws as ServerWebSocket<NativeForwardPeer>);
        else
            this.channels.open(ws as ServerWebSocket<NativePeer>); },
        message: (ws: ServerWebSocket<NativeSocketData>, data: string | Buffer) => { if ('runnerControl' in ws.data) this.coordinator.websocket.message(ws as ServerWebSocket<RunnerPeer>, data);
        else if ('assignment' in ws.data)
            this.forward.websocket.message(ws as ServerWebSocket<NativeForwardPeer>, data);
        else
            this.channels.message(ws as ServerWebSocket<NativePeer>, data); },
        close: (ws: ServerWebSocket<NativeSocketData>) => { if ('runnerControl' in ws.data) this.coordinator.websocket.close(ws as ServerWebSocket<RunnerPeer>);
        else if ('assignment' in ws.data)
            this.forward.websocket.close(ws as ServerWebSocket<NativeForwardPeer>);
        else
            this.channels.close(ws as ServerWebSocket<NativePeer>); },
    };
    private sessions = new Map<string, Session>();
    private timer?: ReturnType<typeof setInterval>;
    private recovering = false;
    private stopped = false;
    private recoveryTask?: Promise<unknown>;
    private lastRecovery = 0;
    readonly forward;
    readonly coordinator: RunnerCoordinator;
    constructor(private ctx: AppContext) {
        this.coordinator = new RunnerCoordinator(ctx, {
            spawn: (request, pairHash) => this.spawnManaged(request, pairHash),
            stop: async (id, reason) => { const s = this.sessions.get(id); if (s) { if(s.cleanupError && Date.now()-s.lastCheck<15000)return; s.lastCheck=Date.now(); await this.stopSession(s, reason); } },
            info: id => { const s = this.sessions.get(id); return s ? this.info(s) : null; },
            busy: () => this.stopped || this.recovering || this.ctx.db.nativeExperiments.all().length > 0 || [...this.sessions.values()].some(s => this.live(s)),
        });
        this.forward = createNativeForwardGateway(async (req) => {
            const match = /^\/api\/native\/sessions\/([a-f0-9-]{36})\/forward\/(metro|backend)$/.exec(new URL(req.url).pathname);
            if (!match)
                return null;
            const s = await this.runnerSession(req, match[1]!);
            if (!s?.reservation || !s.runner || !this.live(s) || !['Connecting', 'Ready'].includes(s.phase))
                return null;
            const r = s.reservation, port = match[2] === 'metro' ? r.metro : r.backend;
            return { signal: s.controller.signal, connect: async () => {
                    if (!this.live(s))
                        throw new Error('Session ended');
                    const project = this.ctx.db.project(s.projectId)!;
                    const machine = await machineOf(this.ctx.fountain!, project);
                    if (!this.live(s) || !machine || await spriteFor(this.ctx.fountain!, machine.sandboxId) !== r.sprite) {
                        void this.stopSession(s, 'Workspace replaced');
                        throw new Error('Workspace replaced');
                    }
                    return spriteTunnel(this.ctx.config.sprites!, r.sprite, port, s.controller.signal);
                } };
        });
    }
    start() {
        if (this.timer || !this.ctx.config.nativePreviewExperiment)
            return;
        this.coordinator.start();
        this.recovering = true;
        const recover = () => {
            this.lastRecovery = Date.now();
            this.recoveryTask = Promise.allSettled(this.ctx.db.nativeExperiments.all().map(r => this.retire(r))).then(() => { this.recovering = this.ctx.db.nativeExperiments.all().length > 0; }).finally(() => { this.recoveryTask = undefined; });
        };
        recover();
        this.timer = setInterval(() => {
            void this.coordinator.tick().catch(error => console.error('Native scheduler:', error));
            if (this.recovering && !this.recoveryTask && Date.now() - this.lastRecovery >= 15000) recover();
            for (const s of this.sessions.values()) {
                if (!this.live(s)) {
                    if (!s.controller.signal.aborted || (!s.stopping && Date.now() - s.lastCheck >= 15000)) {
                        s.lastCheck = Date.now();
                        void this.stopSession(s, s.error ?? 'Session lease or access ended');
                    }
                    continue;
                }
                for (const ws of [...s.viewers, ...(s.input ? [s.input] : [])])
                    if (!this.viewerLive(ws.data))
                        ws.close(1008, 'Access ended');
                if (Date.now() - s.lastViewer > 5 * 60000) {
                    void this.stopSession(s, 'Preview idle');
                    continue;
                }
                if (s.runner && Date.now() - s.lastCheck > 15000 && !s.checking && s.reservation && ['Connecting', 'Ready'].includes(s.phase)) {
                    s.lastCheck = Date.now();
                    s.checking = this.checkWorkspace(s).catch(error => { void this.stopSession(s, String(error)); }).finally(() => { s.checking = undefined; });
                }
                // scrcpy is damage-driven: a healthy static screen may emit no
                // frames. Producer disconnect and the runner lease fence liveness.
            }
        }, 1000);
        this.timer.unref();
    }
    async stop() {
        this.stopped = true;
        this.coordinator.shutdown();
        if (this.timer) clearInterval(this.timer);
        this.forward.stop();
        await this.recoveryTask;
        await Promise.all([...this.sessions.values()].map(s => this.stopSession(s, 'Server stopped')));
    }
    private live(s: Session) {
        if (this.stopped || s.controller.signal.aborted || s.expiresAt <= Date.now() || s.leaseUntil <= Date.now())
            return false;
        if (s.managed && !this.coordinator.current(s.id, s.managed.generation, s.managed.epoch)) return false;
        const user = this.ctx.db.sessionUser(s.sessionHash), track = this.ctx.db.track(s.trackId), project = this.ctx.db.project(s.projectId);
        return !!user && user.id === s.userId && !!track && !track.closedAt && track.workdir === s.workdir &&
            !!project && !project.archivedAt && project.userId === user.id && project.rev === s.projectRevision && project.agentId === s.agentId;
    }
    private viewerLive(p: NativePeer) {
        if (!this.live(p.session) || !p.sessionHash || !p.userId)
            return false;
        try {
            const user = this.ctx.db.sessionUser(p.sessionHash);
            if (!user || user.id !== p.userId)
                return false;
            return !trackAccess(this.ctx, user, p.session.trackId).track.closedAt;
        }
        catch {
            return false;
        }
    }
    private info(s: Session): NativeInfo { return { id: s.id, platform: s.platform, trackId: s.trackId, phase: s.phase, error: s.cleanupError ? [s.error, `Cleanup pending: ${s.cleanupError}`].filter(Boolean).join('\n') : s.error, expiresAt: s.expiresAt, runnerOnline: !!s.runner && this.live(s), video: s.video, frames: s.frames }; }
    private async runnerSession(req: Request, id: string) {
        if (req.headers.has('origin') || new URL(req.url).search)
            return null;
        const token = /^Bearer ([a-zA-Z0-9_-]{32,256})$/.exec(req.headers.get('authorization') ?? '')?.[1];
        const s = this.sessions.get(id);
        return token && s?.tokenHash && await sha256(token) === s.tokenHash && this.live(s) ? s : null;
    }
    async route(req: Request, trackId: string, action = ''): Promise<Response> {
        const user = await authenticate(this.ctx, req), { track, project, role } = trackAccess(this.ctx, user, trackId);
        if (track.closedAt)
            throw new HttpError(409, 'closed', 'This track is closed.');
        const available = !!this.ctx.config.nativePreviewExperiment && !!this.ctx.fountain && !!this.ctx.sprites && project.repoFullName === FIXTURE;
        const current = [...this.sessions.values()].reverse().find(s => s.trackId === trackId);
        const durable = this.ctx.db.runners.current(trackId);
        if (req.method === 'GET') {
            if (durable) this.ctx.db.runners.touch(durable.id);
            if (current && this.live(current))
                current.lastViewer = Date.now();
            return Response.json({ data: { available, platforms: this.ctx.config.nativeHelloIosSha256 ? ['android', 'ios'] : ['android'], runners: this.coordinator.list(project.id), session: durable ? this.coordinator.info(durable) : current ? this.info(current) : null } }, { headers: { 'cache-control': 'no-store' } });
        }
        if (req.headers.get('origin') !== this.ctx.config.publicUrl)
            throw new HttpError(403, 'origin', 'Open this action in Switchyard.');
        requireOwner(role, 'start or stop this native experiment');
        if (!available)
            throw new HttpError(501, 'native_unavailable', 'Native experiments are not enabled for this project.');
        if (action === 'runner-pair') return this.coordinator.pair(req, trackId);
        if (action === 'stop') {
            if (durable) await this.coordinator.stop(durable.id);
            if (current)
                await this.stopSession(current);
            return Response.json({ data: { ok: true } });
        }
        if (action !== 'start')
            throw new HttpError(404, 'not_found');
        const body = await nativeBody(req, true);
        const platform = body.platform ?? 'android';
        if (platform !== 'android' && platform !== 'ios') throw new HttpError(400, 'platform', 'Choose Android or iOS.');
        if (this.coordinator.list(project.id).length) {
            const info = await this.coordinator.enqueue(req, trackId, platform, body.requestId as string, body.runnerId as string | undefined);
            return Response.json({data: info}, {headers: {'cache-control': 'no-store'}});
        }
        if (this.recovering || this.ctx.db.nativeExperiments.all().length || [...this.sessions.values()].some(s => this.live(s)))
            throw new HttpError(409, 'native_busy', 'The experiment runner is occupied or still cleaning up. Stop it before starting another.');
        if (this.sessions.size >= 10)
            this.sessions.delete(this.sessions.keys().next().value!);
        const artifactSha256 = platform === 'ios' ? this.ctx.config.nativeHelloIosSha256 : APK_SHA;
        if (!artifactSha256) throw new HttpError(409, 'ios_unavailable', 'The iOS Hello build has not been verified yet.');
        const code = randomToken(), now = Date.now();
        const s: Session = { platform, artifactSha256, metroPort: NATIVE.metroPort, backendPort: NATIVE.backendPort, id: crypto.randomUUID(), trackId, userId: user.id, sessionHash: await sha256(cookieValue(req, SESSION_COOKIE)!), projectId: project.id, projectRevision: project.rev, workdir: track.workdir, agentId: project.agentId,
            pairHash: await sha256(code), pairUntil: now + 5 * 60000, tokenHash: null, expiresAt: now + NATIVE.lifetimeMs, leaseUntil: now + 5 * 60000, lastViewer: now,
            phase: 'Awaiting runner', error: null, controller: new AbortController(), viewers: new Set(), video: null, frames: 0, lastFrame: 0, appReady: false, lastCheck: 0 };
        // Hashing yields. Recheck capacity and account access before publishing.
        if (!this.live(s) || [...this.sessions.values()].some(s => this.live(s)))
            throw new HttpError(409, 'native_busy', 'Native experiment unavailable.');
        this.sessions.set(s.id, s);
        return Response.json({ data: { ...this.info(s), pairingCode: code } }, { headers: { 'cache-control': 'no-store' } });
    }
    private spawnManaged(request: NativeRequest, pairHash: string) {
        for (const [id, s] of this.sessions) if (s.controller.signal.aborted && !s.cleanupError) this.sessions.delete(id);
        const now = Date.now();
        const s: Session = {...request, managed: {generation: request.generation, epoch: request.epoch},
            metroPort: NATIVE.metroPort, backendPort: NATIVE.backendPort, pairHash, pairUntil: request.leaseUntil,
            tokenHash: null, expiresAt: request.deadline, leaseUntil: request.leaseUntil, lastViewer: now,
            phase: 'Awaiting runner', error: null, controller: new AbortController(), viewers: new Set(),
            video: null, frames: 0, lastFrame: 0, appReady: false, lastCheck: 0};
        this.sessions.set(s.id, s);
    }
    async show(req: Request, id: string) {
        const durable = this.ctx.db.runners.request(id);
        if (durable) {
            const user = await authenticate(this.ctx, req), {track} = trackAccess(this.ctx, user, durable.trackId);
            if (track.closedAt) throw new HttpError(404, 'not_found');
            this.ctx.db.runners.touch(id);
            const live = this.sessions.get(id); if (live) live.lastViewer = Date.now();
            return Response.json({data: {...this.coordinator.info(durable), trackUrl: `/p/${durable.projectId}/t/${durable.trackId}`}}, {headers: {'cache-control': 'no-store'}});
        }
        const user = await authenticate(this.ctx, req), s = this.sessions.get(id);
        if (!s)
            throw new HttpError(404, 'not_found', 'This experiment has ended. Start it again from the track.');
        const { track } = trackAccess(this.ctx, user, s.trackId);
        if (track.closedAt)
            throw new HttpError(404, 'not_found');
        if (this.live(s))
            s.lastViewer = Date.now();
        return Response.json({ data: { ...this.info(s), trackUrl: `/p/${s.projectId}/t/${s.trackId}` } }, { headers: { 'cache-control': 'no-store' } });
    }
    async claim(req: Request) {
        if (!this.ctx.config.nativePreviewExperiment || req.method !== 'POST' || req.headers.has('origin') || new URL(req.url).search)
            throw new HttpError(401, 'unauthorized');
        const value = await nativeBody(req);
        if (typeof value.code !== 'string' || !/^[\w-]{43}$/.test(value.code) )
            throw new HttpError(401, 'unauthorized', 'Pairing requires the verified Hello build.');
        const hash = await sha256(value.code), s = [...this.sessions.values()].find(s => s.pairHash === hash && s.pairUntil > Date.now() && this.live(s));
        if (!s || value.artifactSha256 !== s.artifactSha256 || (value.platform ?? 'android') !== s.platform)
            throw new HttpError(401, 'unauthorized');
        const metroPort = value.metroPort === undefined ? NATIVE.metroPort : value.metroPort, backendPort = value.backendPort === undefined ? NATIVE.backendPort : value.backendPort;
        if ((value.metroPort === undefined) !== (value.backendPort === undefined) || ![metroPort,backendPort].every(port => typeof port === 'number' && Number.isInteger(port) && port >= 1024 && port <= 65535) || metroPort === backendPort)
            throw new HttpError(400, 'invalid_ports', 'Choose two distinct, reserved loopback ports.');
        s.metroPort = metroPort as number; s.backendPort = backendPort as number;
        s.pairHash = null; // Consume synchronously before the next await.
        const token = randomToken();
        s.tokenHash = await sha256(token);
        s.leaseUntil = Date.now() + NATIVE.leaseMs;
        s.phase = 'Preparing';
        s.pending = this.prepare(s);
        void s.pending.catch(error => { void this.stopSession(s, error instanceof Error ? error.message : String(error)); });
        return Response.json({ data: { id: s.id, platform: s.platform, token, leaseMs: NATIVE.leaseMs, expiresAt: s.expiresAt, metroPort: s.metroPort, backendPort: s.backendPort } }, { headers: { 'cache-control': 'no-store' } });
    }
    private assert(s: Session) { if (!this.live(s))
        throw new Error('Native session ended'); }
    private async exec(s: Session, code: string, args: string[] = [], seconds = 30) {
        this.assert(s);
        const result = await this.ctx.sprites!.exec(s.reservation!.sprite, ['node', '-e', code, s.workdir, ...args], seconds);
        this.assert(s);
        if (result.code)
            throw new Error((result.stderr || result.stdout || 'Workspace command failed').slice(-2000));
        return result.stdout;
    }
    private async checkWorkspace(s: Session) {
        const machine = await machineOf(this.ctx.fountain!, this.ctx.db.project(s.projectId)!);
        this.assert(s);
        if (!machine || await spriteFor(this.ctx.fountain!, machine.sandboxId) !== s.reservation!.sprite) throw new Error('Workspace replaced');
        await this.exec(s, `const fs=require('node:fs'),crypto=require('node:crypto');process.chdir(process.argv[1]);for(const name of ['app.config.js','app.config.ts','app.config.cjs','app.config.mjs','android','ios']) {if(fs.existsSync(name))throw Error('Native configuration changed: '+name+'. Rebuild required.');}for(const [name,hash] of Object.entries(JSON.parse(process.argv[2]))) {const stat=fs.lstatSync(name);if(!stat.isFile()||stat.size>8*1024*1024)throw Error('Invalid native input: '+name);if(crypto.createHash('sha256').update(fs.readFileSync(name)).digest('hex')!==hash)throw Error('Native configuration changed: '+name+'. Rebuild required.');}`, [JSON.stringify(NATIVE_HASHES)]);
        const r = s.reservation!;
        for (const kind of ['metro', 'backend']) {
            this.assert(s);
            await this.ctx.sprites!.activity(r.sprite, serviceName(s.id, kind));
        }
    }
    private async prepare(s: Session) {
        const project = this.ctx.db.project(s.projectId)!;
        const machine = await machineOf(this.ctx.fountain!, project);
        this.assert(s);
        if (!machine)
            throw new Error('No Sprite workspace; open the track first');
        const sprite = await spriteFor(this.ctx.fountain!, machine.sandboxId);
        this.assert(s);
        if (!sprite)
            throw new Error('Workspace is not a Sprite');
        s.reservation = this.ctx.db.nativeExperiments.allocate(s.id, s.trackId, sprite);
        await this.checkWorkspace(s);
        const preload = `/tmp/switchyard-native-${s.id}.cjs`;
        await this.exec(s, `const fs=require('node:fs');fs.writeFileSync(process.argv[2],Buffer.from(process.argv[3],'base64'),{mode:0o600,flag:'wx'});`, [preload, Buffer.from(loopbackSource).toString('base64')]);
        // Start dependency installation as a bounded managed service too: it can
        // be stopped after server loss and never blocks heartbeat/input handling.
        const r = s.reservation;
        const installName = serviceName(s.id, 'install');
        const installStatus = `/tmp/switchyard-native-${s.id}.install`;
        await this.ctx.sprites!.defineService(sprite, installName, s.workdir, `npm ci --no-audit --no-fund; status=$?; printf '%s' "$status" > ${quote(installStatus)}; exec sleep 1800`, r.metro);
        this.assert(s);
        const installDeadline = Date.now() + 10 * 60000;
        while (true) {
            this.assert(s);
            const install = await this.ctx.sprites!.service(sprite, installName);
            const status = (await this.exec(s, `const fs=require('node:fs');try{process.stdout.write(fs.readFileSync(process.argv[2],'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}`, [installStatus])).trim();
            if (status === '0')
                break;
            if (status || (install?.state?.restart_count ?? 0) > 0 || Date.now() > installDeadline)
                throw new Error('Dependency installation failed: ' + await this.ctx.sprites!.serviceLogs(sprite, installName));
            await this.ctx.sprites!.activity(sprite, installName);
            await Bun.sleep(1000);
        }
        for (const [kind, port, command] of [
            ['backend', r.backend, 'exec node server.mjs'],
            ['metro', r.metro, `unset CI; export EXPO_NO_TELEMETRY=1 EXPO_NO_DOTENV=1 EXPO_OFFLINE=1 EXPO_PUBLIC_API_URL=http://127.0.0.1:${s.backendPort} EXPO_PACKAGER_PROXY_URL=http://127.0.0.1:${s.metroPort}; exec node --require ${quote(preload)} node_modules/expo/bin/cli start --dev-client --localhost --port "$PORT"`],
        ] as const) {
            this.assert(s);
            await this.exec(s, `const net=require('node:net');const s=net.createServer();s.on('error',()=>process.exit(1));s.listen(Number(process.argv[2]),'127.0.0.1',()=>s.close());`, [String(port)]);
            await this.ctx.sprites!.defineService(sprite, serviceName(s.id, kind), s.workdir, command, port);
            this.assert(s);
        }
        const deadline = Date.now() + 120000;
        while (true) {
            this.assert(s);
            if (await this.ready(s, r.metro, '/status', 'packager-status:running') && await this.ready(s, r.backend, '/health'))
                break;
            if (Date.now() > deadline)
                throw new Error('Private Metro/backend readiness timed out');
            await Bun.sleep(1000);
        }
        await this.checkWorkspace(s);
        s.phase = 'Connecting';
    }
    private async ready(s: Session, port: number, path: string, body?: string) {
        const signal = AbortSignal.any([s.controller.signal, AbortSignal.timeout(3000)]);
        let client: ReturnType<typeof previewClient> | undefined;
        try {
            client = previewClient(await spriteTunnel(this.ctx.config.sprites!, s.reservation!.sprite, port, signal));
            const response = await client.request({ path, method: 'GET', signal });
            const text = await response.body.text();
            return response.statusCode === 200 && (!body || text === body);
        }
        catch {
            return false;
        }
        finally {
            await client?.destroy();
        }
    }
    private async retire(r: NativeServiceReservation) {
        if (!this.ctx.sprites)
            throw new Error('Sprites unavailable for cleanup');
        for (const kind of ['metro', 'backend', 'install']) {
            await this.ctx.sprites.serviceAction(r.sprite, serviceName(r.id, kind), 'stop');
            await this.ctx.sprites.serviceAction(r.sprite, serviceName(r.id, kind), 'delete');
            await this.ctx.sprites.activity(r.sprite, serviceName(r.id, kind), true);
        }
        const result = await this.ctx.sprites.exec(r.sprite, ['rm', '-f', `/tmp/switchyard-native-${r.id}.cjs`, `/tmp/switchyard-native-${r.id}.install`], 10);
        if (result.code)
            throw new Error('Could not remove Metro preload');
        this.ctx.db.nativeExperiments.remove(r.id);
    }
    private stopSession(s: Session, error?: string): Promise<void> {
        if (s.stopping)
            return s.stopping;
        // Cleanup retries must retain the original termination reason.
        if (!s.controller.signal.aborted) s.error = error?.slice(-2000) ?? null;
        s.controller.abort();
        s.pairHash = null;
        s.tokenHash = null;
        s.phase = s.error || s.cleanupError ? 'Failed' : 'Stopped';
        s.runner?.send(JSON.stringify({ type: 'ended', error: s.error }));
        for (const ws of [s.runner, s.producer, s.input, ...s.viewers])
            ws?.close(1000, 'Session ended');
        s.stopping = (async () => { await s.pending?.catch(() => { }); await s.checking?.catch(() => { }); if (s.reservation)
            await this.retire(s.reservation);
            s.cleanupError = undefined;
            s.phase = s.error ? 'Failed' : 'Stopped';
        })().catch(error => { s.cleanupError = String(error).slice(-1500); s.phase = 'Failed'; s.stopping = undefined; });
        return s.stopping;
    }
    async upgrade(req: Request, server: Server<NativePeer>) {
        try {
            const url = new URL(req.url), match = /^\/api\/native\/sessions\/([a-f0-9-]{36})\/(runner|video|view|input)$/.exec(url.pathname);
            if (!match || req.method !== 'GET' || url.search || req.headers.get('upgrade')?.toLowerCase() !== 'websocket')
                return new Response('Not found', { status: 404 });
            const role = match[2] as NativePeer['role'];
            let s: Session | undefined;
            let userId: string | undefined, sessionHash: string | undefined;
            if (role === 'runner' || role === 'video') {
                s = await this.runnerSession(req, match[1]!) ?? undefined;
                if (!s || (role === 'runner' ? s.runner : s.producer))
                    return new Response('Unauthorized', { status: 401 });
            }
            else {
                if (req.headers.get('origin') !== this.ctx.config.publicUrl)
                    return new Response('Unauthorized', { status: 401 });
                const user = await authenticate(this.ctx, req);
                s = this.sessions.get(match[1]!);
                if (!s || !this.live(s))
                    return new Response('Not found', { status: 404 });
                trackAccess(this.ctx, user, s.trackId);
                userId = user.id;
                sessionHash = await sha256(cookieValue(req, SESSION_COOKIE)!);
                if (s.viewers.size >= 8)
                    return new Response('Busy', { status: 503 });
            }
            if (!this.live(s))
                return new Response('Unauthorized', { status: 401 });
            if (server.upgrade(req, { data: { role, session: s, userId, sessionHash, waiting: true, count: 0, period: Date.now() } }))
                return;
            return new Response('Upgrade failed', { status: 400 });
        }
        catch (error) {
            return errorResponse(error);
        }
    }
    private readonly channels = {
        open: (ws: ServerWebSocket<NativePeer>) => {
            const p = ws.data, s = p.session;
            if (!this.live(s)) {
                ws.close(1008);
                return;
            }
            if (p.role === 'runner') {
                if (s.runner) {
                    ws.close(1008);
                    return;
                }
                s.runner = ws;
                ws.send(JSON.stringify({ type: 'status', ...this.info(s), leaseMs: NATIVE.leaseMs }));
            }
            else if (p.role === 'video') {
                if (s.producer) {
                    ws.close(1008);
                    return;
                }
                s.producer = ws;
            }
            else if (!this.viewerLive(p)) {
                ws.close(1008);
            }
            else if (p.role === 'view') {
                if (s.viewers.size >= 8) { ws.close(1013, 'Viewer limit'); return; }
                s.viewers.add(ws);
                if (s.video)
                    ws.send(JSON.stringify(s.video));
                if (s.config)
                    ws.send(s.config);
            }
            else {
                if (!s.appReady || s.phase !== 'Ready') { ws.close(1008, 'Wait until the app is ready'); return; }
                if (s.input) {
                    ws.close(1008, 'Another viewer controls this device');
                    return;
                }
                s.input = ws;
                ws.send(JSON.stringify({ type: 'controller', active: true }));
            }
        },
        message: (ws: ServerWebSocket<NativePeer>, data: string | Buffer) => {
            const p = ws.data, s = p.session;
            try {
                if (!this.live(s))
                    throw Error('Session ended');
                if (Date.now() - p.period >= 1000) {
                    p.period = Date.now();
                    p.count = 0;
                }
                if (++p.count > 120)
                    throw Error('Channel rate exceeded');
                if (p.role === 'video') {
                    if (s.producer !== ws)
                        throw Error('Stale producer');
                    if (typeof data === 'string') {
                        if (data.length > 512)
                            throw Error('Invalid video metadata');
                        const v = JSON.parse(data) as NativeVideo;
                        if (v.type !== 'video' || v.codec !== 'h264' || ![v.width, v.height].every(n => Number.isInteger(n) && n > 0 && n <= 4096))
                            throw Error('Invalid video metadata');
                        s.video = { type: 'video', codec: 'h264', width: v.width, height: v.height };
                        s.config = undefined;
                        for (const viewer of s.viewers) {
                            viewer.data.waiting = true;
                            viewer.send(JSON.stringify(s.video));
                        }
                        return;
                    }
                    if (!s.video)
                        throw Error('Video has no dimensions');
                    const frame = nativeFrame(data);
                    if (frame.config)
                        s.config = Buffer.from(data);
                    else {
                        s.frames++;
                        s.lastFrame = Date.now();
                        if (s.appReady)
                            s.phase = 'Ready';
                    }
                    for (const viewer of s.viewers) {
                        if (!this.viewerLive(viewer.data)) {
                            viewer.close(1008);
                            continue;
                        }
                        if (viewer.getBufferedAmount() > 256 * 1024) {
                            viewer.close(1013, 'Viewer fell behind');
                            continue;
                        }
                        if (frame.config) {
                            viewer.send(data);
                            viewer.data.waiting = true;
                        }
                        else if (!viewer.data.waiting || frame.key) {
                            viewer.data.waiting = false;
                            viewer.send(data);
                        }
                    }
                    return;
                }
                if (typeof data !== 'string' || data.length > 4096)
                    throw Error('Invalid control message');
                const message = JSON.parse(data);
                if (p.role === 'runner') {
                    if (s.runner !== ws)
                        throw Error('Stale runner');
                    if (message.type === 'heartbeat') {
                        s.leaseUntil = Math.min(s.expiresAt, Date.now() + NATIVE.leaseMs);
                        ws.send(JSON.stringify({ type: 'status', ...this.info(s), leaseMs: Math.max(0, s.leaseUntil - Date.now()) }));
                    }
                    else if (message.type === 'ready') {
                        s.appReady = true;
                        if (s.producer && s.lastFrame > 0)
                            s.phase = 'Ready';
                    }
                    else if (message.type === 'error')
                        void this.stopSession(s, String(message.error).slice(-2000));
                    else
                        throw Error('Unknown runner message');
                    return;
                }
                if (!this.viewerLive(p))
                    throw Error('Access ended');
                s.lastViewer = Date.now();
                if (p.role === 'view') {
                    if (message.type !== 'heartbeat')
                        throw Error('Viewer is read only');
                    return;
                }
                if (s.input !== ws || !s.runner)
                    throw Error('No controller');
                if (message.type === 'heartbeat') return;
                if (!s.appReady || s.phase !== 'Ready') throw Error('Device is not ready');
                const input = parseNativeInput(message);
                if (s.platform === 'ios' && (input.type === 'key' && input.key === 'back' || input.type === 'text' && /[^\x20-\x7e]/.test(input.text))) throw Error('Unsupported iOS input');
                if ('width' in input && (!s.video || input.width !== s.video.width || input.height !== s.video.height))
                    throw Error('Frame dimensions changed');
                if (s.runner.getBufferedAmount() > 16384)
                    throw Error('Runner controls stalled');
                s.runner.send(JSON.stringify(input));
            }
            catch (error) {
                ws.close(1008, String(error).slice(0, 100));
            }
        },
        close: (ws: ServerWebSocket<NativePeer>) => {
            const p = ws.data, s = p.session;
            if (p.role === 'runner' && s.runner === ws) {
                s.runner = undefined;
                if (this.live(s))
                    void this.stopSession(s, 'Runner disconnected');
            }
            if (p.role === 'video' && s.producer === ws) {
                s.producer = undefined;
                if (this.live(s))
                    void this.stopSession(s, 'Screen stream disconnected');
            }
            if (p.role === 'view')
                s.viewers.delete(ws);
            if (p.role === 'input' && s.input === ws) {
                s.input = undefined;
                if (s.runner && s.video)
                    s.runner.send(JSON.stringify({ type: 'touch', action: 'cancel', x: 0, y: 0, width: s.video.width, height: s.video.height }));
            }
        },
    };
}
