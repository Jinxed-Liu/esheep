import assert from "node:assert/strict";
import test from "node:test";
import { createCloudAuthLifecycle } from "../src/lib/cloudAuthLifecycle.js";
import { submitDraft } from "../src/lib/cloudV2Writes.js";

function deferred() {
  let resolve;
  const promise = new Promise((finish) => { resolve = finish; });
  return { promise, resolve };
}

// Exercise the real draft-store functions without touching browser or server
// data. This fixture implements only the IndexedDB operations that they use.
function memoryIndexedDB(accounts) {
  return {
    open() {
      const request = {};
      queueMicrotask(() => {
        request.result = {
          close() {},
          transaction() {
            let pending = 0;
            let aborted = false;
            const tx = {
              abort() { aborted = true; queueMicrotask(() => tx.onabort?.()); },
              objectStore() {
                return {
                  get(key) {
                    pending += 1;
                    const read = {};
                    queueMicrotask(() => {
                      read.result = structuredClone(accounts.get(key));
                      read.onsuccess?.();
                      finish();
                    });
                    return read;
                  },
                  put(value, key) {
                    pending += 1;
                    queueMicrotask(() => {
                      if (!aborted) accounts.set(key, structuredClone(value));
                      finish();
                    });
                  },
                };
              },
            };
            function finish() {
              pending -= 1;
              if (!pending && !aborted) queueMicrotask(() => tx.oncomplete?.());
            }
            return tx;
          },
        };
        request.onsuccess?.();
      });
      return request;
    },
  };
}

