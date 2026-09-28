// Refill a slot as soon as it finishes; a slow response must not hold up an
// entire batch. Results retain input order and failures cancel sibling reads.
export async function concurrentRead(items, read, { limit = 6, signal } = {}) {
  const controller = new AbortController();
  const forwardAbort = () => controller.abort(signal.reason);
  if (signal?.aborted) forwardAbort();
  else signal?.addEventListener("abort", forwardAbort, { once: true });
  const results = new Array(items.length);
  let next = 0;
  try {
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        controller.signal.throwIfAborted();
        const index = next++;
        try {
          results[index] = await read(items[index], controller.signal);
        } catch (error) {
          controller.abort(error);
          throw error;
        }
      }
    }));
    controller.signal.throwIfAborted();
    return results;
  } finally {
    signal?.removeEventListener("abort", forwardAbort);
  }
}
