import assert from "node:assert/strict";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import { createCloudAuthLifecycle } from "../src/lib/cloudAuthLifecycle.js";

function deferred() {
  let resolve;
  const promise = new Promise((finish) => { resolve = finish; });
  return { promise, resolve };
}

function fixture(overrides = {}) {
  let user = { id: "account-a" };
  const scheduled = [];
  const changes = [];
  const lifecycle = createCloudAuthLifecycle({
    verifyUser: async () => user,
    loadWorkspace: async () => ({ profile: { userID: user.id }, farm: { id: "farm" } }),
    invalidate: () => changes.push("invalidate"),
    clearPrivateState: () => changes.push("clear"),
    onSignedOut: () => changes.push("signed-out"),
    onWorkspace: (workspace) => changes.push(workspace.profile.userID),
    onError: (error) => changes.push(error.name),
    schedule: (run) => scheduled.push(run),
    ...overrides,
  });
  return { lifecycle, changes, scheduled, setUser: (value) => { user = value; } };
}

test("account replacement clears private UI synchronously and verifies outside the auth callback", async () => {
  const { lifecycle, changes, scheduled, setUser } = fixture();
  await lifecycle.restore();
  changes.length = 0;
  setUser({ id: "account-b" });
  lifecycle.observe({ event: "SIGNED_IN", session: { user: { id: "account-b" } } });
  assert.deepEqual(changes, ["invalidate", "clear"]);
  assert.equal(scheduled.length, 1);
  scheduled.shift()();
  await lifecycle.restore();
  assert.deepEqual(changes, ["invalidate", "clear", "account-b"]);
});

test("same-account sign-in and token refresh keep the verified workspace without another read", async () => {
  let loads = 0;
  const { lifecycle, changes, scheduled } = fixture({ loadWorkspace: async () => {
    loads += 1;
    return { profile: { userID: "account-a" } };
  } });
  await lifecycle.restore();
  for (const event of ["SIGNED_IN", "TOKEN_REFRESHED", "USER_UPDATED"]) {
    lifecycle.observe({ event, session: { user: { id: "account-a" } } });
  }
  assert.equal(loads, 1);
  assert.equal(scheduled.length, 0);
  assert.deepEqual(changes, ["account-a"]);
});

test("sign-out cannot be undone by a late verification result", async () => {
  const verification = deferred();
  let loads = 0;
  const { lifecycle, changes } = fixture({
    verifyUser: () => verification.promise,
    loadWorkspace: async () => { loads += 1; return { profile: { userID: "account-a" } }; },
  });
  const old = lifecycle.restore();
  lifecycle.observe({ event: "SIGNED_OUT", session: null });
  verification.resolve({ id: "account-a" });
  assert.equal(await old, null);
  assert.equal(loads, 0);
  assert.deepEqual(changes, ["invalidate", "clear", "signed-out"]);
});

test("late workspace is discarded across account switches even when its loader ignores abort", async () => {
  const workspace = deferred();
  const { lifecycle, changes, scheduled, setUser } = fixture({
    loadWorkspace: (farmID) => farmID === "old" ? workspace.promise : Promise.resolve({ profile: { userID: "account-b" } }),
  });
  const old = lifecycle.restore({ farmID: "old" });
  await Promise.resolve();
  setUser({ id: "account-b" });
  lifecycle.observe({ event: "TOKEN_REFRESHED", session: { user: { id: "account-b" } } });
  scheduled.shift()();
  await lifecycle.restore();
  workspace.resolve({ profile: { userID: "account-a" } });
  assert.equal(await old, null);
  assert.deepEqual(changes, ["invalidate", "clear", "account-b"]);
});

test("sign-out discards a pending workspace and stale manually guarded reads", async () => {
  const workspace = deferred();
  const { lifecycle, changes } = fixture({ loadWorkspace: () => workspace.promise });
  const token = lifecycle.token();
  const old = lifecycle.restore();
  await Promise.resolve();
  lifecycle.observe({ event: "SIGNED_OUT", session: null });
  assert.throws(() => lifecycle.assertCurrent(token), { name: "AbortError" });
  workspace.resolve({ profile: { userID: "account-a" } });
  assert.equal(await old, null);
  assert.deepEqual(changes, ["invalidate", "clear", "signed-out"]);
});

