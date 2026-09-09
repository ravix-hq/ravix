/**
 * One port, two hosts.
 *
 * A hosting platform hands a web service exactly one HTTP listener, and
 * Render is no exception. The track-preview gateway (`preview-gateway.ts`) is
 * a node:http server that decides everything by the Host header —
 * `t-<id>.preview.ravix.sh` — and it has to see that header untouched, with
 * the browser's cookies and Origin beside it. So the gateway listens on
 * loopback, and this front, inside the app's own `Bun.serve`, hands it every
 * request whose Host is under `PREVIEW_DOMAIN`: plain requests through
 * `fetch` with the body and response streamed both ways, and WebSocket
 * upgrades through a client socket relayed frame for frame. Everything else
 * is the app.
 *
 * The gateway keeps its own auth, origin and cross-site checks, because this
 * front adds nothing to the trust model: it forwards headers as they came
 * and only ever connects to 127.0.0.1.
 */
import type { Server, ServerWebSocket } from "bun";
import type { AppContext } from "./context";

/** `ws.data` for a relayed preview socket; `preview` is the discriminant. */
export interface PreviewPeer {
  preview: true;
  /** The socket to the gateway. Open by the time the browser's socket is. */
  upstream: WebSocket;
  /** Frames the gateway sent before the browser's socket was open. */
  queued: (string | ArrayBuffer)[];
  socket: ServerWebSocket<PreviewPeer> | null;
}

/** Headers that describe this hop rather than the request. */
const HOP = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade"];
const HANDSHAKE = new Set([...HOP, "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-protocol"]);
/** The gateway bounds its own relay at 2 MiB of unsent frames; match it. */
const BACKLOG = 2 * 1024 * 1024;

export function createPreviewFront(ctx: AppContext, gatewayPort: number) {
  if (!ctx.config.previews) throw new Error("PREVIEW_DOMAIN is not configured.");
  const base = `127.0.0.1:${gatewayPort}`;

  /** Read live, as the gateway does, so both agree on what a preview host is. */
  function matches(request: Request): boolean {
    const cfg = ctx.config.previews;
    return !!cfg && (request.headers.get("host") ?? "").toLowerCase().endsWith(`.${cfg.domain}${cfg.publicPort}`);
  }

  async function proxy(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const headers = new Headers(request.headers);
    for (const name of HOP) headers.delete(name);
    const bodyless = request.method === "GET" || request.method === "HEAD";
    let upstream: Response;
    try {
      upstream = await fetch(`http://${base}${url.pathname}${url.search}`, {
        method: request.method,
        headers,
        body: bodyless ? undefined : request.body,
        redirect: "manual",
        signal: request.signal,
        // The gateway's answer goes back exactly as it came, encoding
        // included; re-inflating it here would lie about content-encoding.
        decompress: false,
      } as RequestInit);
    } catch {
      return new Response("The preview gateway did not answer.", { status: 502, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
    }
    const out = new Headers(upstream.headers);
    for (const name of HOP) out.delete(name);
    return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
  }

  async function relay(request: Request, server: Server<PreviewPeer>): Promise<Response | undefined> {
    const url = new URL(request.url);
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => { if (!HANDSHAKE.has(name)) headers[name] = value; });
    const protocols = request.headers.get("sec-websocket-protocol")?.split(",").map(s => s.trim()).filter(Boolean) ?? [];
    const upstream = new WebSocket(`ws://${base}${url.pathname}${url.search}`, { headers, protocols } as unknown as string[]);
    upstream.binaryType = "arraybuffer";
    const peer: PreviewPeer = { preview: true, upstream, queued: [], socket: null };
    const deliver = (frame: string | ArrayBuffer) => {
      if (!peer.socket) { peer.queued.push(frame); return; }
      peer.socket.send(frame);
      if (peer.socket.getBufferedAmount() > BACKLOG) end(peer, 1009, "Preview socket backlog");
    };
    upstream.onmessage = event => deliver(event.data as string | ArrayBuffer);
    // The gateway answered the handshake with a status rather than 101: the
    // browser gets that as a failed upgrade, which is what it was.
    const opened = await new Promise<boolean>(resolve => {
      upstream.onopen = () => resolve(true);
      upstream.onerror = () => resolve(false);
      upstream.onclose = () => resolve(false);
    });
    if (!opened) return new Response("Preview unavailable", { status: 502, headers: { "cache-control": "no-store" } });
    upstream.onerror = () => end(peer, 1011, "Preview socket failed");
    upstream.onclose = event => end(peer, event.code, event.reason);
    const accepted = server.upgrade(request, { data: peer, headers: upstream.protocol ? { "sec-websocket-protocol": upstream.protocol } : undefined });
    if (!accepted) { upstream.close(); return new Response("WebSocket upgrade failed", { status: 400 }); }
    return undefined;
  }

  function end(peer: PreviewPeer, code: number, reason: string) {
    // 1005 and 1006 are the codes for "no code" and "lost"; neither may be sent.
    const sendable = code >= 1000 && code !== 1005 && code !== 1006;
    try { peer.socket?.close(sendable ? code : 1011, sendable ? reason : "Preview socket closed"); } catch { /* already closed */ }
    try { if (peer.upstream.readyState < WebSocket.CLOSING) peer.upstream.close(sendable ? code : 1000, sendable ? reason : ""); } catch { /* already closed */ }
  }

  const websocket = {
    open(ws: ServerWebSocket<PreviewPeer>) {
      ws.data.socket = ws;
      for (const frame of ws.data.queued.splice(0)) ws.send(frame);
    },
    message(ws: ServerWebSocket<PreviewPeer>, data: string | Buffer) {
      const { upstream } = ws.data;
      if (upstream.readyState !== WebSocket.OPEN) { end(ws.data, 1011, "Preview socket closed"); return; }
      upstream.send(data);
      if (upstream.bufferedAmount > BACKLOG) end(ws.data, 1009, "Preview socket backlog");
    },
    close(ws: ServerWebSocket<PreviewPeer>) {
      ws.data.socket = null;
      end(ws.data, 1000, "");
    },
  };

  return {
    matches,
    fetch(request: Request, server: Server<PreviewPeer>): Promise<Response | undefined> {
      return request.headers.get("upgrade")?.toLowerCase() === "websocket" ? relay(request, server) : proxy(request);
    },
    websocket,
  };
}
