import assert from "node:assert/strict";
import test from "node:test";
import { createCheckpointChunkCache } from "../src/lib/checkpointChunkCache.js";

test("verified checkpoint bytes survive a new cache instance and stay scoped to the account and manifest", async () => {
  const entries = new Map();
  const storage = {
    async open() {
      return {
        match: async (key) => entries.get(key)?.clone(),
        put: async (key, response) => { entries.set(key, response.clone()); },
        keys: async () => [...entries.keys()].map((url) => new Request(url)),
        delete: async (key) => entries.delete(typeof key === "string" ? key : key.url),
      };
    },
    async delete() { entries.clear(); },
  };
  const options = { cacheStorage: storage, appOrigin: "https://esheepplus.example" };
  const descriptor = { index: 0, compressedBytes: 3, compressedSHA256: "a".repeat(64) };
  const bytes = Uint8Array.from([1, 2, 3]);
  await createCheckpointChunkCache(options).write("account-a:farm:generation:checkpoint:manifest-a", descriptor, bytes);

  const reopened = createCheckpointChunkCache(options);
  assert.deepEqual(await reopened.read("account-a:farm:generation:checkpoint:manifest-a", descriptor), bytes);
  assert.equal(await reopened.read("account-b:farm:generation:checkpoint:manifest-a", descriptor), null);
  assert.equal(await reopened.read("account-a:farm:generation:checkpoint:manifest-b", descriptor), null);
  await reopened.write("account-a:farm:generation:checkpoint-old:manifest-a", descriptor, bytes);
  await reopened.prune("account-a:farm:generation:", "account-a:farm:generation:checkpoint:manifest-a");
  assert.equal(await reopened.read("account-a:farm:generation:checkpoint-old:manifest-a", descriptor), null);
  assert.deepEqual(await reopened.read("account-a:farm:generation:checkpoint:manifest-a", descriptor), bytes);
  await reopened.clear();
  assert.equal(await reopened.read("account-a:farm:generation:checkpoint:manifest-a", descriptor), null);
});

test("unavailable browser storage keeps cloud reads usable", async () => {
  const cache = createCheckpointChunkCache({ cacheStorage: null, appOrigin: "https://esheepplus.example" });
  const descriptor = { index: 0, compressedBytes: 1, compressedSHA256: "a".repeat(64) };
  assert.equal(await cache.read("scope", descriptor), null);
  await cache.write("scope", descriptor, Uint8Array.of(1));
  await cache.clear();
});
