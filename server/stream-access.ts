import { subscribe } from "./hub";

/** Keep authorization live while an upstream request or response is open. */
export function watchStream(
  projectId: string,
  userId: string,
  clientSignal: AbortSignal,
  canAccess: () => boolean,
) {
  const controller = new AbortController();
  const abort = () => controller.abort(new DOMException("Stream access ended.", "AbortError"));
  const unsubscribe = subscribe(projectId, userId, () => {
    if (!canAccess()) abort();
  });
  const dispose = () => {
    unsubscribe();
    clientSignal.removeEventListener("abort", abort);
  };
  controller.signal.addEventListener("abort", dispose, { once: true });
  clientSignal.addEventListener("abort", abort, { once: true });
  if (clientSignal.aborted || !canAccess()) abort();

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
      });
    },
  };
}
