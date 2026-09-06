import { createServer, type Socket } from "node:net";
import { TcpTunnel } from "./tcp-tunnel";

export function validateForwardEndpoint(value: string): URL {
  const url = new URL(value);
  const local = url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if ((url.protocol !== "wss:" && !(url.protocol === "ws:" && local)) || url.username || url.password || url.search || url.hash) throw new Error("Forward endpoint must use WSS without URL credentials or query parameters (WS is allowed only on literal loopback for tests)");
  return url;
}

/** Reserve a loopback listener before pairing so another process cannot take
 * the chosen port between discovery and connection. Until activation, incoming
 * connections are closed without opening an upstream channel. */
export async function reserveLoopbackForward(options: { signal: AbortSignal; port?: number }) {
  let assignment: {endpoint: URL; token: string} | undefined;
  const port = options.port ?? 0;
  if (!Number.isInteger(port) || (port !== 0 && (port < 1024 || port > 65535))) throw new Error("Invalid loopback port");
  options.signal.throwIfAborted();
  const peers = new Set<() => void>();
  let stopped = false;
  const server = createServer({ allowHalfOpen: true }, (socket: Socket) => {
    socket.allowHalfOpen = true;
    socket.pause();
    if (stopped || !assignment || peers.size >= 16) { socket.destroy(); return; }
    const ClientSocket = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
    const ws = new ClientSocket(assignment.endpoint.href, { headers: { authorization: `Bearer ${assignment.token}` } });
    ws.binaryType = "arraybuffer";
    let tunnel: TcpTunnel | undefined;
    const timer = setTimeout(() => close(), 10_000);
    timer.unref();
    const close = () => {
      clearTimeout(timer); peers.delete(close);
      tunnel?.stop(); socket.destroy();
      try { ws.close(); } catch { /* Upgrade already failed. */ }
    };
    peers.add(close);
    socket.on("error", close);
    socket.once("close", () => { if (!tunnel) close(); });
    // Attach the stream lifecycle before the asynchronous WSS upgrade, so
    // an early app half-close is retained while the destination connects.
    tunnel = new TcpTunnel(socket, { send: data => ws.send(data), close: (code, reason) => { ws.close(code, reason); peers.delete(close); } }, options.signal);
    ws.onopen = () => {
      clearTimeout(timer);
      if (stopped || socket.destroyed) { close(); return; }
      tunnel!.start();
    };
    ws.onmessage = event => tunnel ? tunnel.message(event.data) : close();
    ws.onerror = close; ws.onclose = close;
  });
  const close = () => {
    if (stopped) return;
    stopped = true; options.signal.removeEventListener("abort", close);
    for (const stop of [...peers]) stop();
    server.close();
  };
  options.signal.addEventListener("abort", close, { once: true });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", error => reject(new Error(`Unable to bind native preview at 127.0.0.1:${port}: ${error.message}`))); server.listen(port, "127.0.0.1", resolve);
    });
    // Abort during listen still closes the eventual listener.
    if (options.signal.aborted || stopped) { server.close(); throw new Error("Forward assignment ended during startup"); }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No loopback listener");
    return { port: address.port, close, activate(value: {endpoint: string; token: string}) {
      if (stopped || options.signal.aborted || assignment) throw new Error("Forward cannot be activated again or after ending");
      const endpoint = validateForwardEndpoint(value.endpoint);
      if (!/^[a-zA-Z0-9_-]{32,256}$/.test(value.token)) throw new Error("Invalid session credential");
      assignment = {endpoint, token: value.token};
    } };
  } catch (error) { close(); throw error; }
}

/** Bind an already assigned service; retained for callers that know its token. */
export async function startLoopbackForward(options: { endpoint: string; token: string; signal: AbortSignal; port?: number }) {
  validateForwardEndpoint(options.endpoint);
  if (!/^[a-zA-Z0-9_-]{32,256}$/.test(options.token)) throw new Error("Invalid session credential");
  const forward = await reserveLoopbackForward(options);
  try { forward.activate(options); return forward; }
  catch (error) { forward.close(); throw error; }
}
