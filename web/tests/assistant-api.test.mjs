import assert from "node:assert/strict";
import test from "node:test";
import { createAssistantAPI } from "../server/api.mjs";

const environment = {
  SUPABASE_URL: "https://project.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
};
const userAPIKey = "sk-test-not-real";

test("streams a farm-scoped assistant turn after authorization", async () => {
  const calls = [];
  const harness = {
    async *runTurn(input) {
      calls.push(input);
      yield { type: "session", sessionID: "11111111-1111-4111-8111-111111111111", model: "mimo-v2.5", multimodal: true };
      yield { type: "assistant", itemID: "answer-1", text: "已核对" };
      yield { type: "done", model: "mimo-v2.5" };
    },
  };
  const api = createAssistantAPI({
    environment,
    harness,
    authVerifier: async ({ farmID }) => ({ userID: "user-1", membership: { farm_id: farmID } }),
  });
  const snapshot = { schemaVersion: "esheepnext-farm-assistant/v1", farm: { id: "farm-1" } };
  const response = await api(new Request("https://example.test/api/assistant/turn", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer test", "x-mimo-api-key": userAPIKey },
    body: JSON.stringify({
      farmID: "farm-1",
      prompt: "看图",
      snapshot,
      attachments: [{ mimeType: "image/png", dataURL: "data:image/png;base64,iVBORw0KGgo=" }],
    }),
  }));
  assert.equal(response.status, 200);
  const events = (await response.text()).trim().split("\n").map(JSON.parse);
  assert.equal(events[0].type, "session");
  assert.equal(events[1].text, "已核对");
  assert.equal(calls[0].userID, "user-1");
  assert.equal(calls[0].farmID, "farm-1");
  assert.equal(calls[0].attachments.length, 1);
  assert.equal(calls[0].mimoAPIKey, userAPIKey);
});

test("rejects a snapshot for a different farm before invoking the harness", async () => {
  const api = createAssistantAPI({
    environment,
    harness: { async *runTurn() { throw new Error("must not run"); } },
    authVerifier: async () => ({ userID: "user-1" }),
  });
  const response = await api(new Request("https://example.test/api/assistant/turn", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ farmID: "farm-1", prompt: "概览", snapshot: { farm: { id: "farm-2" } } }),
  }));
  assert.equal(response.status, 400);
  assert.equal((await response.json()).code, "SNAPSHOT_SCOPE_MISMATCH");
});

test("status exposes both model names but no key or endpoint", async () => {
  const api = createAssistantAPI({ environment, harness: {}, authVerifier: async () => ({ userID: "user-1" }) });
  const response = await api(new Request("https://example.test/api/assistant/status"));
  const payload = await response.json();
  assert.equal(payload.model, "mimo-v2.5-pro");
  assert.equal(payload.multimodalModel, "mimo-v2.5");
  assert.equal(payload.capabilities.includes("image_input"), true);
  assert.equal(payload.requiresUserAPIKey, true);
  assert.equal(JSON.stringify(payload).includes(userAPIKey), false);
  assert.equal(JSON.stringify(payload).includes("xiaomimimo.com"), false);
});

test("requires a valid per-user MiMo key without invoking the harness", async () => {
  let invoked = false;
  const api = createAssistantAPI({
    environment,
    harness: { async *runTurn() { invoked = true; } },
    authVerifier: async () => ({ userID: "user-1" }),
  });
  const snapshot = { schemaVersion: "esheepnext-farm-assistant/v1", farm: { id: "farm-1" } };
  const request = (apiKey) => new Request("https://example.test/api/assistant/turn", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer test",
      ...(apiKey === undefined ? {} : { "x-mimo-api-key": apiKey }),
    },
    body: JSON.stringify({ farmID: "farm-1", prompt: "概览", snapshot }),
  });
  const missing = await api(request(undefined));
  assert.equal(missing.status, 400);
  assert.equal((await missing.json()).code, "MISSING_USER_MIMO_API_KEY");
  const invalid = await api(request("server-shared-key"));
  assert.equal(invalid.status, 400);
  assert.equal((await invalid.json()).code, "INVALID_USER_MIMO_API_KEY");
  assert.equal(invoked, false);
});
