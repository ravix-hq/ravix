import * as ws from "ws-node";
import { Duplex, Writable } from "node:stream";
import { Client } from "undici-node";
import { createHash, randomBytes } from "node:crypto";
import type { Socket } from "node:net";
import type { SpritesConfig } from "./sprites";

// ws exports its RFC6455 framing primitives; its typings only describe the
// high-level client, whose node:http upgrade path Bun does not implement.
export const framing = ws as unknown as {
  Receiver: new (options: Record<string, unknown>) => Writable;
  Sender: new (socket: Duplex) => {
    send(data: Buffer | string, options: Record<string, unknown>, callback: (error?: Error) => void): void;
    pong(data: Buffer, mask: boolean, callback: (error?: Error) => void): void;
  };
};

/** Real TCP over /proxy: HTTP upgrade, JSON connected acknowledgement, then
 * binary frames. Socket pause/resume and write callbacks bound both directions. */
export async function spriteTunnel(cfg: SpritesConfig, sprite: string, port: number, signal?: AbortSignal): Promise<Duplex> {
  const url = new URL(cfg.baseUrl);
  const client = new Client(url.origin, { headersTimeout: 15_000 });
  const key = randomBytes(16).toString("base64");
  const timeout = AbortSignal.timeout(15_000);
  const handshakeSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
  let socket: Duplex;
  try {
    const upgraded = await client.upgrade({ path: `${url.pathname.replace(/\/$/, "")}/v1/sprites/${encodeURIComponent(sprite)}/proxy`,
      protocol: "websocket", headers: { authorization: `Bearer ${cfg.token}`, "sec-websocket-key": key, "sec-websocket-version": "13" }, signal: handshakeSignal });
    socket = upgraded.socket;
    const expected = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    if (upgraded.headers["sec-websocket-accept"] !== expected) { socket.destroy(); throw new Error("Invalid Sprites WebSocket handshake."); }
  } catch (error) { await client.destroy(); throw error; }
  const receiver = new framing.Receiver({ isServer: false, binaryType: "nodebuffer", maxPayload: 1024 * 1024 });
  const sender = new framing.Sender(socket);
  return new Promise((resolve, reject) => {
    let connected = false;
    const timer = setTimeout(() => fail(new Error("Sprites tunnel acknowledgement timed out.")), 15_000);
    const stream = new Duplex({ highWaterMark: 64 * 1024,
      read() { socket.resume(); },
      write(chunk, _encoding, done) { sender.send(chunk, { binary: true, mask: true, fin: true, compress: false }, done); },
      final(done) { socket.end(); done(); },
      destroy(error, done) {
        clearTimeout(timer); signal?.removeEventListener("abort", abort); socket.destroy(); receiver.destroy();
        void client.destroy(); done(error);
      },
    });
    stream.on("error", () => {});
    const fail = (error: Error) => { reject(error); stream.destroy(error); };
    const abort = () => fail(new Error("Preview tunnel ended."));
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) { abort(); return; }
    socket.on("data", (chunk: Buffer) => { if (!receiver.write(chunk)) socket.pause(); });
    receiver.on("drain", () => { if (stream.readableLength < stream.readableHighWaterMark) socket.resume(); });
    receiver.on("message", (data: Buffer, binary: boolean) => {
      if (!connected) {
        try {
          if (binary || JSON.parse(data.toString()).status !== "connected") throw new Error("Sprites refused the preview port.");
          connected = true; clearTimeout(timer); resolve(stream);
        } catch { fail(new Error("Sprites refused the preview port.")); }
      } else { if (binary && !stream.push(data)) socket.pause(); }
    });
    receiver.on("ping", (data: Buffer) => sender.pong(data, true, error => { if (error) fail(error); }));
    receiver.on("conclude", () => { stream.push(null); socket.end(); });
    receiver.on("error", fail); socket.on("error", fail);
    socket.once("close", () => {
      if (!connected) reject(new Error("Sprites closed the tunnel before connecting."));
      stream.push(null); stream.destroy();
    });
    sender.send(JSON.stringify({ host: "127.0.0.1", port }), { binary: false, mask: true, fin: true, compress: false }, error => { if (error) fail(error); });
  });
}

/** undici accepts a custom stream, unlike Bun's node:http compatibility API. */
export function previewClient(stream: Duplex): Client {
  return new Client("http://127.0.0.1", { bodyTimeout: 0, headersTimeout: 30_000,
    connect(_options, callback) { queueMicrotask(() => callback(null, stream as Socket)); },
  });
}
