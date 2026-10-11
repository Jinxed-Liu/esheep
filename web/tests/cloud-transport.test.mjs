import assert from "node:assert/strict";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import { createCloudFetch, cloudConnectionErrorMessage } from "../src/lib/cloudTransport.js";
import { proxyCloudRequest } from "../worker/cloud-proxy.js";

const upstream = "https://fixture.supabase.co";
const site = "https://app.example.test";
const env = { SUPABASE_URL: upstream };
const request = (path, init = {}) => new Request(`${site}/api/cloud${path}`, {
  ...init, headers: { "x-esheep-cloud-host": "fixture.supabase.co", ...init.headers },
});

test("Safari-compatible uploads preserve JSON, multipart boundaries, binary bytes, and Request bodies", async () => {
  const NativeRequest = globalThis.Request;
  // Safari constructs stream-backed Requests but rejects streaming uploads.
  // Reject that body at the final URL rewrite to reproduce its restriction.
  globalThis.Request = class extends NativeRequest {
    constructor(input, init) {
      if (new URL(typeof input === "string" || input instanceof URL ? input : input.url).origin === site && init?.body instanceof ReadableStream) {
        throw new TypeError("ReadableStream uploading is not supported");
      }
      super(input, init);
    }
  };
  try {
    const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async (proxied) => {
      assert.equal(new URL(proxied.url).origin, site);
      assert.equal(proxied.headers.get("authorization"), "Bearer fixture-access");
      return Response.json({ type: proxied.headers.get("content-type"), body: await proxied.text() });
    } });
    const headers = { authorization: "Bearer fixture-access" };
    const json = JSON.stringify({ farm_id: "fixture", note: "牧场🌿" });
    const jsonResponse = await transport(`${upstream}/rest/v1/rpc/farm_read`, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: json });
    assert.deepEqual(await jsonResponse.json(), { type: "application/json", body: json });
    const input = new NativeRequest(`${upstream}/auth/v1/token`, { method: "POST", headers, body: "fixture=42" });
    assert.equal((await (await transport(input)).json()).body, "fixture=42");
    const form = new FormData(); form.append("note", "牧场"); form.append("file", new Blob(["fixture bytes"]), "fixture.txt");
    const multipart = await (await transport(`${upstream}/storage/v1/object/fixture`, { method: "POST", headers, body: form })).json();
    const decoded = await new Response(multipart.body, { headers: { "content-type": multipart.type } }).formData();
    assert.equal(decoded.get("note"), "牧场");
    assert.equal(decoded.get("file").name, "fixture.txt");
    assert.equal(await decoded.get("file").text(), "fixture bytes");
    const binary = new Uint8Array([0, 31, 139, 255]);
    const binaryTransport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async (proxied) => {
      assert.deepEqual(new Uint8Array(await proxied.arrayBuffer()), binary);
      return new Response(null, { status: 204 });
    } });
    assert.equal((await binaryTransport(`${upstream}/storage/v1/object/fixture`, { method: "PUT", body: new Blob([binary]) })).status, 204);
    const client = createClient(upstream, "sb_publishable_fixture", { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }, global: { fetch: createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async (proxied) => {
      const body = await proxied.json();
      assert.equal(body.email, "fixture@example.test");
      return Response.json({ code: "invalid_credentials", msg: "Invalid login credentials" }, { status: 400 });
    } }) } });
    assert.equal((await client.auth.signInWithPassword({ email: "fixture@example.test", password: "fixture-password" })).error.status, 400);
  } finally {
    globalThis.Request = NativeRequest;
  }
});

