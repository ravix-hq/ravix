import { NATIVE, type NativeVideo } from '../shared/native-preview';

/** Dimensions from an H.264 SPS, including high-profile chroma and crop units. */
export function spsDimensions(nal: Uint8Array) {
  const bytes: number[] = [];
  for (let i = 1; i < nal.length; i++) {
    if (i >= 3 && nal[i] === 3 && nal[i - 1] === 0 && nal[i - 2] === 0) continue;
    bytes.push(nal[i]!);
  }
  let position = 0;
  const bits = (count: number): number => {
    if (count > 32 || position + count > bytes.length * 8) throw Error('Truncated SPS');
    let result = 0;
    for (let i = 0; i < count; i++, position++) result = result * 2 + ((bytes[position >> 3]! >> (7 - (position & 7))) & 1);
    return result;
  };
  const ue = () => { let zeros = 0; while (!bits(1)) if (++zeros > 24) throw Error('Invalid SPS integer'); return 2 ** zeros - 1 + bits(zeros); };
  const se = () => { const value = ue(); return value & 1 ? (value + 1) / 2 : -value / 2; };
  const profile = bits(8); bits(16); ue();
  let chroma = 1, separate = 0;
  if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profile)) {
    chroma = ue(); if (chroma > 3) throw Error('Unsupported SPS chroma');
    if (chroma === 3) separate = bits(1);
    ue(); ue(); bits(1);
    if (bits(1)) for (let i = 0; i < (chroma === 3 ? 12 : 8); i++) if (bits(1)) {
      let last = 8, next = 8;
      for (let j = 0; j < (i < 6 ? 16 : 64); j++) { if (next) next = (last + se() + 256) % 256; last = next || last; }
    }
  }
  ue(); const order = ue();
  if (order === 0) ue();
  else if (order === 1) { bits(1); se(); se(); const cycle = ue(); if (cycle > 255) throw Error('Invalid SPS cycle'); for (let i = 0; i < cycle; i++) se(); }
  else if (order !== 2) throw Error('Invalid SPS order');
  ue(); bits(1);
  const columns = ue() + 1, rows = ue() + 1, progressive = bits(1);
  if (!progressive) bits(1);
  bits(1);
  let left = 0, right = 0, top = 0, bottom = 0;
  if (bits(1)) { left = ue(); right = ue(); top = ue(); bottom = ue(); }
  const array = separate ? 0 : chroma;
  const cropX = array === 1 || array === 2 ? 2 : 1;
  const cropY = (array === 1 ? 2 : 1) * (2 - progressive);
  const width = columns * 16 - (left + right) * cropX, height = rows * 16 * (2 - progressive) - (top + bottom) * cropY;
  if (![width, height].every(n => Number.isInteger(n) && n > 0 && n <= 4096)) throw Error('Invalid SPS dimensions');
  return { width, height };
}
export function annexBNals(data: Buffer) {
  const starts: {offset: number; header: number}[] = [];
  for (let i = 0; i + 3 < data.length; i++) if (data[i] === 0 && data[i + 1] === 0) {
    const header = data[i + 2] === 1 ? i + 3 : data[i + 2] === 0 && data[i + 3] === 1 ? i + 4 : -1;
    if (header >= 0 && header < data.length) { starts.push({offset:i,header}); i = header; }
  }
  if (!starts.length || starts[0]!.offset !== 0) throw Error('Expected Annex-B access unit');
  return starts.map((start, i) => ({data:data.subarray(start.offset,starts[i + 1]?.offset ?? data.length), nal:data.subarray(start.header,starts[i + 1]?.offset ?? data.length)}));
}
const packet = (data: Buffer, flags: bigint) => { const header = Buffer.alloc(12); header.writeBigUInt64BE(flags); header.writeUInt32BE(data.length,8); return Buffer.concat([header,data]); };
/** Converts complete idb access units to the shared media contract. */
export class IosVideo {
  private config?: Buffer;
  private last = -1;
  constructor(private metadata: (video: NativeVideo) => void, private frame: (packet: Buffer) => void) {}
  push(data: Buffer, timestamp: number) {
    if (!data.length || data.length > NATIVE.frameBytes || !Number.isSafeInteger(timestamp) || timestamp <= this.last) throw Error('Invalid iOS video frame');
    const nals = annexBNals(data), parameters = nals.filter(n => [7,8].includes(n.nal[0]! & 31));
    const sps = parameters.find(n => (n.nal[0]! & 31) === 7), pps = parameters.find(n => (n.nal[0]! & 31) === 8);
    if (sps && pps) {
      const config = Buffer.concat(parameters.map(n => n.data));
      if (config.length > NATIVE.configBytes - 12) throw Error('iOS video configuration too large');
      if (!this.config?.equals(config)) {
        this.config = config;
        this.metadata({type:'video',codec:'h264',...spsDimensions(sps.nal)});
        this.frame(packet(config,1n << 62n));
      }
    }
    if (!this.config) throw Error('iOS video has no SPS/PPS');
    const vcl = nals.filter(n => [1,5].includes(n.nal[0]! & 31));
    if (!vcl.length) return;
    this.last = timestamp;
    this.frame(packet(data,BigInt(timestamp) | (vcl.some(n => (n.nal[0]! & 31) === 5) ? 1n << 61n : 0n)));
  }
}
