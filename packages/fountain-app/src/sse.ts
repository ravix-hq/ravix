/**
 * Server-sent events over `fetch`.
 *
 * `EventSource` cannot send an `Authorization` header, and the Fountain API
 * authenticates every request with a bearer key, so the stream is read with
 * `fetch` and parsed by hand. The parser is the spec's: records separated by
 * a blank line, `id:` / `event:` / `data:` fields, `:` comment lines
 * (heartbeats) ignored, multi-line `data:` joined with `\n`.
 */

export interface SseMessage {
  id: string | null;
  event: string;
  data: string;
}

/** Feed chunks of text in; get complete messages out. Keeps partial state. */
export class SseParser {
  private buffer = "";

  push(chunk: string): SseMessage[] {
    this.buffer += chunk;
    const out: SseMessage[] = [];
    // A record ends at a blank line. Normalise CRLF first.
    let idx: number;
    while ((idx = this.buffer.indexOf("\n\n")) !== -1) {
      const raw = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 2);
      const msg = parseRecord(raw);
      if (msg) out.push(msg);
    }
    return out;
  }
}

function parseRecord(raw: string): SseMessage | null {
  let id: string | null = null;
  let event = "message";
  const data: string[] = [];
  for (const line of raw.split("\n")) {
    if (line === "" || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    switch (field) {
      case "id":
        id = value;
        break;
      case "event":
        event = value;
        break;
      case "data":
        data.push(value);
        break;
      default:
        break; // retry and unknown fields are ignored
    }
  }
  if (data.length === 0 && id === null) return null;
  return { id, event, data: data.join("\n") };
}

export interface StreamOptions {
  headers?: Record<string, string>;
  lastEventId?: string | null;
  signal?: AbortSignal;
  onMessage: (msg: SseMessage) => void;
  /** Called once the server has answered 200 and the body is being read. */
  onOpen?: () => void;
  /** Called when the connection ends for any reason other than abort. */
  onClose?: (err?: unknown) => void;
}

/**
 * Open one SSE connection and pump messages until it closes. Resolves when
 * the stream ends. Reconnection is the caller's job (it owns Last-Event-ID).
 */
export async function readSse(url: string, opts: StreamOptions): Promise<void> {
  const headers: Record<string, string> = {
    accept: "text/event-stream",
    ...(opts.headers ?? {}),
  };
  if (opts.lastEventId) headers["last-event-id"] = opts.lastEventId;

  let res: Response;
  try {
    res = await fetch(url, { headers, signal: opts.signal });
  } catch (err) {
    if (opts.signal?.aborted) return;
    opts.onClose?.(err);
    return;
  }
  if (!res.ok || !res.body) {
    opts.onClose?.(new Error(`stream ${res.status}`));
    return;
  }

  opts.onOpen?.();
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  const parser = new SseParser();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true }).replace(/\r\n/g, "\n");
      for (const msg of parser.push(text)) opts.onMessage(msg);
    }
    if (!opts.signal?.aborted) opts.onClose?.();
  } catch (err) {
    if (!opts.signal?.aborted) opts.onClose?.(err);
  }
}