test("a workspace with a different verified identity is never published", async () => {
  const { lifecycle, changes } = fixture({ loadWorkspace: async () => ({ profile: { userID: "account-b" } }) });
  await assert.rejects(lifecycle.restore(), { name: "AbortError" });
  assert.deepEqual(changes, ["AbortError"]);
});

test("disposed or superseded deferred callbacks cannot restart cloud loading", async () => {
  let verifications = 0;
  const { lifecycle, scheduled, changes } = fixture({ verifyUser: async () => { verifications += 1; return { id: "account-a" }; } });
  lifecycle.observe({ event: "SIGNED_IN", session: { user: { id: "account-a" } } });
  lifecycle.dispose();
  scheduled.shift()();
  await lifecycle.restore();
  assert.equal(verifications, 0);
  assert.deepEqual(changes, ["invalidate", "clear", "invalidate"]);
});

test("failed verification can be retried after connection recovery", async () => {
  let offline = false;
  const failedIdentities = [];
  const { lifecycle, changes } = fixture({ verifyUser: async () => {
    if (offline) throw new TypeError("Load failed");
    return { id: "account-a" };
  }, onError: (error, user) => { changes.push(error.name); failedIdentities.push(user?.id); } });
  await lifecycle.restore();
  offline = true;
  await assert.rejects(lifecycle.refresh(), { name: "TypeError" });
  assert.deepEqual(failedIdentities, ["account-a"], "an existing verified account retains a retryable unavailable state");
  offline = false;
  await lifecycle.refresh();
  assert.deepEqual(changes, ["account-a", "invalidate", "clear", "TypeError", "invalidate", "clear", "account-a"]);
  assert.equal(lifecycle.owns("account-a"), true);
  assert.equal(lifecycle.owns("account-b"), false);
});

test("explicit post-login restore and deferred SIGNED_IN share a single read", async () => {
  let loads = 0;
  const workspace = deferred();
  const { lifecycle, scheduled, changes } = fixture({ loadWorkspace: () => {
    loads += 1;
    return workspace.promise;
  } });
  lifecycle.beginChecking();
  lifecycle.observe({ event: "SIGNED_IN", session: { user: { id: "account-a" } } });
  const explicit = lifecycle.restore();
  scheduled.shift()();
  assert.equal(lifecycle.restore(), explicit);
  await Promise.resolve();
  workspace.resolve({ profile: { userID: "account-a" } });
  await explicit;
  assert.equal(loads, 1);
  assert.equal(changes.filter((item) => item === "account-a").length, 1);
});

test("a queued login restore is cancelled if another tab signs out first", async () => {
  const { lifecycle, changes, scheduled } = fixture();
  lifecycle.observe({ event: "SIGNED_IN", session: { user: { id: "account-a" } } });
  lifecycle.observe({ event: "SIGNED_OUT", session: null });
  scheduled.shift()();
  assert.deepEqual(changes, ["invalidate", "clear", "invalidate", "clear", "signed-out"]);
  assert.equal(lifecycle.owns("account-a"), false);
});

test("initial lazy module failure ends loading and a later import retry can restore the workspace", async () => {
  let attempts = 0;
  let loading = false;
  let error = null;
  let rendered = null;
  const lazyModule = async () => {
    attempts += 1;
    if (attempts === 1) throw new TypeError("Failed to fetch dynamically imported module");
    return { getVerifiedUser: async () => ({ id: "account-a" }) };
  };
  const { lifecycle } = fixture({
    verifyUser: async () => (await lazyModule()).getVerifiedUser(),
    clearPrivateState: () => { loading = true; rendered = null; },
    onError: (failure) => { loading = false; error = failure; },
    onWorkspace: (workspace) => { loading = false; rendered = workspace.profile.userID; error = null; },
  });
  lifecycle.beginChecking();
  await assert.rejects(lifecycle.restore(), { name: "TypeError" });
  assert.equal(loading, false);
  assert.match(error.message, /dynamically imported module/);
  assert.equal(rendered, null);
  await lifecycle.refresh();
  assert.equal(attempts, 2);
  assert.equal(loading, false);
  assert.equal(error, null);
  assert.equal(rendered, "account-a");
});

