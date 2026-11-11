import assert from "node:assert/strict";
import test from "node:test";
import { sharedModuleLoader, preloadPage } from "../src/lib/pageModules.js";

test("hover and navigation share an import started before page data is ready", async () => {
  let imports = 0, resolve;
  const load = sharedModuleLoader(() => {
    imports += 1;
    return new Promise(done => { resolve = done; });
  });
  const speculative = load();
  const navigation = load();
  assert.equal(imports, 1);
  assert.equal(speculative, navigation);
  const module = { default: () => null };
  resolve(module);
  assert.equal(await navigation, module);
  assert.equal(await load(), module);
  assert.equal(imports, 1);
});

test("a transient preload failure does not poison a later navigation attempt", async () => {
  let calls = 0;
  const load = sharedModuleLoader(async () => {
    if (++calls === 1) throw new Error("temporary network failure");
    return { default: "page" };
  });
  await assert.rejects(load(), /temporary network/);
  assert.deepEqual(await load(), { default: "page" });
  assert.equal(calls, 2);
});

test("the eager home route and unknown routes do not trigger speculative imports", () => {
  assert.equal(preloadPage("home"), undefined);
  assert.equal(preloadPage("missing"), undefined);
});
