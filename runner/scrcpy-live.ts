import { connect, type Socket } from 'node:net';
import { readFile } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import { ScrcpyVideo, scrcpyInput } from './scrcpy-protocol';
import type { NativeInput, NativeVideo } from '../shared/native-preview';
import { checked, type Command } from './process';
const SERVER = '/opt/homebrew/share/scrcpy/scrcpy-server';
const SERVER_SHA = 'deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae';
/** Called only by the adapter after verifying its own randomly named AVD. */
export async function scrcpyLive(options: {
    adb: string;
    serial: string;
    run: Command;
    env: NodeJS.ProcessEnv;
    signal: AbortSignal;
    metadata: (video: NativeVideo) => void;
    frame: (bytes: Buffer) => void;
    failed: (error: Error) => void;
}) {
    const { adb, serial, run, env, signal } = options;
    if (createHash('sha256').update(await readFile(SERVER)).digest('hex') !== SERVER_SHA)
        throw new Error('scrcpy 4.1 server digest changed; verify the toolchain');
    const id = (randomBytes(4).readUInt32BE() & 0x7fffffff).toString(16).padStart(8, '0');
    const jar = `/data/local/tmp/switchyard-scrcpy-${id}.jar`;
    const local = new AbortController(), active = AbortSignal.any([local.signal, signal]);
    const exec = (...args: string[]) => checked(run, [adb, '-s', serial, ...args], { env, signal: active, timeoutMs: 15000 });
    let video: Socket | undefined, control: Socket | undefined, port = 0, stopped = false;
    let process: Promise<unknown> | undefined;
    let closing: Promise<void> | undefined;
    const close = () => {
        if (closing) return closing;
        stopped = true;
        closing = (async () => {
        signal.removeEventListener('abort', abort);
        video?.destroy();
        control?.destroy();
        local.abort();
        await process?.catch(() => { });
        if (port)
            await checked(run, [adb, '-s', serial, 'forward', '--remove', `tcp:${port}`], { env, timeoutMs: 5000 }).catch(() => { });
        await checked(run, [adb, '-s', serial, 'shell', 'rm', '-f', jar], { env, timeoutMs: 5000 }).catch(() => { });
        })();
        return closing;
    };
    const fail = (error: Error) => { if (!stopped && !signal.aborted)
        options.failed(error); void close(); };
    const abort = () => { void close(); };
    signal.addEventListener('abort', abort, { once: true });
    try {
        active.throwIfAborted();
        await exec('push', SERVER, jar);
        port = Number((await exec('forward', 'tcp:0', `localabstract:scrcpy_${id}`)).toString().trim());
        if (!Number.isInteger(port) || port < 1024 || port > 65535)
            throw new Error('Invalid scrcpy forward');
        process = checked(run, [adb, '-s', serial, 'shell', `CLASSPATH=${jar}`, 'app_process', '/', 'com.genymobile.scrcpy.Server', '4.1',
            `scid=${id}`, 'tunnel_forward=true', 'audio=false', 'control=true', 'clipboard_autosync=false', 'send_device_meta=false',
            'max_size=1280', 'max_fps=30', 'video_bit_rate=4000000', 'video_codec=h264', 'video_codec_options=i-frame-interval=1', 'cleanup=false'], { env, signal: active, timeoutMs: 30 * 60000, maxBytes: 1024 * 1024 });
        void process.then(() => fail(new Error('Screen capture stopped')), error => fail(error instanceof Error ? error : new Error(String(error))));
        const deadline = Date.now() + 20000;
        while (!video) {
            active.throwIfAborted();
            try {
                video = await new Promise<Socket>((resolve, reject) => {
                    const socket = connect({ host: '127.0.0.1', port });
                    const timer = setTimeout(() => finish(new Error('scrcpy handshake timed out')), 2000);
                    const finish = (error?: Error) => {
                        clearTimeout(timer);
                        socket.off('error', errored);
                        socket.off('close', ended);
                        socket.off('data', data);
                        if (error) {
                            socket.destroy();
                            reject(error);
                        }
                        else {
                            socket.pause();
                            resolve(socket);
                        }
                    };
                    const errored = (error: Error) => finish(error), ended = () => finish(new Error('scrcpy not ready'));
                    const data = (bytes: Buffer) => { if (bytes.length !== 1 || bytes[0] !== 0)
                        finish(new Error('Invalid scrcpy handshake'));
                    else
                        finish(); };
                    socket.once('error', errored);
                    socket.once('close', ended);
                    socket.once('data', data);
                });
            }
            catch (error) {
                if (Date.now() > deadline)
                    throw error;
                await Bun.sleep(150);
            }
        }
        active.throwIfAborted();
        const parser = new ScrcpyVideo(options.metadata, options.frame);
        video.on('data', bytes => { try {
            parser.push(Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
        }
        catch (error) {
            fail(error instanceof Error ? error : new Error(String(error)));
        } });
        video.on('error', fail);
        video.on('close', () => fail(new Error('Screen stream closed')));
        control = connect({ host: '127.0.0.1', port });
        control.on('error', fail);
        control.on('close', () => fail(new Error('Device controls closed')));
        // Clipboard autosync is off; bound/discard any device acknowledgements.
        control.on('data', bytes => { if (bytes.length > 64 * 1024)
            fail(new Error('Invalid control acknowledgement')); });
        await new Promise<void>((resolve, reject) => {
            const socket = control!;
            const finish = (error?: Error) => { clearTimeout(timer); socket.off('connect', connected); socket.off('error', failed); socket.off('close', closed); error ? reject(error) : resolve(); };
            const connected = () => finish(), failed = (error: Error) => finish(error), closed = () => finish(new Error('Controls connection closed'));
            const timer = setTimeout(() => finish(new Error('Controls connection timed out')), 5000);
            socket.once('connect', connected); socket.once('error', failed); socket.once('close', closed);
        });
        video.resume();
        return { close, input(input: NativeInput) {
                active.throwIfAborted();
                if (stopped || !control || control.destroyed || control.writableLength > 16 * 1024)
                    throw new Error('Device control unavailable');
                control.write(scrcpyInput(input));
            } };
    }
    catch (error) {
        await close();
        throw error;
    }
}