test("SDK sign-in, restore, refresh, and farm reads retain canonical sessions through same-origin HTTP", async () => {
  const calls = [], stored = new Map();
  const user = { id: "10000000-0000-4000-8000-000000000001", email: "fixture@example.test", aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" };
  const session = { access_token: "fixture-access", refresh_token: "fixture-refresh", expires_in: 3600, token_type: "bearer", user };
  const refreshed = { ...session, access_token: "fixture-access-rotated", refresh_token: "fixture-refresh-rotated" };
  const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async (proxied) => {
    assert.equal(new URL(proxied.url).origin, site);
    assert.equal(proxied.credentials, "omit");
    return proxyCloudRequest(proxied, env, { fetchImpl: async (outbound) => {
      const url = new URL(outbound.url);
      calls.push({ path: url.pathname + url.search, token: outbound.headers.get("authorization"), body: outbound.method === "POST" ? await outbound.json() : null });
      assert.equal(url.origin, upstream);
      assert.equal(outbound.headers.get("apikey"), "sb_publishable_fixture");
      return Response.json(url.pathname === "/auth/v1/token" ? (url.searchParams.get("grant_type") === "refresh_token" ? refreshed : session) : url.pathname === "/auth/v1/user" ? user : [{ farm_id: "fixture" }]);
    } });
  } });
  const options = { global: { fetch: transport }, auth: { autoRefreshToken: false, detectSessionInUrl: false, storage: {
    getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: (key) => stored.delete(key),
  } } };
  const client = createClient(upstream, "sb_publishable_fixture", options);
  assert.equal((await client.auth.signInWithPassword({ email: user.email, password: "fixture-password" })).error, null);
  assert.ok(stored.has("sb-fixture-auth-token"));
  const restored = createClient(upstream, "sb_publishable_fixture", options);
  assert.equal((await restored.auth.getSession()).data.session.user.id, user.id);
  assert.equal((await restored.auth.getUser()).data.user.id, user.id);
  assert.equal((await restored.auth.refreshSession()).error, null);
  const persisted = JSON.parse(stored.get("sb-fixture-auth-token"));
  assert.equal(persisted.access_token, refreshed.access_token);
  assert.equal(persisted.refresh_token, refreshed.refresh_token);
  assert.deepEqual((await restored.from("farm_registry").select("farm_id")).data, [{ farm_id: "fixture" }]);
  assert.equal((await restored.functions.invoke("esheep-cloud-checkpoints", { body: { farm_id: "fixture" } })).error, null);
  assert.deepEqual(calls.map((call) => call.path), ["/auth/v1/token?grant_type=password", "/auth/v1/user", "/auth/v1/token?grant_type=refresh_token", "/rest/v1/farm_registry?select=farm_id", "/functions/v1/esheep-cloud-checkpoints"]);
  assert.equal(calls[0].body.password, "fixture-password");
  assert.equal(calls[2].body.refresh_token, "fixture-refresh");
  assert.equal(calls[3].token, "Bearer fixture-access-rotated");
  assert.equal(calls[4].token, "Bearer fixture-access-rotated");
  assert.deepEqual(calls[4].body, { farm_id: "fixture" });
});

test("SDK keeps invalid credentials as an authentication failure", async () => {
  const client = createClient(upstream, "sb_publishable_fixture", { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: (proxied) => proxyCloudRequest(proxied, env, {
      fetchImpl: async () => Response.json({ code: "invalid_credentials", msg: "Invalid login credentials" }, { status: 400, headers: { "x-supabase-api-version": "2024-01-01" } }),
    }) }) },
  });
  const { data, error } = await client.auth.signInWithPassword({ email: "fixture@example.test", password: "incorrect" });
  assert.equal(data.session, null);
  assert.equal(error.code, "invalid_credentials");
  assert.equal(error.status, 400);
});

