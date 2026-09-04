/**
 * The project's own live channel, beside Fountain's.
 *
 * Fountain streams a *conversation* — one track's transcript. That is the
 * wrong shape for the sidebar, which has to know when any track in a project
 * changes state: one opened, one finished cutting its worktree, the machine
 * woke up, the settings revision moved. So there are two streams per open
 * project and they carry different things:
 *
 *   `/api/tracks/:id/stream`     Fountain's, forwarded — the transcript
 *   `/api/projects/:id/stream`   this one — everything about the *set*
 *
 * One process, one map, which is fine on the single replica a SQLite volume
 * allows. Same simplification as paddock's hub and salon's before it.
 */
import type { ProjectEvent } from "../shared/api";

type Listener = (e: ProjectEvent) => void;

/**
 * A browser on this channel, and who is behind it.
 *
 * The userId is not decoration. A project's stream is subscribed by its owner
 * *and* by everyone invited to any one of its tracks, and some of what goes
 * down it names a track — who is watching it, who was just invited to it. A
 * member who cannot see that track should not learn it exists from an event
 * about it, so an event may carry an audience and the fan-out honours it.
 */
interface Subscriber {
  userId: string;
  fn: Listener;
}

const listeners = new Map<string, Set<Subscriber>>();

export function subscribe(projectId: string, userId: string, fn: Listener): () => void {
  const sub: Subscriber = { userId, fn };
  const set = listeners.get(projectId) ?? new Set<Subscriber>();
  set.add(sub);
  listeners.set(projectId, set);
  return () => {
    set.delete(sub);
    if (set.size === 0) listeners.delete(projectId);
  };
}

/**
 * Fan one event out.
 *
 * `audience`, when given, is the set of user ids the event is for; anybody
 * else on the channel is skipped. Omitted means everybody, which is right for
 * the events that describe the project rather than one track.
 */
export function publish(projectId: string, event: ProjectEvent, audience?: ReadonlySet<string>): void {
  for (const sub of listeners.get(projectId) ?? []) {
    if (audience && !audience.has(sub.userId)) continue;
    try {
      sub.fn(event);
    } catch {
      // A browser that went away mid-write. The next flush drops it; a throw
      // here would take the publisher's request down with it.
    }
  }
}

/** For tests: forget everything. */
export function resetHub(): void {
  listeners.clear();
}

/**
 * One project's events as a server-sent stream.
 *
 * The comment line every twenty seconds is not decoration: an idle SSE
 * connection through Traefik and a browser's own timeouts is closed at around
 * a minute, and a sidebar that silently stops updating is the hardest kind of
 * bug to notice. A `:` line is a comment in the SSE grammar — it keeps the
 * socket warm and is ignored by `EventSource`.
 */
export function projectStream(projectId: string, userId: string, signal: AbortSignal): Response {
  const encoder = new TextEncoder();
  let unsubscribe = () => {};
  let keepalive: ReturnType<typeof setInterval> | undefined;

  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const send = (chunk: string) => {
        try {
          controller.enqueue(encoder.encode(chunk));
        } catch {
          /* already closed */
        }
      };
      send(": open\n\n");
      unsubscribe = subscribe(projectId, userId, (e) => send(`event: ${e.event}\ndata: ${JSON.stringify(e.data)}\n\n`));
      keepalive = setInterval(() => send(": ping\n\n"), 20_000);
      signal.addEventListener("abort", () => {
        unsubscribe();
        if (keepalive) clearInterval(keepalive);
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      });
    },
    cancel() {
      unsubscribe();
      if (keepalive) clearInterval(keepalive);
    },
  });

  return new Response(body, {
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      // Traefik does not buffer, but an nginx in front of it would, and a
      // buffered event stream is a stream that arrives all at once at the end.
      "x-accel-buffering": "no",
    },
  });
}
