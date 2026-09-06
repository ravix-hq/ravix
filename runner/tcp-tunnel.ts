import type { Duplex } from "node:stream";

/** Experimental TCP framing for Metro and named app services. Video/input must
 * use separate channels. Credit is returned only after the destination accepts
 * a write, so a stalled destination cannot grow an unbounded JS receive queue. */
export const TCP_TUNNEL = { version: 1, window: 64 * 1024, frame: 16 * 1024, sourceChunk: 1024 * 1024 } as const;
export interface TunnelWire {
  send(data: string | Uint8Array): unknown;
  close(code: number, reason: string): void;
}

export class TcpTunnel {
  private ready = false;
  private closed = false;
  private credit = 0;
  private receiving = TCP_TUNNEL.window as number;
  private inFlight = 0;
  private writes = 0;
  private pending: Buffer | null = null;
  private sourceEnded = false;
  private sentEnd = false;
  private receivedEnd = false;
  private handshake: ReturnType<typeof setTimeout>;
  private pingTimer: ReturnType<typeof setInterval>;
  private awaitingPong = false;
  private messages = 0;
  private intervalAt = Date.now();
  readonly done: Promise<void>;
  private finish!: () => void;
  private abort = () => this.stop("Assignment ended");

  constructor(private stream: Duplex, private wire: TunnelWire, private signal: AbortSignal) {
    this.done = new Promise(resolve => { this.finish = resolve; });
    stream.pause();
    stream.on("data", this.data);
    stream.on("end", this.end);
    stream.on("error", this.error);
    stream.on("close", this.streamClosed);
    stream.once("finish", () => this.complete());
    signal.addEventListener("abort", this.abort, { once: true });
    this.handshake = setTimeout(() => this.stop("Tunnel handshake timed out"), 10_000);
    this.handshake.unref();
    this.pingTimer = setInterval(() => {
      if (!this.ready || this.closed) return;
      if (this.awaitingPong) { this.stop("Tunnel heartbeat timed out"); return; }
      this.awaitingPong = true; this.send(JSON.stringify({ type: "ping" }));
    }, 15_000);
    this.pingTimer.unref();
    if (signal.aborted) this.abort();
  }
  start() { this.send(JSON.stringify({ type: "ready", version: TCP_TUNNEL.version, window: TCP_TUNNEL.window })); }
  private send(data: string | Uint8Array) {
    if (this.closed) return;
    try { this.wire.send(data); }
    catch { this.stop("Tunnel send failed"); }
  }
  /** The WebSocket owner must cap wire messages at TCP_TUNNEL.frame bytes. */
  message(data: string | Buffer | ArrayBuffer | Uint8Array) {
    if (this.closed) return;
    const now = Date.now();
    if (now - this.intervalAt >= 1000) { this.messages = 0; this.intervalAt = now; }
    if (++this.messages > 4096) { this.stop("Tunnel message limit exceeded"); return; }
    if (typeof data === "string") {
      if (data.length > 256) { this.stop("Invalid tunnel control"); return; }
      try {
        const msg = JSON.parse(data);
        if (!msg || typeof msg !== "object" || Array.isArray(msg)) throw new Error();
        if (!this.ready) {
          if (msg.type !== "ready" || msg.version !== TCP_TUNNEL.version || msg.window !== TCP_TUNNEL.window) throw new Error();
          this.ready = true; this.credit = msg.window; clearTimeout(this.handshake); this.pump(); return;
        }
        if (msg.type === "ack") {
          if (!Number.isSafeInteger(msg.bytes) || msg.bytes <= 0 || msg.bytes > this.inFlight) throw new Error();
          this.inFlight -= msg.bytes; this.credit += msg.bytes; this.pump(); this.complete(); return;
        }
        if (msg.type === "end" && !this.receivedEnd) {
          this.receivedEnd = true; this.stream.end(() => this.complete()); this.complete(); return;
        }
        if (msg.type === "ping") { this.send(JSON.stringify({ type: "pong" })); return; }
        if (msg.type === "pong" && this.awaitingPong) { this.awaitingPong = false; return; }
        throw new Error();
      } catch { this.stop("Invalid tunnel control"); }
      return;
    }
    const bytes = Buffer.from(data instanceof ArrayBuffer ? new Uint8Array(data) : data);
    if (!this.ready || this.receivedEnd || !bytes.length || bytes.length > TCP_TUNNEL.frame || bytes.length > this.receiving) { this.stop("Invalid tunnel data"); return; }
    this.receiving -= bytes.length; this.writes++;
    this.stream.write(bytes, error => {
      this.writes--;
      if (this.closed) return;
      if (error) { this.stop("Destination write failed"); return; }
      this.receiving += bytes.length;
      this.send(JSON.stringify({ type: "ack", bytes: bytes.length }));
      this.complete();
    });
  }
  private data = (chunk: Buffer) => {
    this.stream.pause();
    if (this.pending || !Buffer.isBuffer(chunk) || chunk.length > TCP_TUNNEL.sourceChunk) { this.stop("Source buffer limit exceeded"); return; }
    this.pending = chunk; this.pump();
  };
  private pump() {
    if (this.closed || !this.ready) return;
    while (this.pending?.length && this.credit > 0 && !this.closed) {
      const size = Math.min(this.pending.length, this.credit, TCP_TUNNEL.frame);
      const frame = this.pending.subarray(0, size);
      this.pending = size === this.pending.length ? null : this.pending.subarray(size);
      this.credit -= size; this.inFlight += size; this.send(frame);
    }
    if (!this.pending) {
      if (this.sourceEnded && !this.sentEnd && this.inFlight === 0) { this.sentEnd = true; this.send(JSON.stringify({ type: "end" })); this.complete(); }
      else if (!this.sourceEnded && this.credit > 0) this.stream.resume();
    }
  }
  private end = () => { this.sourceEnded = true; this.pump(); };
  private error = () => this.stop("TCP connection failed");
  private streamClosed = () => {
    if (!this.stream.readableEnded || !this.stream.writableFinished) this.stop("TCP connection closed early");
    else this.complete();
  };
  private complete() { if (this.sentEnd && this.receivedEnd && this.inFlight === 0 && this.writes === 0 && this.stream.writableFinished) this.stop("Complete", 1000); }
  stop(reason = "Tunnel closed", code = 1008) {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.handshake); clearInterval(this.pingTimer);
    this.signal.removeEventListener("abort", this.abort);
    this.stream.off("data", this.data); this.stream.off("end", this.end); this.stream.off("close", this.streamClosed);
    // Keep the error listener during asynchronous destroy completion.
    this.stream.destroy(); this.pending = null;
    try { this.wire.close(code, reason); } catch { /* Already disconnected. */ }
    this.finish();
  }
}