test("signed downloads preserve signatures and bytes and never forward website cookies or cache private responses", async () => {
  const bytes = new Uint8Array([31, 139, 0, 255]);
  const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: (proxied) => proxyCloudRequest(proxied, env, { fetchImpl: async (outbound) => {
    assert.equal(outbound.url, `${upstream}/storage/v1/object/sign/esheep-cloud-checkpoints/a/chunk.json.gz?token=a%2Bb%2Fc`);
    assert.equal(outbound.headers.get("cookie"), null);
    return new Response(bytes, { headers: { "cache-control": "public, max-age=3600", "access-control-allow-origin": "*", "set-cookie": "unwanted=1" } });
  } }) });
  const response = await transport(`${upstream}/storage/v1/object/sign/esheep-cloud-checkpoints/a/chunk.json.gz?token=a%2Bb%2Fc`, { headers: { cookie: "website-session=1" } });
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("access-control-allow-origin"), null);
  assert.equal(response.headers.get("set-cookie"), null);
});

test("proxy preserves original bearer, schema, ranges, RPC body, and permission failure", async () => {
  const response = await proxyCloudRequest(request("/rest/v1/rpc/farm_read?x=1", { method: "POST", body: JSON.stringify({ p_farm_id: "fixture" }),
    headers: { apikey: "public-fixture", authorization: "Bearer member", "content-type": "application/json", "content-profile": "public", range: "0-99", cookie: "private=1" },
  }), env, { fetchImpl: async (outbound) => {
    assert.equal(outbound.url, `${upstream}/rest/v1/rpc/farm_read?x=1`);
    for (const [name, value] of [["authorization", "Bearer member"], ["apikey", "public-fixture"], ["content-profile", "public"], ["range", "0-99"], ["cookie", null], ["x-esheep-cloud-host", null]]) assert.equal(outbound.headers.get(name), value);
    assert.deepEqual(await outbound.json(), { p_farm_id: "fixture" });
    return Response.json({ code: "42501", message: "permission denied" }, { status: 403 });
  } });
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "42501");
});

test("proxy rejects cross-site, project mismatch, unknown paths, and missing configuration before network access", async () => {
  for (const [input, environment, status] of [
    [request("/auth/v1/token", { headers: { origin: "https://evil.test" } }), env, 403],
    [request("/auth/v1/token", { headers: { "x-esheep-cloud-host": "other.supabase.co" } }), env, 409],
    [request("/anything/https://evil.test"), env, 404], [request("/auth/v1/token", { method: "OPTIONS" }), env, 404],
    [request("/auth/v1/token"), {}, 503], [request("/auth/v1/token"), { SUPABASE_URL: "http://localhost:54321" }, 503],
  ]) assert.equal((await proxyCloudRequest(input, environment, { fetchImpl: () => { throw new Error("must not fetch"); } })).status, status);
});

test("proxy blocks redirects and returns bounded, explicit failures and timeouts", async () => {
  const redirect = await proxyCloudRequest(request("/auth/v1/user"), env, { fetchImpl: async (outbound) => {
    assert.equal(outbound.redirect, "manual");
    return new Response(null, { status: 302, headers: { location: "https://evil.test" } });
  } });
  assert.equal((await redirect.json()).code, "CLOUD_PROXY_REDIRECT_DENIED");
  const failed = await proxyCloudRequest(request("/auth/v1/user"), env, { fetchImpl: async () => { throw new TypeError("Load failed"); } });
  assert.equal(failed.status, 502);
  assert.equal((await failed.json()).message, "暂时无法连接云端服务，请稍后重试。");
  const timeout = await proxyCloudRequest(request("/auth/v1/user"), env, { timeoutMs: 5, fetchImpl: (outbound) => new Promise((resolve, reject) => outbound.signal.addEventListener("abort", () => reject(outbound.signal.reason), { once: true })) });
  assert.equal(timeout.status, 504);
});

test("transport explains network failures and preserves cancellation", async () => {
  const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async () => { throw new TypeError("Load failed"); } });
  await assert.rejects(transport(`${upstream}/auth/v1/token`), { code: "CLOUD_NETWORK_FAILED" });
  const controller = new AbortController(); controller.abort();
  await assert.rejects(transport(`${upstream}/auth/v1/user`, { signal: controller.signal }), { name: "AbortError" });
  assert.equal(cloudConnectionErrorMessage(new TypeError("Load failed")), "无法连接云端服务，请检查网络后重试。");
  assert.equal(cloudConnectionErrorMessage({ message: "Invalid login credentials" }), "Invalid login credentials");
});

