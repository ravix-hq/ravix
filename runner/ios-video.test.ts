import { expect, test } from 'bun:test';
import { IosVideo, annexBNals, spsDimensions } from './ios-video';
import { IosBridgeFrames } from './ios-live';
import { iosNode, iosStartupAction } from './ios-runtime';
import { nativeFrame, avcCodec, type NativeVideo, NATIVE } from '../shared/native-preview';
import { parsePreviewExperiment } from './preview-experiment';
// SPS/PPS from a 360x640 baseline H.264 encoder, not a fabricated SPS.
const sps = Buffer.from('6742c01ed9017051e5f0110000030001000003003c0f162e48', 'hex');
const config = Buffer.concat([Buffer.from('00000001','hex'), sps, Buffer.from('0000000168cb83cb20','hex')]);
const key = Buffer.concat([config, Buffer.from('000001658884','hex')]);
const envelope = (kind: number, payload: Buffer) => { const head=Buffer.alloc(5);head[0]=kind;head.writeUInt32BE(payload.length,1);return Buffer.concat([head,payload]); };
test('idb access units become browser-decodable config and key/delta packets', () => {
  const packets: Buffer[] = [], metadata: NativeVideo[] = [];
  const video = new IosVideo(m => metadata.push(m), b => packets.push(b));
  video.push(key, 1000);
  expect(metadata).toEqual([{type:'video',codec:'h264',width:360,height:640}]);
  expect(nativeFrame(packets[0]!).config).toBe(true);
  expect(avcCodec(nativeFrame(packets[0]!).data)).toBe('avc1.42c01e');
  expect(nativeFrame(packets[1]!)).toMatchObject({key:true,config:false,timestamp:1000});
  video.push(Buffer.from('00000001419a','hex'), 2000);
  expect(nativeFrame(packets[2]!)).toMatchObject({key:false,timestamp:2000});
  video.push(key, 3000);
  expect(metadata).toHaveLength(1); expect(packets).toHaveLength(4);
  expect(() => video.push(key, 3000)).toThrow('Invalid');
  expect(() => new IosVideo(()=>{},()=>{}).push(Buffer.from('000001419a','hex'),1)).toThrow('SPS/PPS');
});
test('SPS dimensions include crop and reject truncated or oversized data', () => {
  expect(spsDimensions(sps)).toEqual({width:360,height:640});
  expect(spsDimensions(Buffer.from('6764001facd940940a1eab0110000003001000000303c0f183196', 'hex'))).toEqual({width:590,height:1278});
  expect(() => spsDimensions(sps.subarray(0,3))).toThrow('Truncated');
  expect(() => annexBNals(Buffer.from('garbage'))).toThrow('Annex-B');
  const video=new IosVideo(()=>{},()=>{});
  expect(() => video.push(Buffer.alloc(NATIVE.frameBytes+1),1)).toThrow('Invalid');
});
test('pipe chunking preserves gRPC access-unit boundaries and enforces envelope limits', () => {
  const identity=Buffer.from('{"udid":"fixture"}'), data=Buffer.concat([Buffer.alloc(8),key]);
  const bytes=Buffer.concat([envelope(1,identity),envelope(2,data),envelope(2,data)]);
  for (const chunkSize of [1,2,4,5,11,bytes.length]) {
    const received: [number,Buffer][]=[];const parser=new IosBridgeFrames((k,b)=>received.push([k,b]));
    for(let i=0;i<bytes.length;i+=chunkSize) parser.push(bytes.subarray(i,i+chunkSize));
    parser.end(); expect(received).toEqual([[1,identity],[2,data],[2,data]]);
  }
  expect(()=>new IosBridgeFrames(()=>{}).push(envelope(3,identity))).toThrow('envelope');
  const header=Buffer.alloc(5);header[0]=2;header.writeUInt32BE(NATIVE.frameBytes+1,1);
  expect(()=>new IosBridgeFrames(()=>{}).push(header)).toThrow('envelope');
  const partial=new IosBridgeFrames(()=>{});partial.push(bytes.subarray(0,8));
  expect(()=>partial.end()).toThrow('Truncated');
});
test('iOS accessibility coordinates use exact labels and bounded point frames', () => {
  const node=(AXLabel:string)=>({AXLabel,frame:{x:10,y:30,width:100,height:40}});
  expect(iosNode(JSON.stringify([node('Call backend')]),'Call backend')).toEqual({x:60,y:50});
  expect(iosNode(JSON.stringify([node('Call backend now')]),'Call backend')).toBeNull();
  expect(iosNode(JSON.stringify([{...node('Call backend'),frame:{x:0,y:0,width:9000,height:40}}]),'Call backend')).toBeNull();
  expect(iosNode(JSON.stringify({children:[node('Hello, world!')]}),'Hello, world!')).toEqual({x:60,y:50});
  expect(iosStartupAction(JSON.stringify([node('Continue')]))).toBeNull();
  expect(iosStartupAction(JSON.stringify(['Switchyard Hello','Reload','Go home','Close'].map(node)))).toEqual({x:60,y:50});
});
test('preview platform is explicit while older Android pairing files remain valid', () => {
  const base={expectedAccount:'switchyard',buildDirectory:'/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041',artifactSha256:'a'.repeat(64),serverUrl:'https://switchyard.demo.managoat.com',pairingCode:'p'.repeat(43)};
  expect(parsePreviewExperiment(base).platform).toBeUndefined();
  expect(parsePreviewExperiment({...base,platform:'ios'}).platform).toBe('ios');
  expect(()=>parsePreviewExperiment({...base,platform:'macos'})).toThrow('android or ios');
});
