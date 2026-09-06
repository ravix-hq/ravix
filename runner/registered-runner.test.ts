import { expect, test } from 'bun:test';
import { parseRunnerConfig, parseRunnerWork, runnerLoop } from './registered-runner';
import { parseRunnerCapabilities } from '../shared/runners';
const caps = parseRunnerCapabilities({ version: 1, capacity: { sessions: 1, builds: 1 }, builds: [{ platform: 'android', architecture: 'arm64-v8a', profile: 'pixel_7', runtime: 'android-35', toolchain: 'sdk35', artifactSha256: 'a'.repeat(64), sourceDigest: 'b'.repeat(64), lockfileDigest: 'c'.repeat(64) }] });
const work = () => ({ id: crypto.randomUUID(), sessionId: crypto.randomUUID(), targetId: crypto.randomUUID(), generation: 1, epoch: 1, platform: 'android' as const, artifactSha256: 'a'.repeat(64), deadline: Date.now() + 60000, pairingCode: 'x'.repeat(43) });
test('remote assignment cannot choose a host path, executable, platform, expired deadline or epoch', () => {
    const valid = work();
    expect(parseRunnerWork({ ...valid, command: 'rm -rf', buildDirectory: '/private' }, 1, caps)).toEqual(valid);
    for (const patch of [{ targetId: '../../private' }, { epoch: 2 }, { deadline: Date.now() - 1 }, { generation: 0 }, { platform: 'ios' }, { artifactSha256: 'b'.repeat(64) }])
        expect(() => parseRunnerWork({ ...valid, ...patch }, 1, caps)).toThrow();
    expect(() => parseRunnerConfig({ name: 'Mac', expectedAccount: 'switchyard', serverUrl: 'https://app.test/path', builds: [{ platform: 'android', buildDirectory: '/Users/switchyard/.local/share/switchyard/builds/experiment-' + crypto.randomUUID(), artifactSha256: 'a'.repeat(64) }] })).toThrow();
});
test('Mac acknowledges a duplicate offer once and reports completion only after cleanup', async () => {
    const assignment = work(), abort = new AbortController();
    let calls = 0, completed = false, accepted = false, release!: () => void;
    const blocked = new Promise<void>(resolve => release = resolve);
    const server = Bun.serve({ port: 0, fetch(req, server) { expect(req.headers.get('authorization')).toBe('Bearer ' + 't'.repeat(43)); if (server.upgrade(req))
            return; return new Response('', { status: 400 }); }, websocket: { open(ws) { ws.send(JSON.stringify({ type: 'connected', version: 1, epoch: 1, leaseMs: 60000 })); }, message(ws, data) {
                const m = JSON.parse(String(data));
                if (m.type === 'hello') {
                    ws.send(JSON.stringify({ type: 'work', work: assignment }));
                    ws.send(JSON.stringify({ type: 'work', work: assignment }));
                }
                if (m.type === 'heartbeat' && m.owned)
                    accepted = true;
                if (m.type === 'complete') {
                    completed = true;
                    ws.send(JSON.stringify({ type: 'completed', sessionId: m.sessionId, generation: m.generation, accepted: true }));
                    abort.abort();
                }
            } } });
    const task = runnerLoop({ version: 1, id: crypto.randomUUID(), token: 't'.repeat(43), serverUrl: `http://127.0.0.1:${server.port}`, capabilities: caps }, async () => { calls++; await blocked; return { error: null, cleanup: 'complete' }; }, abort.signal);
    try {
        const until = Date.now() + 3000;
        while (!accepted) {
            if (Date.now() > until)
                throw Error('No acknowledgement');
            await Bun.sleep(10);
        }
        expect(calls).toBe(1);
        expect(completed).toBe(false);
        release();
        await task;
        expect(completed).toBe(true);
    }
    finally {
        release();
        abort.abort();
        server.stop(true);
        await task;
    }
});
