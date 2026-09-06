import type { Server, ServerWebSocket } from "bun";
import type { Duplex } from "node:stream";
import { TcpTunnel, TCP_TUNNEL } from "../runner/tcp-tunnel";

/** Supplied by session authorization, not by request parameters. The signal
 * must abort on lease expiry, sign-out, track closure or assignment revocation.
 * Production native session routes do not exist yet; this adapter is tested
 * independently before it is attached to Switchyard's server. */
export interface NativeForwardAssignment {
  signal: AbortSignal;
  connect(): Promise<Duplex>;
}
export interface NativeForwardPeer {
  assignment: NativeForwardAssignment;
  tunnel?: TcpTunnel;
  closed: boolean;
  abort?: () => void;
}
type Peer = NativeForwardPeer;
export type NativeForwardAuthorizer = (request: Request) => Promise<NativeForwardAssignment | null>;

export function createNativeForwardGateway(authorize: NativeForwardAuthorizer) {
  const peers = new Set<ServerWebSocket<Peer>>();
  const pendingReady = new WeakSet<ServerWebSocket<Peer>>();
  let closed = false;
  return {
    async fetch(request: Request, server: Server<Peer>): Promise<Response | undefined> {
      // Browsers use their own authorized viewer channel. This runner channel
      // requires a header credential; browser cookies alone never authorize it.
      if (closed) return new Response("Unavailable", { status: 503 });
      if (request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("Upgrade required", { status: 426 });
      if (request.headers.has("origin") || !/^Bearer [a-zA-Z0-9_-]{32,256}$/.test(request.headers.get("authorization") ?? "")) return new Response("Unauthorized", { status: 401 });
      const url = new URL(request.url);
      if (url.search) return new Response("Invalid channel", { status: 400 });
      let assignment: NativeForwardAssignment | null;
      try { assignment = await authorize(request); }
      catch { return new Response("Unauthorized", { status: 401 }); }
      if (!assignment || assignment.signal.aborted) return new Response("Unauthorized", { status: 401 });
      if (closed || peers.size >= 64) return new Response("Busy", { status: 503 });
      if (server.upgrade(request, { data: { assignment, closed: false } })) return;
      return new Response("Upgrade failed", { status: 400 });
    },
    websocket: {
      maxPayloadLength: TCP_TUNNEL.frame,
      backpressureLimit: 2 * TCP_TUNNEL.window,
      closeOnBackpressureLimit: true,
      idleTimeout: 60,
      open(ws: ServerWebSocket<Peer>) {
        if (closed || peers.size >= 64 || ws.data.assignment.signal.aborted) { ws.close(1008, "Assignment ended"); return; }
        peers.add(ws);
        ws.data.abort = () => { ws.data.closed = true; ws.data.tunnel?.stop("Assignment ended"); ws.close(1008, "Assignment ended"); };
        ws.data.assignment.signal.addEventListener("abort", ws.data.abort, { once: true });
        const timer = setTimeout(() => ws.data.abort?.(), 10_000); timer.unref();
        void ws.data.assignment.connect().then(stream => {
          clearTimeout(timer);
          if (closed || ws.data.closed || ws.data.assignment.signal.aborted) { stream.destroy(); return; }
          ws.data.tunnel = new TcpTunnel(stream, { send: data => ws.send(data), close: (code, reason) => ws.close(code, reason) }, ws.data.assignment.signal);
          ws.data.tunnel.start();
          if (pendingReady.delete(ws)) ws.data.tunnel.message(JSON.stringify({ type: "ready", version: TCP_TUNNEL.version, window: TCP_TUNNEL.window }));
        }).catch(() => { clearTimeout(timer); ws.close(1011, "Destination unavailable"); });
      },
      message(ws: ServerWebSocket<Peer>, data: string | Buffer) {
        if (ws.data.tunnel) ws.data.tunnel.message(data);
        // Client readiness can arrive while the authorized Sprite connection
        // opens. Buffer exactly one validated ready message, no payload.
        else if (!pendingReady.has(ws) && typeof data === "string" && data === JSON.stringify({ type: "ready", version: TCP_TUNNEL.version, window: TCP_TUNNEL.window })) {
          pendingReady.add(ws);
        } else ws.close(1008, "Destination not ready");
      },
      close(ws: ServerWebSocket<Peer>) {
        ws.data.closed = true; peers.delete(ws); pendingReady.delete(ws);
        if (ws.data.abort) ws.data.assignment.signal.removeEventListener("abort", ws.data.abort);
        ws.data.tunnel?.stop();
      },
    },
    stop() { closed = true; for (const ws of peers) { ws.data.abort?.(); ws.close(1001, "Server stopped"); } },
  };
}
