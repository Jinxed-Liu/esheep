const listeners = new Set();
export function subscribeCloudReadProgress(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
export function reportCloudReadProgress(message, signal) {
  if (!signal?.aborted) for (const listener of listeners) listener(message);
}
