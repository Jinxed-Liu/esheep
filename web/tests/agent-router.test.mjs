import assert from "node:assert/strict";
import test from "node:test";
import { createAgentRouter } from "../container/agent-router.mjs";

const farm = "00000000-0000-4000-8000-000000000001";
function request(user = "alice", headers = {}) {
  return new Request(`https://app.esheepplus.com/api/assistant/agent/turn?farm_id=${farm}`, {
    method: "POST", headers: { authorization: `Bearer ${user}`, "x-agent-consent": "2026-11-05-agent-v1", "x-assistant-api-key": "sk-test-never-real", ...headers },
    body: '{"provider":"openai","input":[{"role":"user","content":"查羊"}]}',
  });
}
function fixture() {
  const calls = [];
  const route = createAgentRouter({ verifyAccess: async ({ request }) => {
    const userID = request.headers.get("authorization").split(" ")[1];
    if (userID === "denied") throw { status: 403 };
    return { userID, membership: { provider: "esheep_cloud", initial_sync_ready: true } };
  } });
  const env = { SUPABASE_URL: "https://test.supabase.co", SUPABASE_PUBLISHABLE_KEY: "test", AGENT_RUNTIME_VERIFIED: "true",
    HARNESS_CONTAINER: { getByName(name) { return { async fetch(request) { calls.push({ name, body: await request.text() }); return new Response("ok"); } }; } } };
  return { route, env, calls };
}
test("Agent gateway rejects missing consent, authorization and unverified deployments before starting a container", async () => {
  const { route, env, calls } = fixture();
  assert.equal((await route(request("alice", { authorization: "" }), env)).status, 401);
  assert.equal((await route(request("denied"), env)).status, 403);
  assert.equal((await route(request("alice", { "x-agent-consent": "" }), env)).status, 403);
  assert.equal((await route(request(), { ...env, AGENT_RUNTIME_VERIFIED: "false" })).status, 503);
  assert.equal(calls.length, 0);
});
test("Agent container affinity is bound to verified account and farm, with the body forwarded intact", async () => {
  const { route, env, calls } = fixture();
  await route(request(), env); await route(request(), env); await route(request("bob"), env);
  assert.equal(calls[0].name, calls[1].name); assert.notEqual(calls[0].name, calls[2].name);
  assert.match(calls[0].name, /^farm-agent-[a-f0-9]{64}$/);
  assert.equal(JSON.parse(calls[0].body).provider, "openai");
});
