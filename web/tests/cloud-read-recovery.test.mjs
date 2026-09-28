import assert from "node:assert/strict";
import test from "node:test";
import {
  cloudAccessErrorMessage,
  loadWithTransientJWTClockRetry,
} from "../src/lib/cloudReadRecovery.js";

const jwtClockError = Object.assign(new Error("JWT issued at future"), { code: "PGRST303" });

test("retries a transient PostgREST JWT clock error once", async () => {
  let calls = 0;
  const value = await loadWithTransientJWTClockRetry(async () => {
    calls += 1;
    if (calls === 1) throw jwtClockError;
    return "verified farm";
  }, { delayMs: 0 });
  assert.equal(value, "verified farm");
  assert.equal(calls, 2);
  assert.match(cloudAccessErrorMessage(jwtClockError), /已自动重试/);
});

test("does not retry unrelated authentication failures", async () => {
  let calls = 0;
  const error = Object.assign(new Error("JWT expired"), { code: "PGRST303" });
  await assert.rejects(loadWithTransientJWTClockRetry(async () => {
    calls += 1;
    throw error;
  }, { delayMs: 0 }), (caught) => caught === error);
  assert.equal(calls, 1);
});

test("cancellation prevents the second cloud read", async () => {
  const controller = new AbortController();
  let calls = 0;
  const pending = loadWithTransientJWTClockRetry(async () => {
    calls += 1;
    throw jwtClockError;
  }, { signal: controller.signal, delayMs: 100 });
  controller.abort();
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(calls, 1);
});
