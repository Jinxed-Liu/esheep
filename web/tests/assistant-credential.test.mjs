import assert from "node:assert/strict";
import test from "node:test";
import {
  describeMiMoAPIKey,
  loadMiMoCredential,
  normalizeMiMoAPIKey,
  removeMiMoCredential,
  saveMiMoCredential,
} from "../src/lib/assistantCredential.js";

test("accepts both personal MiMo plans and rejects malformed keys", () => {
  assert.equal(normalizeMiMoAPIKey("  sk-personal-test-key  "), "sk-personal-test-key");
  assert.equal(describeMiMoAPIKey("sk-personal-test-key"), "Pay-as-you-go");
  assert.equal(describeMiMoAPIKey("tp-personal-test-key"), "Token Plan");
  assert.throws(() => normalizeMiMoAPIKey(""), /请输入/);
  assert.throws(() => normalizeMiMoAPIKey("shared-key-value"), /sk- 或 tp-/);
});

test("keeps a credential usable in memory when persistent browser storage is unavailable", async () => {
  const accountID = "credential-test-account";
  const apiKey = "sk-personal-memory-key";
  const saved = await saveMiMoCredential(accountID, apiKey);
  assert.equal(saved.apiKey, apiKey);
  assert.equal(saved.persistence, "memory");
  assert.equal((await loadMiMoCredential(accountID)).apiKey, apiKey);
  await removeMiMoCredential(accountID);
  assert.equal(await loadMiMoCredential(accountID), null);
});