async function withFixture(run) {
  const farm = { id: "farm-a", generation: 3, revision: 7 };
  const draft = {
    id: "draft-a", farmID: farm.id, generation: farm.generation, status: "unknown",
    signed: [{ unsigned_command_base64: "fixture-signed-bytes", content_digest: "fixture-digest", device_signature_base64: "fixture-signature" }],
    commands: [{ commandID: "command-a" }],
  };
  const accounts = new Map([
    ["account-a", { drafts: [draft] }],
    ["account-b", { drafts: [] }],
  ]);
  const original = Object.fromEntries(["navigator", "indexedDB"].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const navigator = { locks: { request: async (name, run) => run() } };
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: navigator });
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: memoryIndexedDB(accounts) });
  const lifecycle = createCloudAuthLifecycle({
    verifyUser: async () => ({ id: "user-a" }),
    loadWorkspace: async () => ({ profile: { userID: "user-a" } }),
    invalidate() {}, clearPrivateState() {}, onSignedOut() {}, onWorkspace() {}, onError() {}, schedule() {},
  });
  await lifecycle.restore();
  const token = lifecycle.token();
  const options = { assertCurrent: () => lifecycle.assertCurrent(token) };
  const switchAccount = () => lifecycle.observe({ event: "SIGNED_IN", session: { user: { id: "user-b" } } });
  const calls = [];
  const client = {
    auth: { getUser: async () => { calls.push("getUser"); return { data: { user: { id: "user-a" } } }; } },
    rpc: async (name) => {
      calls.push(name);
      return { data: name === "esheep_cloud_fetch_status_v2"
        ? { farm_generation: 3, v2_ready: true, write_frozen: false, cloud_head: 7 }
        : { results: [] } };
    },
    functions: { invoke: async (name, request) => {
      calls.push(name);
      assert.deepEqual(request.body.commands, draft.signed);
      return { data: { results: [{ command_id: "command-a", type: "accepted" }] } };
    } },
  };
  try {
    await run({ farm, draft, accounts, navigator, options, switchAccount, client, calls });
  } finally {
    lifecycle.dispose();
    for (const [key, descriptor] of Object.entries(original)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
}

test("account replacement while waiting for the Web Lock prevents old draft submission", async () => {
  await withFixture(async ({ farm, draft, navigator, options, switchAccount, client, calls, accounts }) => {
    const lock = deferred();
    navigator.locks.request = async (name, run) => { await lock.promise; return run(); };
    const pending = submitDraft(client, "account-a", farm, draft, () => [], options);
    const rejected = assert.rejects(pending, { name: "AbortError" });
    switchAccount();
    lock.resolve();
    await rejected;
    assert.deepEqual(calls, []);
    assert.equal(accounts.get("account-a").drafts[0].status, "unknown");
    assert.deepEqual(accounts.get("account-b").drafts, []);
  });
});

test("account replacement during status lookup stops before preparing or sending commands", async () => {
  await withFixture(async ({ farm, draft, options, switchAccount, client, calls, accounts }) => {
    const started = deferred();
    const status = deferred();
    client.rpc = async (name) => { calls.push(name); started.resolve(); return status.promise; };
    let prepared = false;
    const pending = submitDraft(client, "account-a", farm, draft, () => { prepared = true; return []; }, options);
    const rejected = assert.rejects(pending, { name: "AbortError" });
    await started.promise;
    switchAccount();
    status.resolve({ data: { farm_generation: 3, v2_ready: true, write_frozen: false, cloud_head: 7 } });
    await rejected;
    assert.equal(prepared, false);
    assert.deepEqual(calls, ["getUser", "esheep_cloud_fetch_status_v2"]);
    assert.equal(accounts.get("account-a").drafts[0].status, "unknown");
    assert.deepEqual(accounts.get("account-b").drafts, []);
  });
});

test("a known accepted receipt after account replacement stays in the original account store", async () => {
  await withFixture(async ({ farm, draft, options, switchAccount, client, calls, accounts }) => {
    const started = deferred();
    const response = deferred();
    client.functions.invoke = async (name, request) => {
      calls.push(name);
      assert.deepEqual(request.body.commands, draft.signed);
      started.resolve();
      return response.promise;
    };
    const pending = submitDraft(client, "account-a", farm, draft, () => [], options);
    await started.promise;
    switchAccount();
    response.resolve({ data: { results: [{ command_id: "command-a", type: "accepted" }] } });
    assert.equal((await pending).status, "accepted");
    assert.equal(accounts.get("account-a").drafts[0].status, "accepted");
    assert.deepEqual(accounts.get("account-a").drafts[0].signed, draft.signed);
    assert.deepEqual(accounts.get("account-b").drafts, []);
    assert.equal(calls.filter((name) => name === "esheep-cloud-v2-writes").length, 1);
  });
});

test("a known retry receipt after account replacement is retained without resubmitting", async () => {
  await withFixture(async ({ farm, draft, options, switchAccount, client, calls, accounts }) => {
    const started = deferred();
    const response = deferred();
    const rpc = client.rpc;
    client.rpc = async (name, body) => {
      if (name !== "esheep_cloud_query_command_status_v2") return rpc(name, body);
      calls.push(name);
      started.resolve();
      return response.promise;
    };
    const pending = submitDraft(client, "account-a", farm, draft, () => [], options);
    await started.promise;
    switchAccount();
    response.resolve({ data: { results: [{ command_id: "command-a", result: { type: "accepted" } }] } });
    assert.equal((await pending).status, "accepted");
    assert.equal(accounts.get("account-a").drafts[0].status, "accepted");
    assert.deepEqual(accounts.get("account-b").drafts, []);
    assert.equal(calls.includes("esheep-cloud-v2-writes"), false);
  });
});

test("unchanged account preserves the existing signed retry bytes", async () => {
  await withFixture(async ({ farm, draft, options, client, calls, accounts }) => {
    const result = await submitDraft(client, "account-a", farm, draft, () => { throw new Error("signed retry must not be rebuilt"); }, options);
    assert.equal(result.status, "accepted");
    assert.deepEqual(accounts.get("account-a").drafts[0].signed, draft.signed);
    assert.deepEqual(accounts.get("account-b").drafts, []);
    assert.deepEqual(calls, ["getUser", "esheep_cloud_fetch_status_v2", "esheep_cloud_query_command_status_v2", "esheep-cloud-v2-writes"]);
  });
});
