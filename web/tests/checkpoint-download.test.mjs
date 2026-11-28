import assert from "node:assert/strict";
import test from "node:test";
import { receiveCheckpointBytes } from "../src/lib/checkpointDownload.js";

const payload = Uint8Array.of(1, 2, 3, 4);
const fast = { retryDelayMs: 1, idleTimeoutMs: 200 };

test("a transient network failure retries the immutable download and reports byte progress", async () => {
  let attempts = 0;
  const progress = [], retries = [];
  const bytes = await receiveCheckpointBytes(async () => {
    if (++attempts === 1) throw Object.assign(new Error("network"), { code: "CLOUD_NETWORK_FAILED" });
    return new Response(payload);
  }, 4, { ...fast, onBytes: n => progress.push(n), onRetry: n => retries.push(n) });
  assert.deepEqual(bytes, payload);
  assert.equal(attempts, 2);
  assert.deepEqual(retries, [2]);
  assert.equal(progress.at(-1), 4);
});

test("a truncated response is restarted without mixing bytes from two attempts", async () => {
  let attempts = 0;
  const bytes = await receiveCheckpointBytes(async () => new Response(++attempts === 1 ? Uint8Array.of(9) : payload), 4, fast);
  assert.deepEqual(bytes, payload);
  assert.equal(attempts, 2);
});

test("stalled response bodies are cancelled and retried", { timeout: 1000 }, async () => {
  let attempts = 0, cancelled = false;
  const bytes = await receiveCheckpointBytes(async () => {
    if (++attempts > 1) return new Response(payload);
    return new Response(new ReadableStream({
      start(c) { c.enqueue(Uint8Array.of(9)); },
      cancel() { cancelled = true; },
    }));
  }, 4, { ...fast, idleTimeoutMs: 20 });
  assert.deepEqual(bytes, payload);
  assert.equal(cancelled, true);
  assert.equal(attempts, 2);
});

test("a slow progressing body may take longer than the idle timeout", { timeout: 1000 }, async () => {
  let interval;
  const bytes = await receiveCheckpointBytes(async () => new Response(new ReadableStream({
    start(c) {
      let index = 0;
      interval = setInterval(() => {
        c.enqueue(payload.slice(index, ++index));
        if (index === payload.length) { clearInterval(interval); c.close(); }
      }, 20);
    },
    cancel() { clearInterval(interval); },
  })), 4, { ...fast, idleTimeoutMs: 60, maxAttempts: 1 });
  assert.deepEqual(bytes, payload);
});

test("header stalls abort the request and exhaust a bounded retry budget", { timeout: 1000 }, async () => {
  let attempts = 0;
  await assert.rejects(receiveCheckpointBytes(signal => {
    attempts++;
    return new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
  }, 4, { ...fast, idleTimeoutMs: 15 }), e => e.code === "CLOUD_V2_DOWNLOAD_FAILED");
  assert.equal(attempts, 3);
});

test("storage authorization failures request one fresh authorized ticket", async () => {
  const renewals = [];
  const bytes = await receiveCheckpointBytes(async (_signal, refresh) => {
    renewals.push(refresh);
    return refresh ? new Response(payload) : new Response("expired", { status: 400 });
  }, 4, fast);
  assert.deepEqual(bytes, payload);
  assert.deepEqual(renewals, [false, true]);
});

test("permission still denied after renewal fails without an unbounded auth loop", async () => {
  let attempts = 0;
  await assert.rejects(receiveCheckpointBytes(async () => {
    attempts++;
    return new Response("denied", { status: 403 });
  }, 4, fast), e => e.code === "CLOUD_V2_DOWNLOAD_FAILED");
  assert.equal(attempts, 2);
});

test("oversized and missing objects are not treated as transient network failures", async () => {
  for (const response of [new Response(Uint8Array.of(1,2,3,4,5)), new Response("missing", { status: 404 })]) {
    let attempts = 0;
    await assert.rejects(receiveCheckpointBytes(async () => { attempts++; return response; }, 4, fast));
    assert.equal(attempts, 1);
  }
});

test("a cancelled receive stops its pending body and never retries", { timeout: 1000 }, async () => {
  const controller = new AbortController();
  let attempts = 0, cancelled = false;
  const pending = receiveCheckpointBytes(async () => {
    attempts++;
    return new Response(new ReadableStream({ cancel() { cancelled = true; } }));
  }, 4, { ...fast, signal: controller.signal });
  setTimeout(() => controller.abort(), 10);
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(attempts, 1);
  assert.equal(cancelled, true);
});

test("cancellation during backoff prevents the next request", async () => {
  const controller = new AbortController();
  let attempts = 0;
  await assert.rejects(receiveCheckpointBytes(async () => {
    attempts++;
    return new Response("unavailable", { status: 503 });
  }, 4, { ...fast, signal: controller.signal, onRetry() { controller.abort(); } }), { name: "AbortError" });
  assert.equal(attempts, 1);
});
