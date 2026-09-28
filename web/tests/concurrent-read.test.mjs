import assert from "node:assert/strict";
import test from "node:test";
import { concurrentRead } from "../src/lib/concurrentRead.js";

test("a finished slot starts the next download while a slow sibling remains pending", async () => {
  const started = [];
  const release = new Map();
  const pending = concurrentRead([0, 1, 2, 3], (item) => {
    started.push(item);
    return new Promise((resolve) => release.set(item, () => resolve(item)));
  }, { limit: 2 });
  assert.deepEqual(started, [0, 1]);
  release.get(1)();
  await new Promise(setImmediate);
  assert.deepEqual(started, [0, 1, 2]);
  release.get(2)();
  await new Promise(setImmediate);
  assert.deepEqual(started, [0, 1, 2, 3]);
  release.get(3)();
  release.get(0)();
  assert.deepEqual(await pending, [0, 1, 2, 3]);
});

test("a failed download cancels siblings and does not start queued downloads", async () => {
  const failure = new Error("corrupt checkpoint");
  const started = [];
  let siblingSignal;
  await assert.rejects(concurrentRead([0, 1, 2], async (item, signal) => {
    started.push(item);
    if (item === 0) throw failure;
    siblingSignal = signal;
    return new Promise((resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    });
  }, { limit: 2 }), (error) => error === failure);
  assert.deepEqual(started, [0, 1]);
  assert.equal(siblingSignal.aborted, true);
});

test("an already cancelled workspace starts no downloads", async () => {
  const controller = new AbortController();
  controller.abort();
  let reads = 0;
  await assert.rejects(concurrentRead([1], () => { reads++; }, { signal: controller.signal }), { name: "AbortError" });
  assert.equal(reads, 0);
});
