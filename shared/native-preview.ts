/** Gate-2 native experiment. These limits also apply before decoding payloads. */
export const NATIVE = { version: 1, frameBytes: 2 * 1024 * 1024, configBytes: 128 * 1024, metroPort: 41000, backendPort: 41001, leaseMs: 60000, lifetimeMs: 30 * 60000 } as const;
export type NativeInput = {
    type: 'touch';
    action: 'down' | 'move' | 'up' | 'cancel';
    x: number;
    y: number;
    width: number;
    height: number;
} | {
    type: 'scroll';
    x: number;
    y: number;
    width: number;
    height: number;
    delta: number;
} | {
    type: 'text';
    text: string;
} | {
    type: 'key';
    key: 'back' | 'home' | 'enter' | 'backspace';
};
export interface NativeVideo {
    type: 'video';
    codec: 'h264';
    width: number;
    height: number;
}
export type NativePlatform = "android" | "ios";
export interface NativeInfo {
    platform: NativePlatform;
    id: string;
    trackId: string;
    phase: string;
    error: string | null;
    expiresAt: number;
    runnerOnline: boolean;
    video: NativeVideo | null;
    frames: number;
    pairingCode?: string;
}
export function parseNativeInput(value: unknown): NativeInput {
    const v = value as NativeInput;
    if (!v || typeof v !== 'object')
        throw new Error('Invalid input');
    if (v.type === 'text' && typeof v.text === 'string' && v.text.length > 0 && new TextEncoder().encode(v.text).length <= 300 && !/[\u0000-\u001f\u007f]/.test(v.text))
        return { type: v.type, text: v.text };
    if (v.type === 'key' && ['back', 'home', 'enter', 'backspace'].includes(v.key))
        return { type: v.type, key: v.key };
    if (v.type === 'touch' || v.type === 'scroll') {
        if (![v.x, v.y].every(n => Number.isFinite(n) && n >= 0 && n <= 1) || ![v.width, v.height].every(n => Number.isInteger(n) && n > 0 && n <= 4096))
            throw new Error('Invalid coordinates');
        const position = { x: v.x, y: v.y, width: v.width, height: v.height };
        if (v.type === 'touch' && ['down', 'move', 'up', 'cancel'].includes(v.action))
            return { type: v.type, action: v.action, ...position };
        if (v.type === 'scroll' && Number.isFinite(v.delta) && Math.abs(v.delta) <= 16)
            return { type: v.type, delta: v.delta, ...position };
    }
    throw new Error('Unsupported input');
}
/** scrcpy 4.1 media packet, including the original PTS and config/key flags. */
export function nativeFrame(bytes: Uint8Array) {
    if (bytes.byteLength < 13 || bytes.byteLength > NATIVE.frameBytes + 12)
        throw new Error('Invalid frame size');
    const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const flags = data.getBigUint64(0);
    const config = !!(flags & (1n << 62n)), key = !!(flags & (1n << 61n));
    const timestamp = Number(flags & ((1n << 61n) - 1n));
    if (flags >> 63n || data.getUint32(8) !== bytes.byteLength - 12 || !Number.isSafeInteger(timestamp) || (config && bytes.byteLength > NATIVE.configBytes))
        throw new Error('Invalid media packet');
    return { config, key, timestamp, data: bytes.subarray(12) };
}
export function avcCodec(bytes: Uint8Array): string {
    for (let i = 0; i + 7 < bytes.length; i++) {
        const start = bytes[i] === 0 && bytes[i + 1] === 0 ? (bytes[i + 2] === 1 ? i + 3 : bytes[i + 2] === 0 && bytes[i + 3] === 1 ? i + 4 : -1) : -1;
        if (start >= 0 && (bytes[start]! & 31) === 7 && start + 3 < bytes.length)
            return 'avc1.' + [...bytes.subarray(start + 1, start + 4)].map(n => n.toString(16).padStart(2, '0')).join('');
    }
    throw new Error('H.264 configuration has no SPS');
}
