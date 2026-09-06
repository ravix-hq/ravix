/** Local decoder/input smoke fixture. Supply an Annex-B H.264 file with AUDs.
 * Uses synthetic video, never claims to verify a real device or authorization. */
import { join } from 'node:path';
import { parseNativeInput } from '../../shared/native-preview';
const bytes = Buffer.from(await Bun.file(process.argv[2]!).arrayBuffer());
const offsets: number[] = [];
for (let i = 0; i + 4 < bytes.length; i++)
    if (bytes[i] === 0 && bytes[i + 1] === 0 && (bytes[i + 2] === 1 || (bytes[i + 2] === 0 && bytes[i + 3] === 1))) {
        const header = i + (bytes[i + 2] === 1 ? 3 : 4);
        if ((bytes[header]! & 31) === 9)
            offsets.push(i);
        i = header;
    }
const frames = offsets.map((start, i) => bytes.subarray(start, offsets[i + 1] ?? bytes.length));
const nal = (data: Buffer, types: number[]) => { const starts: {
    i: number;
    header: number;
}[] = []; for (let i = 0; i + 4 < data.length; i++)
    if (data[i] === 0 && data[i + 1] === 0 && (data[i + 2] === 1 || (data[i + 2] === 0 && data[i + 3] === 1))) {
        const header = i + (data[i + 2] === 1 ? 3 : 4);
        starts.push({ i, header });
        i = header;
    } return starts.flatMap((s, i) => types.includes(data[s.header]! & 31) ? [data.subarray(s.i, starts[i + 1]?.i ?? data.length)] : []); };
const configuration = Buffer.concat(nal(frames[0]!, [7, 8]));
function packet(data: Buffer, flags: bigint) { const header = Buffer.alloc(12); header.writeBigUInt64BE(flags); header.writeUInt32BE(data.length, 8); return Buffer.concat([header, data]); }
const id = '00000000-0000-4000-8000-000000000001';
let count = 0, controls: unknown[] = [];
const info = { id, trackId: 'fixture', phase: 'Ready', error: null, expiresAt: Date.now() + 3600000, runnerOnline: true, video: { type: 'video', codec: 'h264', width: 360, height: 640 }, frames: 0, trackUrl: '/' };
const server = Bun.serve<{
    role: string;
    timer?: ReturnType<typeof setInterval>;
}>({ hostname: '127.0.0.1', port: 0, fetch(req, server) {
        const path = new URL(req.url).pathname;
        if (path.endsWith('/view') || path.endsWith('/input')) {
            if (server.upgrade(req, { data: { role: path.endsWith('/view') ? 'view' : 'input' } }))
                return;
        }
        if (path === `/api/native/sessions/${id}`)
            return Response.json({ data: { ...info, frames: count } });
        if (path === '/fixture-report')
            return Response.json({ frames: count, controls });
        if (path.startsWith('/api/'))
            return Response.json({ data: { ok: true } });
        const file = Bun.file(join(import.meta.dir, '../../dist', path.startsWith('/assets/') ? path.slice(1) : 'index.html'));
        return new Response(file);
    }, websocket: { open(ws) { if (ws.data.role === 'input') {
            ws.send(JSON.stringify({ type: 'controller', active: true }));
            return;
        } ws.send(JSON.stringify(info.video)); ws.send(packet(configuration, 1n << 62n)); let i = 0; ws.data.timer = setInterval(() => { const frame = frames[i % frames.length]!; const key = nal(frame, [5]).length > 0; ws.send(packet(frame, BigInt(Math.round(i * 1000000 / 30)) | (key ? 1n << 61n : 0n))); i++; count++; }, 1000 / 30); }, message(ws, data) { if (ws.data.role === 'input') { try { const value = JSON.parse(String(data)); if (value.type !== 'heartbeat') { controls.push(parseNativeInput(value)); controls = controls.slice(-64); } } catch { ws.close(1008); } } }, close(ws) { if (ws.data.timer)
            clearInterval(ws.data.timer); } } });
console.log(`http://127.0.0.1:${server.port}/native/${id}`);
