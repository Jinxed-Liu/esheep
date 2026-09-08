import assert from "node:assert/strict";
import test from "node:test";
import { createContainerRouter } from "../container/router.mjs";
import { validateMiMoAPIKey } from "../server/config.mjs";

const farmID = "11111111-1111-4111-8111-111111111111";
const sessionID = "22222222-2222-4222-8222-222222222222";
function turn({ user = "alice", session = sessionID, headers = {}, body = {} } = {}) {
  return new Request("https://staging.esheepplus.com/api/assistant/turn", {
    method: "POST", headers: { authorization: `Bearer ${user}`, "x-mimo-api-key": "sk-test-never-real", ...headers },
    body: JSON.stringify({ farmID, sessionID: session, prompt: "概览", snapshot: {
      schemaVersion: "esheepnext-farm-assistant/v1", farm: { id: farmID },
    }, ...body }),
  });
}
function fixture() {
  const calls = [];
  const router = createContainerRouter({
    validateKey: validateMiMoAPIKey,
    verifyAccess: async ({ request }) => {
      const userID = request.headers.get("authorization").split(" ")[1];
      if (userID === "denied") throw { status: 403, code: "FARM_ACCESS_DENIED" };
      return { userID };
    },
  });
  const env = { HARNESS_RUNTIME_VERIFIED: "true", HARNESS_CONTAINER: { getByName(name) { return { async fetch(request) {
    calls.push({ name, headers: request.headers, body: await request.json() });
    return new Response("stream");
  } }; } } };
  return { router, calls, env };
}

test("auth and snapshot failures never start billable containers", async () => {
  const { router, calls, env } = fixture();
  assert.equal((await router(turn({ headers: { authorization: "" } }), env)).status, 401);
  assert.equal((await router(turn({ user: "denied" }), env)).status, 403);
  assert.equal((await router(turn({ body: { snapshot: {} } }), env)).status, 400);
  assert.equal((await router(turn({ headers: { "content-length": String(25 * 1_048_576) } }), env)).status, 413);
  assert.equal(calls.length, 0);
});

test("verified user and session control VM affinity; creation header cannot be forged", async () => {
  const { router, calls, env } = fixture();
  await router(turn(), env);
  await router(turn({ headers: { "x-esheep-session-create": "1" } }), env);
  await router(turn({ user: "bob" }), env);
  await router(turn({ session: null }), env);
  assert.equal(calls[0].name, calls[1].name);
  assert.notEqual(calls[0].name, calls[2].name);
  assert.equal(calls[1].headers.get("x-esheep-session-create"), "0");
  assert.equal(calls[3].headers.get("x-esheep-session-create"), "1");
  assert.match(calls[3].body.sessionID, /^[0-9a-f-]{36}$/);
  assert.equal(calls.some(call => call.name.includes("alice")), false);
});
