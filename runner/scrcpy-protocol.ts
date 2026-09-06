import { NATIVE, nativeFrame, parseNativeInput, type NativeInput, type NativeVideo } from '../shared/native-preview';
/** Incremental parser pinned to scrcpy 4.1 (codec, session, media packets).
 * https://github.com/Genymobile/scrcpy/blob/v4.1/doc/develop.md#protocol */
export class ScrcpyVideo {
    private pending = Buffer.alloc(0);
    private codec = false;
    private session = false;
    constructor(private metadata: (video: NativeVideo) => void, private frame: (bytes: Buffer) => void) { }
    push(bytes: Buffer) {
        if (bytes.length > NATIVE.frameBytes + 16 || this.pending.length + bytes.length > 2 * NATIVE.frameBytes + 32)
            throw new Error('Scrcpy buffer exceeded');
        this.pending = Buffer.concat([this.pending, bytes]);
        if (!this.codec) {
            if (this.pending.length < 4)
                return;
            if (this.pending.readUInt32BE() !== 0x68323634)
                throw new Error('Expected scrcpy H.264');
            this.codec = true;
            this.pending = this.pending.subarray(4);
        }
        while (this.pending.length >= 12) {
            if (this.pending[0]! & 128) {
                const width = this.pending.readUInt32BE(4), height = this.pending.readUInt32BE(8);
                if (this.pending.readUInt32BE(0) > 0x80000001 || !width || !height || width > 4096 || height > 4096)
                    throw new Error('Invalid scrcpy session');
                this.metadata({ type: 'video', codec: 'h264', width, height });
                this.session = true;
                this.pending = this.pending.subarray(12);
                continue;
            }
            if (!this.session)
                throw new Error('Scrcpy frame before session');
            const size = this.pending.readUInt32BE(8);
            if (!size || size > NATIVE.frameBytes)
                throw new Error('Invalid scrcpy packet size');
            if (this.pending.length < size + 12)
                return;
            const packet = Buffer.from(this.pending.subarray(0, size + 12));
            nativeFrame(packet);
            this.frame(packet);
            this.pending = this.pending.subarray(size + 12);
        }
    }
}
export function scrcpyInput(input: NativeInput): Buffer {
    const v = parseNativeInput(input);
    if (v.type === 'text') {
        const text = Buffer.from(v.text);
        const packet = Buffer.alloc(5 + text.length);
        packet[0] = 1;
        packet.writeUInt32BE(text.length, 1);
        text.copy(packet, 5);
        return packet;
    }
    if (v.type === 'key') {
        const key = { back: 4, home: 3, enter: 66, backspace: 67 }[v.key];
        const packet = Buffer.alloc(28);
        packet[15] = 1;
        packet.writeUInt32BE(key, 2);
        packet.writeUInt32BE(key, 16);
        return packet;
    }
    const touch = v.type === 'touch';
    const packet = Buffer.alloc(touch ? 32 : 21);
    packet[0] = touch ? 2 : 3;
    const offset = touch ? 10 : 1;
    packet.writeUInt32BE(Math.min(v.width - 1, Math.round(v.x * v.width)), offset);
    packet.writeUInt32BE(Math.min(v.height - 1, Math.round(v.y * v.height)), offset + 4);
    packet.writeUInt16BE(v.width, offset + 8);
    packet.writeUInt16BE(v.height, offset + 10);
    if (touch) {
        packet[1] = { down: 0, up: 1, move: 2, cancel: 3 }[v.action];
        packet.writeBigUInt64BE(0n, 2);
        packet.writeUInt16BE(v.action === 'up' || v.action === 'cancel' ? 0 : 65535, 22);
        // Finger input, no mouse buttons.
    }
    else
        packet.writeInt16BE(Math.max(-32768, Math.min(32767, Math.round(v.delta * 32768 / 16))), 15);
    return packet;
}
