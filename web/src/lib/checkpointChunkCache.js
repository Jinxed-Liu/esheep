const cacheName = "esheepplus-cloud-v2-checkpoints-v1";

export function createCheckpointChunkCache({ cacheStorage = globalThis.caches, appOrigin = globalThis.location?.origin } = {}) {
  const available = Boolean(cacheStorage?.open && appOrigin);
  const keyFor = (scope, descriptor) => new URL(
    `/__esheepplus_checkpoint_cache__/${encodeURIComponent(scope)}/${descriptor.index}/${descriptor.compressedSHA256}`,
    appOrigin,
  ).href;

  return {
    async read(scope, descriptor) {
      if (!available) return null;
      try {
        const cache = await cacheStorage.open(cacheName);
        const response = await cache.match(keyFor(scope, descriptor));
        if (!response) return null;
        const bytes = new Uint8Array(await response.arrayBuffer());
        return bytes.byteLength === descriptor.compressedBytes ? bytes : null;
      } catch {
        // Private browsing, disabled storage, and evicted entries use the network path.
        return null;
      }
    },
    async write(scope, descriptor, bytes) {
      if (!available || bytes.byteLength !== descriptor.compressedBytes) return;
      try {
        const cache = await cacheStorage.open(cacheName);
        await cache.put(keyFor(scope, descriptor), new Response(bytes));
      } catch {
        // Caching is optional; a quota error must not fail an authenticated read.
      }
    },
    async prune(scopePrefix, keepScope) {
      if (!available) return;
      try {
        const cache = await cacheStorage.open(cacheName);
        const keys = await cache.keys();
        await Promise.all(keys.map(async (request) => {
          const encodedScope = new URL(request.url).pathname.split("/")[2];
          const scope = decodeURIComponent(encodedScope ?? "");
          if (scope.startsWith(scopePrefix) && scope !== keepScope) await cache.delete(request);
        }));
      } catch {
        // Old local data is harmless if the browser refuses cleanup.
      }
    },
    async clear() {
      if (!available) return;
      try { await cacheStorage.delete(cacheName); } catch { /* Best effort on sign-out. */ }
    },
  };
}

export const browserCheckpointChunkCache = createCheckpointChunkCache();
