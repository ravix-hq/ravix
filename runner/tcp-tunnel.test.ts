import { afterEach, expect, test } from "bun:test";
import { Duplex } from "node:stream";
import { connect } from "node:net";
import { spawn } from "node:child_process";
import { command } from "./process";
import { createHash } from "node:crypto";
import { TcpTunnel, TCP_TUNNEL } from "./tcp-tunnel";
import { reserveLoopbackForward, validateForwardEndpoint } from "./loopback-forward";
import { createNativeForwardGateway } from "../server/native-forward-gateway";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const close of cleanups.splice(0).reverse()) close(); });
const token = "test_session_credential_" + "x".repeat(32);
const ready = JSON.stringify({ type: "ready", version: TCP_TUNNEL.version, window: TCP_TUNNEL.window });
async function fixture(mode: "echo" | "http" = "echo") {
  const controller = new AbortController();
  const seen: string[] = [];
  // The app and Sprite are separate processes. Bun 1.3.11's same-process
  // net client/server pair can close before the server accepts a half-close.
  const child = spawn("node", ["-e", `
    const {createServer}=require('node:net');
    const {createHash}=require('node:crypto');
    const server=createServer({allowHalfOpen:true},socket=>{
      socket.on('error',()=>{});
      let pending=Buffer.alloc(0),upgraded=false;
      socket.on('data',data=>{
        if (${JSON.stringify(mode)}==='echo'||upgraded){socket.write(data);return;}
        pending=Buffer.concat([pending,data]);
        const end=pending.indexOf('\\r\\n\\r\\n'); if(end<0)return;
        const request=pending.subarray(0,end+4).toString();console.log(JSON.stringify({request}));
        if(request.startsWith('GET /hot ')){
          const key=request.match(/Sec-WebSocket-Key: (.+)\\r\\n/i)[1];
          const accept=createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
          socket.write('HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: '+accept+'\\r\\n\\r\\n');upgraded=true;
          if(pending.length>end+4)socket.write(pending.subarray(end+4));
        }else socket.end('HTTP/1.1 200 OK\\r\\nContent-Length: 6\\r\\nConnection: close\\r\\n\\r\\nbundle');
      });
      socket.on('end',()=>socket.end());
    });
    server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({port:server.address().port})));
  `], { stdio: ["ignore", "pipe", "pipe"] });
  cleanups.push(() => child.kill("SIGTERM"));
  let output = "";
  const address = await new Promise<{ port: number }>((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", () => reject(new Error("Upstream fixture exited")));
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString();
      while (output.includes("\n")) {
        const end = output.indexOf("\n"), line = output.slice(0, end); output = output.slice(end + 1);
        const event = JSON.parse(line);
        if (event.port) resolve({ port: event.port }); else if (event.request) seen.push(event.request);
      }
    });
  });
  let authorized = 0;
  const gateway = createNativeForwardGateway(async request => {
    if (request.headers.get("authorization") !== `Bearer ${token}` || new URL(request.url).pathname !== "/session/one/metro") return null;
    authorized++;
    return { signal: controller.signal, connect: () => new Promise<Duplex>((resolve, reject) => {
      const peer = spawn("node", ["-e", `
        const socket=require('node:net').connect({host:'127.0.0.1',port:Number(process.argv[1]),allowHalfOpen:true});
        socket.on('connect',()=>{process.stderr.write('connected\\n');process.stdin.pipe(socket);socket.pipe(process.stdout);});
        socket.on('error',()=>process.exit(1));
      `, String(address.port)], { stdio: ["pipe", "pipe", "pipe"] });
      cleanups.push(() => peer.kill("SIGTERM"));
      peer.once("error", reject); peer.once("exit", () => reject(new Error("TCP peer exited")));
      peer.stderr.once("data", () => {
        const stream = new Duplex({
          read() { peer.stdout.resume(); },
          write(chunk, encoding, done) { peer.stdin.write(chunk, encoding, done); },
          final(done) { peer.stdin.end(done); },
          destroy(error, done) { peer.kill("SIGTERM"); done(error); },
        });
        peer.stdout.on("data", chunk => { if (!stream.push(chunk)) peer.stdout.pause(); });
        peer.stdout.on("end", () => stream.push(null));
        peer.stdout.on("error", error => stream.destroy(error));
        peer.stdin.on("error", error => stream.destroy(error));
        resolve(stream);
      });
    }) };

  });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: gateway.fetch, websocket: gateway.websocket });
  const endpoint = `ws://127.0.0.1:${server.port}/session/one/metro`;
  const forward = await reserveLoopbackForward({ signal: controller.signal });
  forward.activate({endpoint, token});
  cleanups.push(() => { controller.abort(); forward.close(); gateway.stop(); server.stop(true); child.kill("SIGTERM"); });
  return { controller, endpoint, forward, seen, authorized: () => authorized };
}
async function exchange(port: number, bytes: Buffer) {
  const result = await command(["node", "-e", `
    const chunks=[];process.stdin.on('data',d=>chunks.push(d));process.stdin.on('end',()=>{
      const socket=require('node:net').connect({port:Number(process.argv[1]),host:'127.0.0.1',allowHalfOpen:true});
      socket.on('connect',()=>socket.end(Buffer.from(Buffer.concat(chunks).toString(),'base64')));
      socket.on('data',d=>process.stdout.write(d));socket.on('end',()=>socket.end());
      socket.on('error',()=>process.exit(1));
    });
  `, String(port)], { input: bytes.toString("base64"), maxBytes: 2 * 1024 * 1024, timeoutMs: 5000 });
  expect(result.code).toBe(0); return result.stdout;
}