test("cancellation interrupts upload buffering before fetch and cancels the source", async () => {
  const controller = new AbortController();
  let cancelled = false, fetches = 0;
  let beginRead;
  const reading = new Promise((resolve) => { beginRead = resolve; });
  const body = new ReadableStream({ pull() { beginRead(); }, cancel() { cancelled = true; } });
  const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async () => {
    fetches += 1;
    return new Response(null, { status: 204 });
  } });
  const pending = transport(`${upstream}/storage/v1/object/fixture`, {
    method: "POST", body, duplex: "half", signal: controller.signal,
  });
  await reading;
  const rejected = assert.rejects(pending, { name: "AbortError" });
  controller.abort();
  let timer;
  try {
    await Promise.race([rejected, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("upload remained pending after abort")), 500);
    })]);
  } finally { clearTimeout(timer); }
  assert.equal(cancelled, true);
  assert.equal(fetches, 0);
});

test("SDK retries a transient refresh failure, rotates credentials, and recovers without signing out", async () => {
  const stored = new Map(), tokens = [];
  let refreshes = 0;
  const user = { id: "10000000-0000-4000-8000-000000000002", aud: "authenticated", email: "recovery@example.test", app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" };
  const session = { access_token: "access-before", refresh_token: "refresh-before", expires_in: 3600, token_type: "bearer", user };
  const rotated = { ...session, access_token: "access-after", refresh_token: "refresh-after" };
  const client = createClient(upstream, "sb_publishable_fixture", {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, storage: {
      getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: (key) => stored.delete(key),
    } },
    global: { fetch: createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: (proxied) => proxyCloudRequest(proxied, env, {
      fetchImpl: async (outbound) => {
        const url = new URL(outbound.url);
        if (url.searchParams.get("grant_type") === "password") return Response.json(session);
        if (url.searchParams.get("grant_type") === "refresh_token") {
          refreshes += 1;
          assert.equal((await outbound.json()).refresh_token, "refresh-before");
          if (refreshes === 1) {
            assert.equal(JSON.parse(stored.get("sb-fixture-auth-token")).user.id, user.id);
            return Response.json({ message: "temporary upstream outage" }, { status: 503 });
          }
          return Response.json(rotated);
        }
        tokens.push(outbound.headers.get("authorization"));
        return Response.json([{ farm_id: "recovery-fixture" }]);
      },
    }) }) },
  });
  assert.equal((await client.auth.signInWithPassword({ email: user.email, password: "fixture-password" })).error, null);
  const [first, second] = await Promise.all([client.auth.refreshSession(), client.auth.refreshSession()]);
  assert.equal(first.error, null);
  assert.equal(second.error, null);
  assert.equal(refreshes, 2, "concurrent callers share one refresh plus its retry");
  assert.equal((await client.auth.getSession()).data.session.access_token, "access-after");
  assert.equal(JSON.parse(stored.get("sb-fixture-auth-token")).refresh_token, "refresh-after");
  assert.equal((await client.from("farm_registry").select("farm_id")).error, null);
  assert.deepEqual(tokens, ["Bearer access-after"]);
});

test("proxy isolates concurrent account tokens and responses without adding credentials", async () => {
  const responses = await Promise.all(["account-a", "account-b"].map(async (account) => {
    const response = await proxyCloudRequest(request("/rest/v1/farm_registry", { headers: { authorization: `Bearer ${account}`, apikey: "public-fixture" } }), env, {
      fetchImpl: async (outbound) => {
        const token = outbound.headers.get("authorization");
        assert.equal(outbound.headers.get("apikey"), "public-fixture");
        return Response.json({ account: token }, { headers: { "cache-control": "public, max-age=3600" } });
      },
    });
    assert.equal(response.headers.get("cache-control"), "no-store");
    return response.json();
  }));
  assert.deepEqual(responses, [{ account: "Bearer account-a" }, { account: "Bearer account-b" }]);
});