test("SDK broadcast account replacement cannot retain the previous account workspace", async () => {
  const original = { window: globalThis.window, document: globalThis.document, BroadcastChannel: globalThis.BroadcastChannel };
  const channels = new Map();
  const clients = [];
  globalThis.window = { location: { href: "https://fixture.example/" }, addEventListener() {}, removeEventListener() {} };
  globalThis.document = { visibilityState: "hidden" };
  globalThis.BroadcastChannel = class {
    constructor(name) { this.name = name; this.listeners = []; channels.set(name, [...(channels.get(name) ?? []), this]); }
    addEventListener(name, listener) { this.listeners.push(listener); }
    postMessage(data) {
      for (const channel of channels.get(this.name)) {
        if (channel !== this) for (const listener of channel.listeners) setTimeout(() => listener({ data }), 0);
      }
    }
    close() {}
  };
  try {
    const stored = new Map();
    const user = (id) => ({ id, aud: "authenticated", email: `${id}@fixture.invalid`, app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" });
    const options = { auth: { autoRefreshToken: false, detectSessionInUrl: false,
      lock: async (name, timeout, run) => run(), storage: {
        getItem: (key) => stored.get(key) ?? null,
        setItem: (key, value) => stored.set(key, value),
        removeItem: (key) => stored.delete(key),
      } }, global: { fetch: async (address, init) => {
      const path = new URL(address).pathname;
      if (path.endsWith("/token")) {
        const id = JSON.parse(init.body).email.split("@")[0];
        return Response.json({ access_token: `fixture-${id}`, refresh_token: `fixture-refresh-${id}`, expires_in: 3600, token_type: "bearer", user: user(id) });
      }
      assert.ok(path.endsWith("/user"));
      return Response.json(user(new Headers(init.headers).get("authorization").replace("Bearer fixture-", "")));
    } } };
    const tabA = createClient("https://fixture.invalid", "sb_publishable_fixture", options);
    clients.push(tabA);
    assert.equal((await tabA.auth.signInWithPassword({ email: "account-a@fixture.invalid", password: "fixture" })).error, null);
    const scheduled = [];
    let renderedAccount;
    const lifecycle = createCloudAuthLifecycle({
      verifyUser: async () => (await tabA.auth.getUser()).data.user,
      loadWorkspace: async () => ({ profile: { userID: (await tabA.auth.getSession()).data.session.user.id } }),
      invalidate() {}, clearPrivateState: () => { renderedAccount = null; },
      onWorkspace: (workspace) => { renderedAccount = workspace.profile.userID; },
      onSignedOut: () => { renderedAccount = null; }, onError: (error) => { throw error; },
      schedule: (run) => scheduled.push(run),
    });
    await lifecycle.restore();
    assert.equal(renderedAccount, "account-a");
    let notified;
    const replaced = new Promise((resolve) => { notified = resolve; });
    const { data } = tabA.auth.onAuthStateChange((event, session) => {
      lifecycle.observe({ event, session });
      if (event === "SIGNED_IN" && session?.user.id === "account-b") notified();
    });
    const tabB = createClient("https://fixture.invalid", "sb_publishable_fixture", options);
    clients.push(tabB);
    assert.equal((await tabB.auth.signInWithPassword({ email: "account-b@fixture.invalid", password: "fixture" })).error, null);
    await replaced;
    assert.equal((await tabA.auth.getSession()).data.session.user.id, "account-b");
    assert.equal(renderedAccount, null, "the A workspace must disappear before B is verified");
    while (scheduled.length) scheduled.shift()();
    await lifecycle.restore();
    assert.equal(renderedAccount, "account-b");
    data.subscription.unsubscribe();
    lifecycle.dispose();
  } finally {
    for (const client of clients) { client.auth.broadcastChannel?.close(); await client.auth.stopAutoRefresh(); }
    for (const [key, value] of Object.entries(original)) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
});
