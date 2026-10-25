import assert from "node:assert/strict";
import test from "node:test";
import { createCloudAuthLifecycle } from "../src/lib/cloudAuthLifecycle.js";
import { submitDraft } from "../src/lib/cloudV2Writes.js";
import { saveDraft, listDrafts, patchDraft } from "../src/lib/draftStore.js";
import { submitPenManagement } from "../src/lib/penSubmission.js";
import { submitWorkspaceDraft } from "../src/lib/workspaceSubmission.js";
import { workflowFixture } from "./helpers/workflowFixture.mjs";

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

test("a pen dialog retains its requested draft identity and signed request across a retry", async () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: memoryIndexedDB(new Map()) });
  try {
    const id = crypto.randomUUID(), farm = { id: crypto.randomUUID(), generation: 3 };
    const record = { sheet: "羊舍管理", penAction: "create", penDraft: { penID: crypto.randomUUID(), name: "测试" } };
    const draft = await saveDraft("account-a", farm, record, id);
    assert.equal(draft.id, id);
    await patchDraft("account-a", id, { signed: ["original-bytes"], status: "unknown" });
    const retry = (await listDrafts("account-a", farm.id)).find(d => d.id === id);
    assert.deepEqual(retry.signed, ["original-bytes"]);
    await assert.rejects(() => saveDraft("account-a", farm, record, id), /不能改写/);
    assert.equal((await listDrafts("account-a", farm.id)).length, 1);
  } finally {
    if (original) Object.defineProperty(globalThis, "indexedDB", original); else delete globalThis.indexedDB;
  }
});

test("pen submission recovers an uncertain signed request once and separates accepted receipt from failed refresh", async () => {
  const original = Object.fromEntries(["indexedDB", "navigator"].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: memoryIndexedDB(new Map()) });
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { locks: { request: async (_name, run) => run() } } });
  try {
    const workspace = workflowFixture().workspace();
    workspace.farm.role = "owner"; workspace.farm.revision = 0;
    workspace.profile = { accountID: crypto.randomUUID(), userID: crypto.randomUUID() };
    let sent = 0, commandID, refreshed = 0, reads = 0, refreshFails = false;
    const cloud = { loadCloudWorkspace: async () => { reads++; if (refreshFails) throw new Error("refresh offline"); return workspace; },
      supabase: { auth: { getUser: async () => ({ data: { user: { id: workspace.profile.userID } } }) },
        rpc: async (name) => ({ data: name === "esheep_cloud_fetch_status_v2"
          ? { farm_generation: 3, v2_ready: true, write_frozen: false, cloud_head: 0 }
          : name === "esheep_cloud_query_command_status_v2" ? { results: [{ command_id: commandID, result: { type: "accepted" } }] } : {} }),
        functions: { invoke: async (_name, { body }) => {
          sent++; commandID = JSON.parse(Buffer.from(body.commands[0].unsigned_command_base64, "base64")).commandID;
          throw new Error("response lost after server accepted");
        } } } };
    const draftID = crypto.randomUUID(), record = { sheet: "羊舍管理", penAction: "create", penDraft: { penID: crypto.randomUUID(), name: "提交核对测试", note: "" } };
    const options = { cloud, workspace, record, draftID, assertCurrent: () => {}, onWorkspace: () => { refreshed++; }, onDrafts: () => {} };
    await assert.rejects(() => submitPenManagement(options), error => error.signed && /response lost/.test(error.message));
    const pending = (await listDrafts(workspace.profile.accountID, workspace.farm.id))[0];
    assert.equal(pending.id, draftID); assert.equal(pending.status, "unknown");
    assert.equal(reads, 0, "uncertain submission must not wait for a full farm reload");
    refreshFails = true;
    const retry = await submitPenManagement(options);
    assert.deepEqual(retry, { accepted: 1, refreshed: false });
    assert.equal(sent, 1); assert.equal(refreshed, 0);
    const accepted = (await listDrafts(workspace.profile.accountID, workspace.farm.id))[0];
    assert.equal(accepted.status, "accepted"); assert.deepEqual(accepted.signed, pending.signed);
    refreshFails = false;
    assert.deepEqual(await submitPenManagement(options), { accepted: 1, refreshed: true });
    assert.equal(sent, 1); assert.equal(refreshed, 1);
    assert.equal(reads, 2, "only accepted receipts trigger a refresh");
  } finally {
    for (const [key, descriptor] of Object.entries(original)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
  }
});

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

