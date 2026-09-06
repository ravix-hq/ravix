import { expect, test } from 'bun:test';
import { ScrcpyVideo, scrcpyInput } from './scrcpy-protocol';
import { avcCodec, nativeFrame, parseNativeInput } from '../shared/native-preview';
const session = Buffer.from('68323634800000000000024000000500', 'hex');
function packet(data: Buffer, flags = 0n) { const header = Buffer.alloc(12); header.writeBigUInt64BE(flags); header.writeUInt32BE(data.length, 8); return Buffer.concat([header, data]); }
test('scrcpy 4.1 packets survive arbitrary TCP fragmentation and retain original timestamps', () => {
    const config = packet(Buffer.from('000000016742c01eda0280b7fe5c05050502', 'hex'), 1n << 62n), key = packet(Buffer.from('000000016588', 'hex'), (1n << 61n) | 123456n);
    for (const stride of [1, 2, 3, 7, 16, 1000]) {
        const videos: unknown[] = [], frames: Buffer[] = [];
        const parser = new ScrcpyVideo(v => videos.push(v), p => frames.push(p));
        const all = Buffer.concat([session, config, key]);
        for (let i = 0; i < all.length; i += stride)
            parser.push(all.subarray(i, i + stride));
        expect(videos).toEqual([{ type: 'video', codec: 'h264', width: 576, height: 1280 }]);
        expect(frames).toEqual([config, key]);
        expect(nativeFrame(frames[1]!).timestamp).toBe(123456);
        expect(avcCodec(nativeFrame(frames[0]!).data)).toBe('avc1.42c01e');
    }
});
test('packet boundaries and codec metadata fail closed', () => {
    for (const bytes of [Buffer.from('00617631', 'hex'), Buffer.concat([session, Buffer.from('000000000000000000200001', 'hex')]), Buffer.concat([session.subarray(0, 4), packet(Buffer.from([1]))])])
        expect(() => new ScrcpyVideo(() => { }, () => { }).push(bytes)).toThrow();
    expect(() => nativeFrame(Buffer.alloc(12))).toThrow();
    expect(() => avcCodec(Buffer.alloc(32))).toThrow();
});
test('normalized touch input uses the actual frame dimensions and cancels the same pointer', () => {
    const down = scrcpyInput({ type: 'touch', action: 'down', x: 1, y: 1, width: 576, height: 1280 });
    expect(down.length).toBe(32);
    expect(down[0]).toBe(2);
    expect(down[1]).toBe(0);
    expect(down.readUInt32BE(10)).toBe(575);
    expect(down.readUInt32BE(14)).toBe(1279);
    expect(down.readUInt16BE(18)).toBe(576);
    expect(down.readUInt16BE(22)).toBe(65535);
    const cancel = scrcpyInput({ type: 'touch', action: 'cancel', x: 0, y: 0, width: 576, height: 1280 });
    expect(cancel[1]).toBe(3);
    expect(cancel.readBigUInt64BE(2)).toBe(down.readBigUInt64BE(2));
    expect(cancel.readUInt16BE(22)).toBe(0);
    expect(scrcpyInput({ type: 'text', text: 'hello, world!' }).toString('hex')).toBe('010000000d68656c6c6f2c20776f726c6421');
    expect(scrcpyInput({ type: 'key', key: 'enter' }).toString('hex')).toBe('00000000004200000000000000000001000000420000000000000000');
});
test('invalid coordinates, unsupported keys and oversized text never reach native control', () => {
    for (const input of [{ type: 'text', text: 'a'.repeat(301) }, { type: 'text', text: 'x\n' }, { type: 'key', key: 'shell' }, { type: 'touch', action: 'down', x: NaN, y: 0, width: 576, height: 1280 }, { type: 'touch', action: 'move', x: 1.1, y: 0, width: 576, height: 1280 }, { type: 'scroll', x: 0, y: 0, width: 576, height: 1280, delta: 17 }])
        expect(() => parseNativeInput(input)).toThrow();
});