test("SDK Blob upload preserves binary multipart bytes, cache control, and upsert headers", async () => {
  const bytes = new Uint8Array([0, 31, 139, 255, 128]);
  let uploads = 0;
  const client = createClient(upstream, "sb_publishable_fixture", {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    global: { fetch: createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: (proxied) => proxyCloudRequest(proxied, env, {
      fetchImpl: async (outbound) => {
        uploads += 1;
        assert.equal(outbound.url, `${upstream}/storage/v1/object/avatars/fixture/avatar.jpg`);
        assert.equal(outbound.method, "POST");
        assert.equal(outbound.headers.get("x-upsert"), "true");
        assert.match(outbound.headers.get("content-type"), /^multipart\/form-data; boundary=/);
        const form = await outbound.formData();
        assert.equal(form.get("cacheControl"), "3600");
        assert.deepEqual(new Uint8Array(await form.get("").arrayBuffer()), bytes);
        assert.equal(form.get("").type, "image/jpeg");
        return Response.json({ Key: "avatars/fixture/avatar.jpg", Id: "fixture-object" });
      },
    }) }) },
  });
  const { data, error } = await client.storage.from("avatars").upload("fixture/avatar.jpg", new Blob([bytes], { type: "image/jpeg" }), { upsert: true });
  assert.equal(error, null);
  assert.equal(data.path, "fixture/avatar.jpg");
  assert.equal(uploads, 1);
});

test("SDK restores an expired stored session with a rotated token and clears a revoked session", async (t) => {
  for (const revoked of [false, true]) {
    // The SDK reports the expected revoked-token fixture to console.error.
    if (revoked) t.mock.method(console, "error", () => {});
    const user = { id: "10000000-0000-4000-8000-000000000003", aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" };
    const stored = new Map([["sb-fixture-auth-token", JSON.stringify({
      access_token: "expired-access", refresh_token: "restore-refresh", token_type: "bearer", user,
      expires_at: Math.floor(Date.now() / 1000) - 60,
    })]]);
    let refreshes = 0;
    const client = createClient(upstream, "sb_publishable_fixture", {
      auth: { autoRefreshToken: false, detectSessionInUrl: false, storage: {
        getItem: (key) => stored.get(key) ?? null, setItem: (key, value) => stored.set(key, value), removeItem: (key) => stored.delete(key),
      } },
      global: { fetch: createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: (proxied) => proxyCloudRequest(proxied, env, {
        fetchImpl: async (outbound) => {
          refreshes += 1;
          assert.equal(outbound.url, `${upstream}/auth/v1/token?grant_type=refresh_token`);
          assert.equal((await outbound.json()).refresh_token, "restore-refresh");
          return revoked
            ? Response.json({ code: "refresh_token_not_found", message: "Invalid Refresh Token: Refresh Token Not Found" }, { status: 400, headers: { "x-supabase-api-version": "2024-01-01" } })
            : Response.json({ access_token: "restored-access", refresh_token: "restored-refresh", token_type: "bearer", expires_in: 3600, user });
        },
      }) }) },
    });
    const { data, error } = await client.auth.getSession();
    assert.equal(refreshes, 1);
    if (revoked) {
      assert.equal(data.session, null);
      assert.equal(error.code, "refresh_token_not_found");
      assert.equal(stored.has("sb-fixture-auth-token"), false);
    } else {
      assert.equal(error, null);
      assert.equal(data.session.access_token, "restored-access");
      assert.equal(JSON.parse(stored.get("sb-fixture-auth-token")).refresh_token, "restored-refresh");
    }
  }
});