async function withUnsignedWrite(run) {
  const original = Object.fromEntries(["indexedDB", "navigator"].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: memoryIndexedDB(new Map()) });
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { locks: { request: async (_name, action) => action() } } });
  try {
    const workspace = workflowFixture().workspace();
    workspace.farm.role = "owner"; workspace.farm.revision = 10;
    workspace.profile = { accountID: crypto.randomUUID(), userID: crypto.randomUUID() };
    const state = { head: 10, reads: 0, sends: 0, frozen: false, statusReads: 0, growHead: false };
    const record = { sheet: "羊舍管理", penAction: "create", penDraft: { penID: crypto.randomUUID(), name: "性能校验羊舍", note: "" } };
    const draft = await saveDraft(workspace.profile.accountID, workspace.farm, record, crypto.randomUUID());
    const cloud = {
      loadCloudWorkspace: async () => { state.reads++; return { ...workspace, farm: { ...workspace.farm, revision: state.head } }; },
      supabase: {
        auth: { getUser: async () => ({ data: { user: { id: workspace.profile.userID } } }) },
        rpc: async name => {
          if (name !== "esheep_cloud_fetch_status_v2") return { data: {} };
          state.statusReads++; if (state.growHead) state.head++;
          return { data: { farm_generation: 3, v2_ready: true, write_frozen: state.frozen, cloud_head: state.head } };
        },
        functions: { invoke: async (_name, { body }) => {
          state.sends++;
          const commands = body.commands.map(c => JSON.parse(Buffer.from(c.unsigned_command_base64, "base64")));
          return { data: { results: commands.map(c => ({ command_id: c.commandID, type: "accepted" })) } };
        } },
      },
    };
    await run({ workspace, state, cloud, draft });
  } finally {
    for (const [key, descriptor] of Object.entries(original)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key];
    }
  }
}

test("reproduction writes require an explicit numeric cloud capability before signing and keep unsupported drafts", async () => {
  for (const version of [undefined, null, 0, "1", 1]) {
    await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
      const invoke = cloud.supabase.functions.invoke;
      cloud.supabase.functions.invoke = async (name, request) => request.body.action === "capabilities"
        ? { data: { reproduction_contract_version: version } } : invoke(name, request);
      const submit = () => submitDraft(cloud.supabase, workspace.profile.accountID, workspace.farm, draft,
        () => [{ kind: "care.reproduction.recordBatch", occurredAt: Date.now(),
          body: { reproductionCycleID: crypto.randomUUID() }, streams: [] }]);
      if (version === 1) {
        assert.equal((await submit()).status, "accepted");
        assert.equal(state.sends, 1);
      } else {
        await assert.rejects(submit, /云端尚未启用繁殖周期关联/);
        const saved = (await listDrafts(workspace.profile.accountID, workspace.farm.id))[0];
        assert.equal(saved.signed, undefined);
        assert.equal(state.sends, 0);
      }
    });
  }
});

test("fresh single writes avoid a whole-farm read and check auth/status concurrently", { timeout: 2000 }, async () => {
  await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
    const auth = deferred(), rpc = cloud.supabase.rpc;
    cloud.supabase.auth.getUser = () => auth.promise;
    cloud.supabase.rpc = async name => {
      if (name === "esheep_cloud_fetch_status_v2") auth.resolve({ data: { user: { id: workspace.profile.userID } } });
      return rpc(name);
    };
    const phases = [];
    const { result } = await submitWorkspaceDraft({ cloud, workspace, draft, onProgress: phase => phases.push(phase) });
    assert.equal(result.status, "accepted"); assert.equal(state.sends, 1); assert.equal(state.reads, 0);
    assert.ok(phases.some(p => p.includes("核对账号")));
    assert.ok(phases.some(p => p.includes("等待回执")));
  });
});

test("a stale workspace refreshes exactly once before building and signing the command", async () => {
  await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
    state.head = 11;
    const { result, workspace: refreshed } = await submitWorkspaceDraft({ cloud, workspace, draft });
    assert.equal(result.status, "accepted"); assert.equal(refreshed.farm.revision, 11);
    assert.equal(state.reads, 1); assert.equal(state.statusReads, 2); assert.equal(state.sends, 1);
  });
});

test("continuing concurrent changes, a switched account and frozen writes cannot be hidden by the fast path", async () => {
  await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
    state.growHead = true;
    await assert.rejects(submitWorkspaceDraft({ cloud, workspace, draft }), { code: "CLOUD_WORKSPACE_STALE" });
    assert.equal(state.reads, 1); assert.equal(state.sends, 0);
    assert.equal((await listDrafts(workspace.profile.accountID, workspace.farm.id))[0].signed, undefined);
  });
  await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
    state.head = 11;
    cloud.loadCloudWorkspace = async () => ({ ...workspace, profile: { ...workspace.profile, userID: "another-user" } });
    await assert.rejects(submitWorkspaceDraft({ cloud, workspace, draft }), /账号或牧场版本已切换/);
    assert.equal(state.sends, 0);
  });
  await withUnsignedWrite(async ({ workspace, state, cloud, draft }) => {
    state.frozen = true;
    await assert.rejects(submitWorkspaceDraft({ cloud, workspace, draft }), /暂不可写入/);
    assert.equal(state.reads, 0); assert.equal(state.sends, 0);
  });
});
