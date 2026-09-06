import { afterEach, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Db } from './db';
import { loadConfig } from './config';
import { buildContext } from './context';
import { Cipher, sha256 } from './crypto';
import { buildRouter } from './app';
import { nativeExperiments, type NativeSocketData } from './native-experiment';
import { Sprites, type SpriteService } from './sprites';
import type { NativeInfo } from '../shared/native-preview';
import { startLoopbackForward } from '../runner/loopback-forward';
const cleanup: (() => void | Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse())
    await close(); });
const APK = '6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82';
async function until(check: () => boolean | Promise<boolean>, ms = 4000) { const end = Date.now() + ms; while (!await check()) {
    if (Date.now() > end)
        throw Error('Timed out');
    await Bun.sleep(10);
} }
async function fixture() {
    const dir = mkdtempSync(join(tmpdir(), 'sy-native-session-'));
    const state = { services: new Map<string, SpriteService>(), commands: [] as string[], actions: [] as string[], badNative: false, failStop: false, installBarrier: null as Promise<void> | null, proxyHeaders: [] as string[], upstreamBytes: [] as string[] };
    const provider = Bun.serve({ port: 0, fetch(req, server) {
            if (new URL(req.url).pathname.endsWith('/proxy')) {
                state.proxyHeaders.push(req.headers.get('authorization') ?? '');
                if (server.upgrade(req))
                    return;
            }
            return Response.json({ data: new URL(req.url).pathname === '/api/conversations' ? [{ id: 'conversation', sandbox_id: 'sandbox', status: 'idle', inserted_at: '2026-09-06' }] : { sprite_name: 'sprite' } });
        }, websocket: { message(ws, data) { if (typeof data === 'string') {
                ws.send(JSON.stringify({ status: 'connected' }));
            }
            else {
                state.upstreamBytes.push(data.toString());
                const body = data.toString().includes('/status') ? 'packager-status:running' : '{"ok":true}';
                ws.send(Buffer.from(`HTTP/1.1 200 OK\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`));
            } } } });
    const config = loadConfig({ DATA_DIR: dir, SWITCHYARD_SECRET: 'native-session-test-secret-long-enough', PUBLIC_URL: 'https://switchyard.test', NATIVE_PREVIEW_EXPERIMENT: '1', FOUNTAIN_URL: `http://127.0.0.1:${provider.port}`, FOUNTAIN_API_KEY: 'fake', SPRITES_URL: `http://127.0.0.1:${provider.port}`, SPRITES_TOKEN: 'provider-secret' });
    const db = new Db(config.dbPath), ctx = buildContext({ db, config, cipher: await Cipher.from(config.secret) });
    class Provider extends Sprites {
        async defineService(_sprite: string, name: string, dir: string, command: string, port: number) { state.commands.push(command); if (name.endsWith('-install'))
            await state.installBarrier; state.services.set(name, { name, dir, cmd: 'sh', args: ['-lc', command], env: { PORT: String(port), HOST: '127.0.0.1' }, state: { status: 'running', exit_code: 0, restart_count: 0 } }); return ''; }
        async service(_sprite: string, name: string) { return state.services.get(name) ?? null; }
        async serviceAction(_sprite: string, name: string, action: 'start' | 'stop' | 'delete') { if (state.failStop)
            throw Error('offline'); state.actions.push(`${action}/${name}`); if (action === 'delete')
            state.services.delete(name); return ''; }
        async activity() { return; }
        async serviceLogs() { return 'fixture logs'; }
        async exec(_sprite: string, argv: string[]) { if (state.badNative && argv[2]?.includes('Native configuration changed'))
            return { code: 1, stderr: 'Native configuration changed. Rebuild required.', stdout: '' }; return { code: 0, stderr: '', stdout: argv.some(a => a.endsWith('.install')) ? '0' : '' }; }
    }
    ctx.sprites = new Provider({ token: 'fake', baseUrl: 'unused' });
    const owner = db.upsertUser({ githubId: '1', login: 'owner', name: null, avatarUrl: null, tokenEnc: 'unused' }), member = db.upsertUser({ githubId: '2', login: 'member', name: null, avatarUrl: null, tokenEnc: 'unused' });
    for (const user of [owner, member])
        db.createSession(user.id, await sha256(user.login), 60000);
    db.createProject({ id: 'project', userId: owner.id, name: 'Hello', repoFullName: 'managoat/switchyard-expo-hello', repoPrivate: 1, defaultBranch: 'main', installationId: 1, agentId: 'agent', environmentId: 'env', vaultId: null, runtime: 'codex', model: 'test', instructions: '' });
    for (const id of ['track', 'other'])
        db.createTrack({ id, projectId: 'project', conversationId: id, slug: id, title: id, branch: id, workdir: `/work/${id}`, originKind: 'blank', originBase: null, originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: 'owner' });
    db.addMember('track', member.id, owner.id);
    const manager = nativeExperiments(ctx), router = buildRouter(ctx);
    manager.start();
    const server = Bun.serve<NativeSocketData>({ port: 0, fetch: (req, server) => req.headers.get('upgrade') === 'websocket' ? manager.fetch(req, server) : router(req), websocket: manager.websocket });
    const request = (path: string, method = 'GET', body?: unknown, user = 'owner', origin = config.publicUrl) => router(new Request(`https://switchyard.test${path}`, { method, headers: { cookie: `switchyard_session=${user}`, origin }, ...(body ? { body: JSON.stringify(body) } : {}) }));
    const start = async () => { await Bun.sleep(0); const response = await request('/api/tracks/track/native/start', 'POST'); if (!response.ok)
        throw Error(await response.text()); return (await response.json()).data as NativeInfo; };
    const claim = async (code: string) => { const response = await router(new Request('https://switchyard.test/api/native/claim', { method: 'POST', body: JSON.stringify({ code, artifactSha256: APK }) })); return response; };
    const sockets: WebSocket[] = [];
    const connect = async (id: string, role: string, token?: string, user = 'owner') => {
        const Client = WebSocket as unknown as new (url: string, opts: {
            headers: Record<string, string>;
        }) => WebSocket;
        const ws = new Client(`ws://127.0.0.1:${server.port}/api/native/sessions/${id}/${role}`, { headers: token ? { authorization: `Bearer ${token}` } : { origin: config.publicUrl, cookie: `switchyard_session=${user}` } });
        sockets.push(ws);
        ws.binaryType = 'arraybuffer';
        await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(Error('WS rejected')); });
        return ws;
    };
    cleanup.push(async () => { for (const ws of sockets)
        ws.close(); await manager.stop(); server.stop(true); provider.stop(true); db.close(); rmSync(dir, { recursive: true, force: true }); });
    return { db, ctx, manager, state, request, start, claim, connect, owner, member, port: server.port };
}
test('fixture scope, owner-only pairing, browser origin and signed-out denial', async () => {
    const f = await fixture();
    expect((await f.request('/api/tracks/track/native/start', 'POST', undefined, 'member')).status).toBe(403);
    expect((await f.request('/api/tracks/track/native/start', 'POST', undefined, 'owner', 'https://evil.test')).status).toBe(403);
    expect((await f.request('/api/tracks/track/native', 'GET', undefined, 'signed-out')).status).toBe(401);
    f.ctx.config.nativePreviewExperiment = false;
    expect((await f.request('/api/tracks/track/native/start', 'POST')).status).toBe(501);
});
test('pairing is single-use and private services preserve the existing web preview', async () => {
    const f = await fixture();
    const web = f.db.previews.allocate('track', 'sandbox', 'sprite');
    const s = await f.start();
    expect(s.pairingCode).toHaveLength(43);
    expect((await f.request('/api/tracks/track/native/start', 'POST')).status).toBe(409);
    const results = await Promise.all([f.claim(s.pairingCode!), f.claim(s.pairingCode!)]);
    expect(results.map(r => r.status).sort()).toEqual([200, 401]);
    const paired = (await results.find(r => r.status === 200)!.json()).data;
    const runner = await f.connect(s.id, 'runner', paired.token);
    runner.send(JSON.stringify({ type: 'heartbeat' }));
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Connecting');
    expect(f.db.previews.get('track')).toEqual(web);
    const reservation = f.db.nativeExperiments.all()[0]!;
    expect(reservation.metro).toBeGreaterThanOrEqual(30000);
    expect(reservation.backend).not.toBe(web.port);
    expect(f.state.commands.some(c => c.includes('EXPO_PACKAGER_PROXY_URL=http://127.0.0.1:41000'))).toBe(true);
    expect(f.state.commands.every(c => !c.includes(paired.token))).toBe(true);
    expect(f.state.proxyHeaders).toContain('Bearer provider-secret');
    expect(f.state.upstreamBytes.join('')).not.toContain(paired.token);
    const active = new AbortController();
    const forward = await startLoopbackForward({ endpoint: `ws://127.0.0.1:${f.port}/api/native/sessions/${s.id}/forward/metro`, token: paired.token, signal: active.signal });
    try {
        const response = await fetch(`http://127.0.0.1:${forward.port}/status`, { signal: AbortSignal.timeout(3000) });
        expect(await response.text()).toBe('packager-status:running');
    }
    finally {
        active.abort();
        forward.close();
    }
    expect(f.state.upstreamBytes.join('')).not.toContain(paired.token);
    await f.request('/api/tracks/track/native/stop', 'POST');
    expect(f.db.nativeExperiments.all()).toHaveLength(0);
    expect(f.db.previews.get('track')).toEqual(web);
});
test('video waits for a keyframe, input has one controller, and sign-out ends established channels', async () => {
    const f = await fixture(), s = await f.start(), paired = (await (await f.claim(s.pairingCode!)).json()).data;
    const runner = await f.connect(s.id, 'runner', paired.token), producer = await f.connect(s.id, 'video', paired.token), viewer = await f.connect(s.id, 'view', undefined, 'member');
    const frames: ArrayBuffer[] = [], commands: string[] = [];
    viewer.onmessage = e => { if (e.data instanceof ArrayBuffer)
        frames.push(e.data); };
    runner.onmessage = e => commands.push(String(e.data));
    producer.send(JSON.stringify({ type: 'video', codec: 'h264', width: 576, height: 1280 }));
    const packet = (flags: bigint) => { const p = Buffer.alloc(14); p.writeBigUInt64BE(flags); p.writeUInt32BE(2, 8); return p; };
    producer.send(packet(1n << 62n));
    producer.send(packet(1n));
    producer.send(packet((1n << 61n) | 2n));
    await until(() => frames.length === 2);
    runner.send(JSON.stringify({type: 'ready'}));
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Ready');
    const input = await f.connect(s.id, 'input', undefined, 'member');
    input.send(JSON.stringify({ type: 'touch', action: 'down', x: 0.5, y: 0.5, width: 576, height: 1280 }));
    await until(() => commands.some(c => c.includes('"down"')));
    const second = await f.connect(s.id, 'input');
    await until(() => second.readyState === WebSocket.CLOSED);
    input.close();
    await until(() => commands.some(c => c.includes('"cancel"')));
    f.db.endSession(await sha256('owner'));
    await until(() => runner.readyState === WebSocket.CLOSED);
    await until(() => viewer.readyState === WebSocket.CLOSED);
});
test('stopping during service creation cleans up late definitions before releasing reservations', async () => {
    const f = await fixture();
    let release!: () => void;
    f.state.installBarrier = new Promise(resolve => { release = resolve; });
    const s = await f.start();
    const paired = (await (await f.claim(s.pairingCode!)).json()).data;
    await f.connect(s.id, 'runner', paired.token);
    await until(() => f.state.commands.length > 0);
    const stopping = f.request('/api/tracks/track/native/stop', 'POST');
    release();
    await stopping;
    expect(f.state.services.size).toBe(0);
    expect(f.db.nativeExperiments.all()).toHaveLength(0);
});
test('changed native inputs fail before installation or Metro startup', async () => {
    const f = await fixture();
    f.state.badNative = true;
    const s = await f.start();
    await f.claim(s.pairingCode!);
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Failed');
    expect(f.state.commands).toHaveLength(0);
    await until(() => f.db.nativeExperiments.all().length === 0);
});

