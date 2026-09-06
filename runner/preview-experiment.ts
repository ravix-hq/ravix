import { arch, platform, userInfo } from 'node:os';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { AndroidExperiment } from './adapters/experiment';
import { toolEnvironment, toolPaths } from './doctor';
import { acquireExperiment, writePrivateJson } from './state';
import { command } from './process';
import { androidNode, expoStartupAction, parseRuntimeConfig, verifyRuntimeBuild, type RuntimeConfig } from './runtime-experiment';
import { startLoopbackForward } from './loopback-forward';
import { NATIVE, parseNativeInput, type NativeInfo } from '../shared/native-preview';
interface PreviewConfig extends RuntimeConfig {
    serverUrl: string;
    pairingCode: string;
}
export function parsePreviewExperiment(value: unknown): PreviewConfig {
    const runtime = parseRuntimeConfig(value), v = value as PreviewConfig;
    const url = new URL(v.serverUrl);
    if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1')) || url.username || url.password || url.pathname !== '/' || url.search || url.hash)
        throw new Error('Use the Switchyard HTTPS app origin');
    if (typeof v.pairingCode !== 'string' || !/^[\w-]{43}$/.test(v.pairingCode))
        throw new Error('Use a fresh pairing code from the native preview');
    return { ...runtime, serverUrl: url.origin, pairingCode: v.pairingCode };
}
function socket(url: string, token: string) { const Client = WebSocket as unknown as new (url: string, options: {
    headers: Record<string, string>;
}) => WebSocket; return new Client(url, { headers: { authorization: `Bearer ${token}` } }); }
export async function previewExperiment(config: PreviewConfig, signal?: AbortSignal) {
    const user = userInfo();
    if (platform() !== 'darwin' || arch() !== 'arm64' || user.uid === 0 || user.username !== config.expectedAccount)
        throw new Error(`Run as the dedicated ${config.expectedAccount} account`);
    const baseEnv = {HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8'};
    const paths = await toolPaths(baseEnv);
    const build = await verifyRuntimeBuild(config), owned = await acquireExperiment(join(user.homedir, '.local/share/switchyard/runtime'));
    const controller = new AbortController(), active = AbortSignal.any([controller.signal, AbortSignal.timeout(NATIVE.lifetimeMs), ...(signal ? [signal] : [])]);
    const env = {...toolEnvironment(paths, baseEnv), TMPDIR: join(owned.directory, 'tmp')};
    const adapter = new AndroidExperiment({ platform: 'android', stateDirectory: owned.directory, emulatorPort: 5580, deviceType: 'pixel_7', systemImage: 'system-images;android-35;google_apis;arm64-v8a', scrcpyVersion: '4.1' }, owned.id, owned.directory, paths, command, active, env, NATIVE.lifetimeMs);
    const report = { version: 1, kind: 'android-sprite-preview-experiment', account: user.username, startedAt: new Date().toISOString(), artifactSha256: config.artifactSha256, sourceDigest: build.sourceDigest, sessionId: '', nativeRuntimeVerified: false, spriteMetroVerified: false, spriteBackendVerified: false, browserVerified: false, framesSent: 0, cleanup: 'pending', error: null as string | null };
    let control: WebSocket | undefined, media: WebSocket | undefined, live: Awaited<ReturnType<typeof adapter.live>> | undefined;
    let leaseDeadline = 0, heartbeat: ReturnType<typeof setInterval> | undefined, watchdog: ReturnType<typeof setInterval> | undefined;
    let remote: NativeInfo | null = null;
    const stop = (error: unknown) => { if (!active.aborted) {
        report.error = error instanceof Error ? error.message : String(error);
        controller.abort();
    } };
    const save = () => writePrivateJson(join(owned.directory, 'report.json'), report);
    const phase = async (name: string, work: () => Promise<void>) => { active.throwIfAborted(); console.log(`Preview: ${name}`); await work(); await save(); };
    try {
        await mkdir(env.TMPDIR, { mode: 0o700 });
        await save();
        const claim = await fetch(`${config.serverUrl}/api/native/claim`, { method: 'POST', redirect: 'error', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code: config.pairingCode, artifactSha256: config.artifactSha256 }), signal: AbortSignal.any([active, AbortSignal.timeout(15000)]) });
        if (!claim.ok)
            throw new Error(`Pairing failed (${claim.status}). Create a fresh code in Switchyard.`);
        const { data } = await claim.json() as {
            data: {
                id: string;
                token: string;
                leaseMs: number;
                metroPort: number;
                backendPort: number;
            };
        };
        if (!data || !Number.isFinite(data.leaseMs) || data.leaseMs <= 0 || !/^[a-f0-9-]{36}$/.test(data.id) || !/^[\w-]{43}$/.test(data.token) || data.metroPort !== NATIVE.metroPort || data.backendPort !== NATIVE.backendPort)
            throw new Error('Invalid runner assignment');
        report.sessionId = data.id;
        leaseDeadline = performance.now() + Math.min(NATIVE.leaseMs, data.leaseMs);
        const wsBase = config.serverUrl.replace(/^http/, 'ws') + `/api/native/sessions/${data.id}`;
        control = socket(`${wsBase}/runner`, data.token);
        control.onmessage = event => {
            try {
                if (typeof event.data !== 'string' || event.data.length > 8192)
                    throw new Error('Invalid runner message');
                const message = JSON.parse(event.data);
                if (message.type === 'status') {
                    if (message.id !== data.id || !Number.isFinite(message.leaseMs) || message.leaseMs <= 0)
                        throw new Error('Invalid assignment lease');
                    leaseDeadline = performance.now() + Math.min(NATIVE.leaseMs, message.leaseMs);
                    remote = message;
                    if (['Failed', 'Stopped'].includes(message.phase))
                        throw new Error(message.error || 'Server stopped the preview');
                }
                else if (live)
                    live.input(parseNativeInput(message));
            }
            catch (error) {
                stop(error);
            }
        };
        control.onclose = () => stop(new Error('Switchyard control connection closed'));
        control.onerror = () => stop(new Error('Switchyard control connection failed'));
        await new Promise<void>((resolve, reject) => { const timer = setTimeout(() => reject(new Error('Runner connection timed out')), 10000); control!.onopen = () => { clearTimeout(timer); resolve(); }; });
        heartbeat = setInterval(() => { if (control?.readyState === WebSocket.OPEN)
            control.send(JSON.stringify({ type: 'heartbeat' })); }, 10000);
        watchdog = setInterval(() => { if (performance.now() > leaseDeadline)
            stop(new Error('Runner assignment expired')); }, 250);
        await phase('wait-for-private-sprite-services', async () => { while (!remote || !['Connecting', 'Ready'].includes((remote as NativeInfo).phase)) {
            active.throwIfAborted();
            await Bun.sleep(250);
        } });
        await phase('forward-sprite-services', async () => {
            await startLoopbackForward({ endpoint: `${wsBase}/forward/metro`, token: data.token, signal: active, port: NATIVE.metroPort });
            await startLoopbackForward({ endpoint: `${wsBase}/forward/backend`, token: data.token, signal: active, port: NATIVE.backendPort });
            const status = await fetch(`http://127.0.0.1:${NATIVE.metroPort}/status`, { signal: AbortSignal.any([active, AbortSignal.timeout(15000)]) });
            if (await status.text() !== 'packager-status:running')
                throw new Error('Private Sprite Metro did not answer');
        });
        await phase('boot-owned-emulator', () => adapter.boot());
        await phase('install-apk', () => adapter.installHello(build.apk));
        await adapter.forward(NATIVE.metroPort);
        await adapter.forward(NATIVE.backendPort);
        await phase('connect-browser-stream', async () => {
            media = socket(`${wsBase}/video`, data.token);
            media.onclose = () => stop(new Error('Screen relay closed'));
            media.onerror = () => stop(new Error('Screen relay failed'));
            await new Promise<void>((resolve, reject) => { const timer = setTimeout(() => reject(new Error('Screen relay timed out')), 10000); media!.onopen = () => { clearTimeout(timer); resolve(); }; });
            live = await adapter.live({ metadata: video => { if (media?.readyState === WebSocket.OPEN)
                    media.send(JSON.stringify(video)); }, frame: bytes => {
                    if (!media || media.readyState !== WebSocket.OPEN || media.bufferedAmount > 256 * 1024) {
                        stop(new Error('Screen uplink cannot keep up'));
                        return;
                    }
                    media.send(bytes);
                    report.framesSent++;
                }, failed: stop });
        });
        await phase('launch-from-sprite-metro', () => adapter.launchHello(NATIVE.metroPort));
        const waitFor = async (text: string, timeout = 180000) => {
            const deadline = Date.now() + timeout;
            let dismissals = 0;
            while (Date.now() < deadline) {
                active.throwIfAborted();
                try {
                    const xml = await adapter.readHierarchy();
                    const node = androidNode(xml, 'text', text, 'com.managoat.switchyard.hello');
                    if (node)
                        return node;
                    const action = expoStartupAction(xml);
                    if (action && dismissals++ < 3)
                        await adapter.tap(action.x, action.y);
                }
                catch {
                    active.throwIfAborted();
                }
                await Bun.sleep(1000);
            }
            throw new Error(`App did not show: ${text}`);
        };
        await phase('verify-sprite-greeting', async () => { await waitFor('Hello, world!'); report.nativeRuntimeVerified = true; report.spriteMetroVerified = true; await adapter.screenshot(join(owned.directory, 'sprite-greeting.png')); });
        await phase('verify-sprite-backend', async () => {
            const xml = await adapter.readHierarchy();
            const button = androidNode(xml, 'content-desc', 'Call backend', 'com.managoat.switchyard.hello');
            if (!button)
                throw new Error('Backend button unavailable');
            await adapter.tap(button.x, button.y);
            await waitFor('Hello from the Sprite backend!', 60000);
            report.spriteBackendVerified = true;
            await adapter.screenshot(join(owned.directory, 'sprite-backend.png'));
        });
        control.send(JSON.stringify({ type: 'ready' }));
        console.log(`Browser preview: ${config.serverUrl}/native/${data.id}`);
        console.log('Preview stays open for browser testing. Ctrl+C stops the owned device and private services.');
        while (!active.aborted) {
            await Bun.sleep(1000);
            if (report.framesSent % 30 === 0)
                await save();
        }
        if (!report.error && signal?.aborted)
            report.error = null;
    }
    catch (error) {
        report.error ??= error instanceof Error ? error.message : String(error);
        if (control?.readyState === WebSocket.OPEN)
            control.send(JSON.stringify({ type: 'error', error: report.error }));
    }
    finally {
        controller.abort();
        if (heartbeat)
            clearInterval(heartbeat);
        if (watchdog)
            clearInterval(watchdog);
        await live?.close();
        media?.close();
        control?.close();
        try {
            await adapter.stop();
            report.cleanup = 'complete';
            await save();
            await owned.release();
        }
        catch (error) {
            report.cleanup = String(error);
            report.error ??= report.cleanup;
        }
        await save();
    }
    return { directory: owned.directory, report };
}
