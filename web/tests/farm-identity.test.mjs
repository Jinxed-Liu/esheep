import assert from "node:assert/strict";
import test from "node:test";
import { applyFarmIdentity } from "../src/lib/cloudV2Checkpoint.js";
const id = "00000000-0000-4000-8000-000000000001";
const farm = { id, generation: 3 };
const identity = { farmID: id, farmGeneration: 3, name: "吉昊羊场", revision: 1 };
const projection = () => ({ models: new Map([["FarmRecord", new Map([[id, { id, name: "星露谷牧场" }]])], ["WeightRecord", new Map([["weight", { kilogramsText: "25.10" }]])]]) });
test("live identity overrides cached snapshot name without changing business data", () => {
 const p = projection(); const weights = structuredClone(p.models.get("WeightRecord"));
 applyFarmIdentity(p, identity, farm);
 assert.equal(p.models.get("FarmRecord").get(id).name, "吉昊羊场");
 assert.deepEqual(p.models.get("WeightRecord"), weights);
 applyFarmIdentity(p, { ...identity, name: "旧名", revision: 0 }, farm);
 assert.equal(p.models.get("FarmRecord").get(id).name, "吉昊羊场");
});
test("foreign farm, wrong generation, malformed or conflicting identity is rejected", () => {
 for (const bad of [{ farmID: "other" }, { farmGeneration: 4 }, { revision: -1 }, { name: " " }, { name: "羊\n场" }, { name: "羊".repeat(81) }]) {
  assert.throws(() => applyFarmIdentity(projection(), { ...identity, ...bad }, farm));
 }
 const p = projection(); applyFarmIdentity(p, identity, farm);
 assert.throws(() => applyFarmIdentity(p, { ...identity, name: "同版本不同名" }, farm));
});
test("older server without identity leaves the verified snapshot unchanged", () => {
 const p = projection(); applyFarmIdentity(p, undefined, farm);
 assert.equal(p.models.get("FarmRecord").get(id).name, "星露谷牧场");
});