test('pairing rejects malformed and oversized bodies without consuming the code', async () => {
    const f = await fixture(), s = await f.start();
    for (const [body, expected] of [['null', 400], ['{', 400], ['x'.repeat(1025), 413]] as const) {
        const response = await f.manager.claim(new Request('https://switchyard.test/api/native/claim', {method: 'POST', body})).catch(error => error);
        expect(response.status).toBe(expected);
    }
    expect((await f.claim(s.pairingCode!)).status).toBe(200);
});
test('failed cleanup retains reservations and a retry removes only owned services', async () => {
    const f = await fixture(), s = await f.start(), paired = (await (await f.claim(s.pairingCode!)).json()).data;
    await f.connect(s.id, 'runner', paired.token);
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Connecting');
    f.state.failStop = true;
    await f.request('/api/tracks/track/native/stop', 'POST');
    expect(f.db.nativeExperiments.all()).toHaveLength(1);
    expect((await f.request('/api/tracks/other/native/start', 'POST')).status).toBe(409);
    f.state.failStop = false;
    await f.request('/api/tracks/track/native/stop', 'POST');
    expect(f.db.nativeExperiments.all()).toHaveLength(0);
    expect(f.state.services.size).toBe(0);
});

test('a static screen remains ready while its producer and runner lease are live', async () => {
    const f = await fixture(), s = await f.start(), paired = (await (await f.claim(s.pairingCode!)).json()).data;
    const runner = await f.connect(s.id, 'runner', paired.token), producer = await f.connect(s.id, 'video', paired.token);
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Connecting');
    producer.send(JSON.stringify({type:'video',codec:'h264',width:576,height:1280}));
    const packet=Buffer.alloc(14);packet.writeBigUInt64BE(1n<<61n);packet.writeUInt32BE(2,8);producer.send(packet);
    runner.send(JSON.stringify({type:'ready'}));
    await until(async () => (await (await f.request('/api/tracks/track/native')).json()).data.session.phase === 'Ready');
    const original=Date.now;
    try {
        Date.now=()=>original()+20000;
        await Bun.sleep(1200);
        expect((await (await f.request('/api/tracks/track/native')).json()).data.session.phase).toBe('Ready');
        const input=await f.connect(s.id,'input');
        expect(input.readyState).toBe(WebSocket.OPEN);
    } finally {Date.now=original;}
});
