import assert from "node:assert/strict";
import test from "node:test";
import * as analytics from "../src/lib/appAnalytics.js";
import { createFarmQueryEngine } from "../server/farm-query-core.mjs";
import { mortalityAnalysis } from "../server/agent-mortality.mjs";
const run = createFarmQueryEngine(analytics);
function data() {
  const sheep = ["a", "b", "c", "d"].map(id => ({ id, earTag: id === "a" ? "Q-AH032" : id, sex: "ewe", status: "active", enteredAt: "2026-08-01T00:00:00Z" }));
  return { schemaVersion: "esheepnext-farm-assistant/v1", farm: { id: "farm", timeZoneIdentifier: "Asia/Shanghai" }, capturedAt: "2026-11-05T00:00:00Z", source: { kind: "supabase-authorized-server-read" },
    activeSheep: [sheep[3]], analyticsSource: { sheep, removals: [
      { id: "r1", sheepID: "a", kind: "deceased", at: "2026-09-30T16:00:00Z" },
      { id: "r2", sheepID: "b", kind: "culled", at: "2026-10-15T00:00:00Z" },
      { id: "r3", sheepID: "c", kind: "sold", at: "2026-10-16T00:00:00Z" },
      { id: "r4", sheepID: "d", kind: "deceased", at: "2026-10-31T16:00:00Z" },
    ], transfers: [], weights: [], pens: [], reproduction: [], weanings: [] } };
}
const definition = { startDate: "2026-10-01", endDate: "2026-10-31", sex: "all", denominator: "opening_cohort" };
test("mortality asks for period and denominator instead of guessing", () => {
  assert.throws(() => mortalityAnalysis(data(), {}), error => error.code === "NEEDS_USER_INPUT");
  assert.throws(() => mortalityAnalysis(data(), { startDate: "2026-10-01", endDate: "2026-10-31" }), error => error.fields.includes("denominator"));
});
test("mortality counts farm-local boundaries and excludes sales from death/cull", () => {
  const result = mortalityAnalysis(data(), definition);
  assert.equal(result.denominator, 4); assert.equal(result.deathCount, 1); assert.equal(result.cullCount, 1);
  assert.equal(result.soldCount, 1); assert.equal(result.deathAndCullRate, 0.5);
});
test("ambiguous removals block rates rather than pretending completeness", () => {
  const snapshot = data(); snapshot.analyticsSource.removals.push({ id: "x", sheepID: "missing", kind: "deceased", at: "2026-10-05T00:00:00Z" });
  const result = mortalityAnalysis(snapshot, definition); assert.equal(result.deathAndCullRate, null); assert.equal(result.missingLinkedRemovalCount, 1);
});
test("death after an earlier sale cannot be counted as an in-farm rate without a return", () => {
  const snapshot = data();
  snapshot.analyticsSource.removals.push({ id: "later", sheepID: "c", kind: "deceased", at: "2026-10-20T00:00:00Z" });
  const result = mortalityAnalysis(snapshot, definition);
  assert.equal(result.deathAndCullRate, null);
  assert.ok(result.issues.some(i => i.sheepID === "c" && i.reason.includes("此前离场")));
});
test("sheep lookup includes archived/removed profiles, normalizes separators without merging identities", () => {
  const snapshot = data(); snapshot.analyticsSource.sheep[0].status = "deceased";
  assert.equal(run(snapshot, { kind: "sheep_search", query: "Ｑ AH032" }).result.rows[0].id, "a");
  assert.equal(run(snapshot, { kind: "sheep_search", query: "QAH032", scope: "active" }).result.totalMatches, 0);
  snapshot.analyticsSource.sheep.push({ ...snapshot.analyticsSource.sheep[0], id: "other", earTag: "QAH032" });
  assert.equal(run(snapshot, { kind: "sheep_search", query: "QAH032" }).result.totalMatches, 2);
});
test("unsupported filters fail instead of silently narrowing or widening scope", () => {
  assert.throws(() => run(data(), { kind: "mortality_summary", ...definition, penID: "one" }), /不能执行筛选/);
  assert.throws(() => run(data(), { kind: "weight_summary", scope: "all" }), error => error.code === "NEEDS_USER_INPUT");
});
test("unknown entry dates and a transfer after exit cannot establish opening membership", () => {
  const s = data();
  s.analyticsSource.sheep[0].enteredAt = "0000-12-30T00:00:00.000Z";
  s.analyticsSource.sheep[1].enteredAt = null;
  s.analyticsSource.removals.push({ id: "prior", sheepID: "c", kind: "sold", at: "2026-09-02T00:00:00Z" });
  s.analyticsSource.transfers.push({ id: "moved", sheepID: "c", at: "2026-09-05T00:00:00Z" });
  const r = mortalityAnalysis(s, definition);
  assert.equal(r.denominator, 1);
  assert.equal(r.deathAndCullRate, null);
  assert.equal(r.issueCounts["入群日期缺失或为占位日期"], 2);
  assert.equal(r.issueCounts["离群后有转舍记录，在场状态待核对"], 1);
});
