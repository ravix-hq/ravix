import { subscribe } from "./hub";

/** Keep authorization live while an upstream request or response is open. */
export async function watchStream(
  projectId: string,
  userId: string,
  clientSignal: AbortSignal,
  canAccess: () => boolean | Promise<boolean>,
) {
  const controller = new AbortController();
  const abort = () => controller.abort(new DOMException("Stream access ended.", "AbortError"));
  // The check reads the database, so it settles after the event that started
  // it. When it was synchronous a revocation aborted the stream before the
  // hub's own listener could enqueue anything published in the same breath;
  // `forward` keeps that by holding each chunk until the checks in flight have
  // settled. A check that throws is swallowed, as the hub swallowed it then,
  // and must not become an unhandled rejection.
  let pending: Promise<void> = Promise.resolve();
  const unsubscribe = subscribe(projectId, userId, () => {
    pending = pending.then(() => new Promise<boolean>((resolve) => resolve(canAccess())).then((ok) => { if (!ok) abort(); }, () => undefined));
  });
  const dispose = () => {
    unsubscribe();
    clientSignal.removeEventListener("abort", abort);
  };
  controller.signal.addEventListener("abort", dispose, { once: true });
  clientSignal.addEventListener("abort", abort, { once: true });
  if (clientSignal.aborted || !(await canAccess())) abort();

  return {
    signal: controller.signal,
    dispose,
    // Forward one chunk at a time under the consumer's backpressure. Explicit
    // cancellation also wakes an idle reader immediately when access ends.
    forward(response: Response): ReadableStream<Uint8Array> | null {
      if (!response.body) {
        dispose();
        return null;
      }
      const reader = response.body.getReader();
      let finished = false;
      let revoked = () => {};
      const finish = () => {
        finished = true;
        controller.signal.removeEventListener("abort", revoked);
        dispose();
      };
      const cancel = (reason: unknown) => reader.cancel(reason).catch(() => undefined).finally(() => reader.releaseLock());
      return new ReadableStream<Uint8Array>({
        start(output) {
          revoked = () => {
            if (finished) return;
            finish();
            // The HTTP consumer has already left on a tab close. Erroring
            // that abandoned response can become an unhandled stream rejection
            // in Bun and take the durable queue down with the browser.
            if (clientSignal.aborted) output.close();
            else output.error(controller.signal.reason);
            void cancel(controller.signal.reason);
          };
          controller.signal.addEventListener("abort", revoked, { once: true });
          if (controller.signal.aborted) revoked();
        },
        async pull(output) {
          try {
            const chunk = await reader.read();
            // Output published alongside a revocation waits for that check,
            // and is dropped rather than shown if the check ends the stream.
            await pending;
            if (finished) return;
            if (chunk.done) {
              finish();
              reader.releaseLock();
              output.close();
            } else output.enqueue(chunk.value);
          } catch (err) {
            if (finished) return;
            finish();
            reader.releaseLock();
            output.error(err);
          }
        },
        cancel(reason) {
          finish();
          return cancel(reason);
        },
      // No read-ahead: a chunk is pulled only for a read that is waiting, so
      // every chunk passes the hold above rather than sitting in a queue that
      // was filled before the revocation arrived.
      }, { highWaterMark: 0 });
    },
  };
}
