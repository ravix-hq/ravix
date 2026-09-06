import { arch, userInfo } from 'node:os';
import { join } from 'node:path';
import { lstat, open, readFile, rm } from 'node:fs/promises';
import { privateDirectory, writePrivateJson } from './state';
import { parsePreviewExperiment, previewExperiment } from './preview-experiment';
import { verifyRuntimeBuild, type RuntimeConfig } from './runtime-experiment';
import { verifyIosBuild } from './ios-runtime';
import { RUNNER, parseRunnerCapabilities, type RunnerCapabilities, type RunnerWork } from '../shared/runners';
interface LocalBuild extends RuntimeConfig {
    platform: 'android' | 'ios';
}
export interface RunnerConfig {
    expectedAccount: string;
    serverUrl: string;
    name: string;
    builds: LocalBuild[];
}
interface Identity {
    version: 1;
    id: string;
    token: string;
    serverUrl: string;
    capabilities: RunnerCapabilities;
}
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(v);
export function parseRunnerConfig(value: unknown): RunnerConfig {
    const v = value as RunnerConfig;
    if (!v || typeof v.name !== 'string' || !/^[\w .-]{1,80}$/.test(v.name) || !Array.isArray(v.builds) || !v.builds.length || v.builds.length > 2)
        throw Error('Choose a runner name and one or two explicit Hello builds');
    const seen = new Set<string>();
    let serverUrl = '';
    const builds = v.builds.map(b => {
        if (!b || !['android', 'ios'].includes(b.platform) || seen.has(b.platform))
            throw Error('Duplicate or invalid platform');
        seen.add(b.platform);
        const parsed = parsePreviewExperiment({ ...b, expectedAccount: v.expectedAccount, serverUrl: v.serverUrl, pairingCode: 'a'.repeat(43) });
        serverUrl = parsed.serverUrl;
        return { platform: b.platform, expectedAccount: parsed.expectedAccount, buildDirectory: parsed.buildDirectory, artifactSha256: parsed.artifactSha256 };
    });
    return { name: v.name, expectedAccount: v.expectedAccount, serverUrl, builds };
}
export function parseRunnerWork(value: unknown, epoch: number, capabilities: RunnerCapabilities, now = Date.now()): RunnerWork {
    const w = value as RunnerWork;
    if (epoch < 1 || !w || ![w.id, w.sessionId, w.targetId].every(uuid) || !Number.isSafeInteger(w.generation) || w.generation < 1 || w.epoch !== epoch || !Number.isSafeInteger(w.deadline) || w.deadline <= now || w.deadline > now + 30 * 60000 || !capabilities.builds.some(b => b.platform === w.platform && b.artifactSha256 === w.artifactSha256) || typeof w.pairingCode !== 'string' || !/^[\w-]{43}$/.test(w.pairingCode))
        throw Error('Invalid or incompatible runner assignment');
    return { id: w.id, sessionId: w.sessionId, targetId: w.targetId, generation: w.generation, epoch: w.epoch, platform: w.platform, artifactSha256: w.artifactSha256, deadline: w.deadline, pairingCode: w.pairingCode };
}
async function privateJson(path: string) {
    const stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0 || stat.size > 65536)
        throw Error('Runner config and credentials must be private regular files');
    return JSON.parse(await readFile(path, 'utf8'));
}
async function capabilities(config: RunnerConfig): Promise<RunnerCapabilities> {
    const builds = [];
    for (const b of config.builds) {
        const verified = await (b.platform === 'ios' ? verifyIosBuild(b) : verifyRuntimeBuild(b));
        const report = await privateJson(join(b.buildDirectory, 'report.json'));
        builds.push({ platform: b.platform, architecture: b.platform === 'ios' ? 'arm64' : 'arm64-v8a', profile: b.platform === 'ios' ? 'com.apple.CoreSimulator.SimDeviceType.iPhone-16' : 'pixel_7', runtime: b.platform === 'ios' ? 'com.apple.CoreSimulator.SimRuntime.iOS-18-6' : 'system-images;android-35;google_apis;arm64-v8a', toolchain: b.platform === 'ios' ? `Xcode SDK ${report.iosRuntime?.sdk ?? 'unknown'}` : 'Android SDK 35; Java 21; scrcpy 4.1', artifactSha256: b.artifactSha256, sourceDigest: verified.sourceDigest, lockfileDigest: report.lockfileDigest });
    }
    return parseRunnerCapabilities({ version: 1, capacity: { sessions: 1, builds: 1 }, builds });
}
export async function registeredRunner(configFile: string, pairingFile?: string, signal?: AbortSignal) {
    const config = parseRunnerConfig(await privateJson(configFile)), user = userInfo();
    if (process.platform !== 'darwin' || arch() !== 'arm64' || user.uid === 0 || user.username !== config.expectedAccount)
        throw Error(`Run as the dedicated ${config.expectedAccount} account`);
    const state = await privateDirectory(join(user.homedir, '.local/share/switchyard/managed'));
    const lockPath = join(state, 'runner.lock'), lock = await open(lockPath, 'wx', 0o600).catch(() => { throw Error('A runner already owns this account. Review managed/runner.lock before recovery.'); });
    await lock.writeFile(JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }) + '\n');
    await lock.close();
    let clean = true;
    try {
        const caps = await capabilities(config), identityPath = join(state, 'identity.json');
        let identity: Identity;
        if (pairingFile) {
            if (await Bun.file(identityPath).exists())
                throw Error('This account already has a runner identity; revoke and archive it before pairing another');
            const code = (await readFile(pairingFile, 'utf8')).trim();
            if (!/^[\w-]{43}$/.test(code))
                throw Error('Use the runner pairing code shown by Switchyard');
            const response = await fetch(`${config.serverUrl}/api/native/runners/register`, { method: 'POST', redirect: 'error', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code, name: config.name, capabilities: caps }), signal: AbortSignal.any([AbortSignal.timeout(15000), ...(signal ? [signal] : [])]) });
            if (!response.ok)
                throw Error(`Runner registration failed (${response.status}); create a fresh pairing code`);
            const { data } = await response.json() as {
                data: Identity;
            };
            if (!data || data.version !== 1 || !uuid(data.id) || !/^[\w-]{43}$/.test(data.token))
                throw Error('Invalid registration response');
            identity = { version: 1, id: data.id, token: data.token, serverUrl: config.serverUrl, capabilities: caps };
            await writePrivateJson(identityPath, identity);
            await writePrivateJson(join(state, 'config.json'), config);
            console.log(`Registered ${config.name}. Future runs reuse this identity.`);
        }
        else {
            identity = await privateJson(identityPath);
            if (identity.version !== 1 || !uuid(identity.id) || !/^[\w-]{43}$/.test(identity.token) || identity.serverUrl !== config.serverUrl || JSON.stringify(identity.capabilities) !== JSON.stringify(caps))
                throw Error('Runner identity, origin or verified build inventory changed; review registration before proceeding');
        }
        const run = async (work: RunnerWork, active: AbortSignal) => {
            const build = config.builds.find(b => b.platform === work.platform)!;
            const result = await previewExperiment({ ...build, serverUrl: config.serverUrl, pairingCode: work.pairingCode }, active, { targetId: work.targetId, sessionId: work.sessionId, deadline: work.deadline }).catch(error => { clean = false; throw error; });
            await writePrivateJson(join(state, 'last-result.json'), { sessionId: work.sessionId, generation: work.generation, directory: result.directory, report: result.report });
            if (result.report.cleanup !== 'complete')
                clean = false;
            return { error: result.report.error, cleanup: result.report.cleanup };
        };
        await runnerLoop(identity, run, signal);
    }
    finally {
        if (clean)
            await rm(lockPath);
    }
}
export type RunAssignment = (work: RunnerWork, signal: AbortSignal) => Promise<{
    error: string | null;
    cleanup: string;
}>;
/** One host connection, one owned job, and a wall-clock lease independent of media. */
export async function runnerLoop(identity: Identity, run: RunAssignment, signal?: AbortSignal) {
    let fatal: string | null = null;
    while (!signal?.aborted && !fatal) {
        const Client = WebSocket as unknown as new (url: string, options: {
            headers: Record<string, string>;
        }) => WebSocket;
        const ws = new Client(`${identity.serverUrl.replace(/^http/, 'ws')}/api/native/runners/${identity.id}/control`, { headers: { authorization: `Bearer ${identity.token}` } });
        let epoch = 0, lease = Date.now() + RUNNER.leaseMs, owned: RunnerWork | null = null, task: Promise<void> | undefined;
        let completion: {
            type: 'complete';
            sessionId: string;
            generation: number;
            cleanup: 'complete';
            error: string | null;
        } | null = null;
        const active = new AbortController();
        const send = (v: unknown) => { if (ws.readyState === WebSocket.OPEN)
            ws.send(JSON.stringify(v)); };
        const heartbeat = () => { if (epoch) {
            send({ type: 'heartbeat', owned: owned ? { id: owned.id, generation: owned.generation } : null });
            if (completion)
                send(completion);
        } };
        const abort = () => { active.abort(); ws.close(); };
        signal?.addEventListener('abort', abort, { once: true });
        const timer = setInterval(() => { if (Date.now() >= lease) {
            active.abort();
            ws.close(1000, 'Host lease expired');
        }
        else
            heartbeat(); }, RUNNER.heartbeatMs);
        await new Promise<void>(resolve => {
            ws.onclose = event => { if (event.code === 1008)
                fatal = event.reason || 'Runner access ended'; active.abort(); resolve(); };
            ws.onerror = () => { active.abort(); ws.close(); resolve(); };
            ws.onmessage = event => {
                try {
                    if (typeof event.data !== 'string' || event.data.length > 8192)
                        throw Error('Invalid host message');
                    const v = JSON.parse(event.data);
                    if (v.type === 'connected') {
                        if (epoch || v.version !== 1 || !Number.isSafeInteger(v.epoch) || v.epoch < 1)
                            throw Error('Invalid host epoch');
                        epoch = v.epoch;
                        lease = Date.now() + RUNNER.leaseMs;
                        send({ type: 'hello', owned: null });
                    }
                    else if (v.type === 'heartbeat') {
                        if (!epoch || v.epoch !== epoch || v.leaseMs !== RUNNER.leaseMs || Date.now() >= lease)
                            throw Error('Host lease expired');
                        lease = Date.now() + RUNNER.leaseMs;
                    }
                    else if (v.type === 'work') {
                        const work = parseRunnerWork(v.work, epoch, identity.capabilities);
                        if (owned) {
                            if (owned.id === work.id && owned.generation === work.generation) {
                                heartbeat();
                                return;
                            }
                            throw Error('Runner device slot is occupied');
                        }
                        if (completion || active.signal.aborted || Date.now() >= lease)
                            throw Error('Runner is reconciling');
                        owned = work;
                        heartbeat();
                        task = (async () => {
                            let result;
                            try {
                                result = await run(work, AbortSignal.any([active.signal, AbortSignal.timeout(Math.max(1, work.deadline - Date.now()))]));
                            }
                            catch {
                                fatal = 'Runner job failed before cleanup could be verified';
                                ws.close();
                                return;
                            }
                            if (result.cleanup !== 'complete') {
                                fatal = 'Runner cleanup is incomplete; inspect the retained report';
                                ws.close();
                                return;
                            }
                            completion = { type: 'complete', sessionId: work.sessionId, generation: work.generation, cleanup: 'complete', error: result.error };
                            owned = null;
                            send(completion);
                        })();
                    }
                    else if (v.type === 'cancel') {
                        if (owned && v.id === owned.id && v.generation === owned.generation) {
                            active.abort();
                            ws.close(1000, 'Reconciling assignment');
                        }
                    }
                    else if (v.type === 'completed') {
                        if (completion && v.sessionId === completion.sessionId && v.generation === completion.generation) {
                            completion = null;
                            heartbeat();
                        }
                    }
                    else
                        throw Error('Unknown host message');
                }
                catch {
                    fatal = 'Runner protocol rejected; inspect server and runner versions';
                    active.abort();
                    ws.close(1000, 'Protocol rejected');
                }
            };
        });
        clearInterval(timer);
        signal?.removeEventListener('abort', abort);
        active.abort();
        await task;
        if (!signal?.aborted && !fatal)
            await new Promise<void>(resolve => { const timer = setTimeout(done, 2000); function done() { clearTimeout(timer); signal?.removeEventListener('abort', done); resolve(); } signal?.addEventListener('abort', done, { once: true }); });
    }
    if (fatal)
        throw Error(fatal);
}