test("private TCP forwarding preserves a large binary exchange and half-close", async () => {
  const f = await fixture();
  const bytes = Buffer.alloc(1024 * 1024 + 731); for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
  const received = await exchange(f.forward.port, bytes);
  expect(received.length).toBe(bytes.length);
  expect(createHash("sha256").update(received).digest("hex")).toBe(createHash("sha256").update(bytes).digest("hex"));
  expect(f.authorized()).toBe(1);
});

test("HTTP and nested HMR WebSocket upgrades pass without rewriting app bytes", async () => {
  const f = await fixture("http");
  const seen = f.seen;
  const result = await fetch(`http://127.0.0.1:${f.forward.port}/index.bundle?platform=android`);
  expect(await result.text()).toBe("bundle");
  // Send raw RFC6455 bytes through the upgraded connection, including NUL and
  // high bytes. The outer transport must preserve the inner framing verbatim.
  await new Promise<void>((resolve, reject) => {
    const socket = connect({ host: "127.0.0.1", port: f.forward.port });
    const timer = setTimeout(() => { socket.destroy(); reject(new Error("HMR timeout")); }, 5000);
    let response = Buffer.alloc(0), upgraded = false;
    const frame = Buffer.from([0x82, 0x04, 0x00, 0xff, 0x80, 0x41]);
    socket.on("error", reject);
    socket.on("connect", () => socket.write("GET /hot HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"));
    socket.on("data", (data: Buffer) => {
      response = Buffer.concat([response, data]);
      if (!upgraded) {
        const end = response.indexOf("\r\n\r\n"); if (end < 0) return;
        expect(response.toString()).toContain("101 Switching Protocols"); response = response.subarray(end + 4); upgraded = true; socket.write(frame);
      }
      if (response.length >= frame.length) { clearTimeout(timer); expect(response).toEqual(frame); socket.destroy(); resolve(); }
    });
  });
  expect(seen).toHaveLength(2);
  expect(seen.join("")).not.toContain(token);
});

test("revocation closes active forwarding and refuses new connections", async () => {
  const f = await fixture();
  const socket = connect({ host: "127.0.0.1", port: f.forward.port });
  await new Promise<void>(resolve => { socket.on("connect", () => socket.write("hello")); socket.once("data", () => resolve()); });
  const closed = new Promise<void>(resolve => socket.once("close", () => resolve()));
  f.controller.abort();
  await closed;
  await expect(fetch(`http://127.0.0.1:${f.forward.port}/`)).rejects.toThrow();
});

test("runner channel rejects missing credentials, browser origins and wrong session paths", async () => {
  const f = await fixture();
  const Client = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
  for (const [endpoint, headers] of [
    [f.endpoint, {}], [f.endpoint, { authorization: `Bearer ${token}`, origin: "https://switchyard.example" }],
    [f.endpoint.replace("/one/", "/other/"), { authorization: `Bearer ${token}` }],
  ] as [string, Record<string, string>][]) {
    await new Promise<void>((resolve, reject) => {
      const ws = new Client(endpoint, { headers });
      ws.onopen = () => { ws.close(); reject(new Error("Unauthorized upgrade accepted")); };
      ws.onerror = () => resolve(); ws.onclose = () => resolve();
    });
  }
  expect(f.authorized()).toBe(0);
  expect(() => validateForwardEndpoint("ws://example.com/channel")).toThrow();
  expect(() => validateForwardEndpoint("wss://example.com/channel?token=secret")).toThrow();
  expect(() => validateForwardEndpoint("wss://user:pass@example.com/channel")).toThrow();
});

test("credit limits a stalled destination and invalid acknowledgements fail closed", () => {
  let writes = 0;
  const stream = new Duplex({ read() {}, write(_chunk, _encoding, _done) { writes++; /* Intentionally stalled. */ } });
  const closes: string[] = [];
  const tunnel = new TcpTunnel(stream, { send() {}, close(_code, reason) { closes.push(reason); } }, new AbortController().signal);
  tunnel.start(); tunnel.message(ready);
  for (let i = 0; i < 4; i++) tunnel.message(Buffer.alloc(TCP_TUNNEL.frame));
  expect(writes).toBe(1); expect(stream.writableLength).toBe(TCP_TUNNEL.window);
  tunnel.message(Buffer.from([1])); expect(closes).toEqual(["Invalid tunnel data"]);
  const other = new Duplex({ read() {}, write(_chunk, _encoding, done) { done(); } });
  const rejected = new TcpTunnel(other, { send() {}, close(_code, reason) { closes.push(reason); } }, new AbortController().signal);
  rejected.start(); rejected.message(ready); rejected.message(JSON.stringify({ type: "ack", bytes: 1 }));
  expect(closes.at(-1)).toBe("Invalid tunnel control");
});
