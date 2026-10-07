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

test("SDK sign-in, restore, refresh, and farm reads retain canonical sessions through same-origin HTTP", async () => {
  const calls = [], stored = new Map();
  const user = { id: "10000000-0000-4000-8000-000000000001", email: "fixture@example.test", aud: "authenticated", app_metadata: {}, user_metadata: {}, created_at: "2026-01-01T00:00:00Z" };
  const session = { access_token: "fixture-access", refresh_token: "fixture-refresh", expires_in: 3600, token_type: "bearer", user };
  const transport = createCloudFetch({ supabaseURL: upstream, siteOrigin: site, fetchImpl: async (proxied) => {
    assert.equal(new URL(proxied.url).origin, site);
    assert.equal(proxied.credentials, "omit");
    return proxyCloudRequest(proxied, env, { fetchImpl: async (outbound) => {
      const url = new URL(outbound.url);
      calls.push({ path: url.pathname + url.search, token: outbound.headers.get("authorization"), body: outbound.method === "POST" ? await outbound.json() : null });
      assert.equal(url.origin, upstream);
      assert.equal(outbound.headers.get("apikey"), "sb_publishable_fixture");
      return Response.json(url.pathname === "/auth/v1/token" ? session : url.pathname === "/auth/v1/user" ? user : [{ farm_id: "fixture" }]);
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
  assert.deepEqual((await restored.from("farm_registry").select("farm_id")).data, [{ farm_id: "fixture" }]);
  assert.equal((await restored.functions.invoke("esheep-cloud-checkpoints", { body: { farm_id: "fixture" } })).error, null);
  assert.deepEqual(calls.map((call) => call.path), ["/auth/v1/token?grant_type=password", "/auth/v1/user", "/auth/v1/token?grant_type=refresh_token", "/rest/v1/farm_registry?select=farm_id", "/functions/v1/esheep-cloud-checkpoints"]);
  assert.equal(calls[0].body.password, "fixture-password");
  assert.equal(calls[2].body.refresh_token, "fixture-refresh");
  assert.equal(calls[3].token, "Bearer fixture-access");
  assert.equal(calls[4].token, "Bearer fixture-access");
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
  await assert.rejects(transport(`${upstream}/auth/v1/user`, { signal: controller.signal }), { message: "Load failed" });
  assert.equal(cloudConnectionErrorMessage(new TypeError("Load failed")), "无法连接云端服务，请检查网络后重试。");
  assert.equal(cloudConnectionErrorMessage({ message: "Invalid login credentials" }), "Invalid login credentials");
});
