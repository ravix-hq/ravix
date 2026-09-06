import { spawn } from 'node:child_process';
import { readFile, realpath, lstat } from 'node:fs/promises';
import { join } from 'node:path';
import { NATIVE, parseNativeInput, type NativeInput, type NativeVideo } from '../shared/native-preview';
import { IosVideo } from './ios-video';

/** idb's gRPC responses retain access-unit boundaries; pipes do not. */
export class IosBridgeFrames {
  private pending = Buffer.alloc(0);
  constructor(private receive: (kind: number, data: Buffer) => void) {}
  push(chunk: Buffer) {
    this.pending = Buffer.concat([this.pending, chunk]);
    while (this.pending.length >= 5) {
      const kind = this.pending[0]!, size = this.pending.readUInt32BE(1);
      if (![1, 2].includes(kind) || size < (kind === 1 ? 2 : 9) || size > (kind === 1 ? 4096 : NATIVE.frameBytes)) throw Error('Invalid idb bridge envelope');
      if (this.pending.length < 5 + size) break;
      const payload = this.pending.subarray(5, 5 + size);
      this.pending = this.pending.subarray(5 + size);
      this.receive(kind, payload);
    }
    if (this.pending.length > NATIVE.frameBytes + 5) throw Error('idb bridge buffer exceeded limit');
  }
  end() { if (this.pending.length) throw Error('Truncated idb bridge envelope'); }
}
export async function iosLive(options: {
  idb: string; socket: string; udid: string; env: NodeJS.ProcessEnv; signal: AbortSignal;
  metadata: (video: NativeVideo) => void; frame: (packet: Buffer) => void; failed: (error: unknown) => void;
}) {
  options.signal.throwIfAborted();
  const home = options.env.HOME;
  if (!home) throw Error('Missing runner home');
  const line = (await readFile(options.idb, 'utf8')).split('\n')[0]!;
  const python = line.startsWith('#!') ? line.slice(2).trim() : '';
  if (!python.startsWith(`${home}/.local/share/uv/tools/fb-idb/`) || /\s/.test(python) || !(await lstat(await realpath(python))).isFile()) throw Error('Use the dedicated account’s fb-idb Python installation');
  let metadata: NativeVideo | undefined, identified = false, closing = false, stderr = '';
  let resolveReady!: () => void, rejectReady!: (error: unknown) => void;
  const ready = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const child = spawn(python, ['-u', join(import.meta.dir, 'scripts/ios-bridge.py'), options.socket, options.udid], { env: options.env, stdio: ['pipe', 'pipe', 'pipe'], detached: true });
  const kill = (signal: NodeJS.Signals) => { try { if (child.pid) process.kill(-child.pid, signal); } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error; } };
  let escalation: ReturnType<typeof setTimeout> | undefined;
  const close = () => { if (!closing) { closing = true; child.stdin.end(); kill('SIGTERM'); escalation = setTimeout(() => kill('SIGKILL'), 3000); } };
  const fail = (error: unknown) => { rejectReady(error); if (!closing) options.failed(error); close(); };
  const video = new IosVideo(value => { metadata = value; options.metadata(value); }, options.frame);
  const parser = new IosBridgeFrames((kind, payload) => {
    if (kind === 1) {
      if (identified) throw Error('Repeated idb identity');
      const value = JSON.parse(payload.toString());
      if (value.udid !== options.udid || ![value.widthPoints, value.heightPoints].every(n => Number.isFinite(n) && n > 0 && n <= 4096)) throw Error('idb device identity mismatch');
      identified = true; resolveReady();
    } else {
      if (!identified) throw Error('Video before device identity');
      video.push(payload.subarray(8), Number(payload.readBigUInt64BE()));
    }
  });
  child.stdout.on('data', (bytes: Buffer) => { if (!closing) try { parser.push(bytes); } catch (error) { fail(error); } });
  child.stderr.on('data', (bytes: Buffer) => { stderr = (stderr + bytes.toString()).slice(-8192); });
  child.stdin.on('error', fail);
  child.on('error', fail);
  const settled = new Promise<void>(resolve => child.once('close', code => {
    clearTimeout(startup); if (escalation) clearTimeout(escalation);
    options.signal.removeEventListener('abort', close);
    if (!closing) { closing = true; const error = Error(`idb bridge exited (${code}): ${stderr}`); rejectReady(error); options.failed(error); }
    rejectReady(Error('idb bridge stopped')); resolve();
  }));
  const startup = setTimeout(() => fail(Error('idb bridge startup timed out')), 20000);
  options.signal.addEventListener('abort', close, { once: true });
  if (options.signal.aborted) close();
  try { await ready; clearTimeout(startup); }
  catch (error) { close(); await settled; throw error; }
  return {
    input(value: NativeInput) {
      const input = parseNativeInput(value);
      if (closing || !metadata) throw Error('iOS stream unavailable');
      if (input.type === 'key' && input.key === 'back' || input.type === 'text' && /[^\x20-\x7e]/.test(input.text)) throw Error('iOS supports Home, Enter, Backspace and printable ASCII text');
      if ('width' in input && (input.width !== metadata.width || input.height !== metadata.height)) throw Error('Stale iOS screen dimensions');
      if (child.stdin.writableLength > 16384) throw Error('iOS input cannot keep up');
      child.stdin.write(JSON.stringify(input) + '\n');
    },
    async close() { close(); await settled; },
  };
}
