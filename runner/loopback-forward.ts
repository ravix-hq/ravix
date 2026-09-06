import { createServer, type Socket } from "node:net";
import { TcpTunnel } from "./tcp-tunnel";

export function validateForwardEndpoint(value: string): URL {
  const url = new URL(value);
  const local = url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if ((url.protocol !== "wss:" && !(url.protocol === "ws:" && local)) || url.username || url.password || url.search || url.hash) throw new Error("Forward endpoint must use WSS without URL credentials or query parameters (WS is allowed only on literal loopback for tests)");
  return url;
}

/** Bind one named, server-authorized service to Mac loopback. The URL identifies
 * a session/channel, never a destination host/port. The bearer is sent only in
 * the WSS upgrade header, not in the native app's URLs or TCP bytes. */
export async function startLoopbackForward(options: { endpoint: string; token: string; signal: AbortSignal; port?: number }) {
  const endpoint = validateForwardEndpoint(options.endpoint);
  if (!/^[a-zA-Z0-9_-]{32,256}$/.test(options.token)) throw new Error("Invalid session credential");
  const port = options.port ?? 0;
  if (!Number.isInteger(port) || (port !== 0 && (port < 1024 || port > 65535))) throw new Error("Invalid loopback port");
  options.signal.throwIfAborted();
  const peers = new Set<() => void>();
  let stopped = false;
  const server = createServer({ allowHalfOpen: true }, (socket: Socket) => {
    socket.allowHalfOpen = true;
    socket.pause();
    if (stopped || peers.size >= 16) { socket.destroy(); return; }
    const ClientSocket = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
    const ws = new ClientSocket(endpoint.href, { headers: { authorization: `Bearer ${options.token}` } });
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
      server.once("error", reject); server.listen(port, "127.0.0.1", resolve);
    });
    // Abort during listen still closes the eventual listener.
    if (options.signal.aborted || stopped) { server.close(); throw new Error("Forward assignment ended during startup"); }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No loopback listener");
    return { port: address.port, close };
  } catch (error) { close(); throw error; }
}
