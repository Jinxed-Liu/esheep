import assert from "node:assert/strict";
import test from "node:test";
import * as analytics from "../src/lib/appAnalytics.js";
import { createFarmQueryEngine } from "../server/farm-query-core.mjs";
import { mortalityAnalysis } from "../server/agent-mortality.mjs";
const run = createFarmQueryEngine(analytics);
function data() {
  const sheep = ["a", "b", "c", "d"].map(id => ({ id, earTag: id === "a" ? "Q-AH032" : id, sex: "ewe", status: "active", enteredAt: "2026-08-01T00:00:00Z" }));
  return { schemaVersion: "esheepnext-farm-assistant/v1", farm: { id: "farm", generation: 1, revision: 5, timeZoneIdentifier: "Asia/Shanghai" }, capturedAt: "2026-11-05T00:00:00Z", source: { kind: "supabase-authorized-server-read" },
    activeSheep: [sheep[3]], analyticsSource: { sheep, removals: [
      { id: "r1", sheepID: "a", kind: "deceased", at: "2026-09-30T16:00:00Z" },
      { id: "r2", sheepID: "b", kind: "culled", at: "2026-10-15T00:00:00Z" },
      { id: "r3", sheepID: "c", kind: "sold", at: "2026-10-16T00:00:00Z" },
      { id: "r4", sheepID: "d", kind: "deceased", at: "2026-10-31T16:00:00Z" },
    ], transfers: [], weights: [], pens: [], reproduction: [], weanings: [] } };
}
const definition = { startDate: "2026-10-01", endDate: "2026-10-31", sex: "all", denominator: "opening_cohort" };
const opening = { farm_id:"farm", farm_generation:1, day:definition.startDate, basis:"期初", cloud_head:3, time_zone:"Asia/Shanghai",
  filters_applied:{day:definition.startDate, opening:true, sex:"all", breed:"", penName:""}, count:4, memberIDs:["a","b","c","d"] };

test("a month alone selects the opening roster, but a missing period requires clarification", () => {
  assert.throws(() => mortalityAnalysis(data(), {}), error => error.code === "NEEDS_USER_INPUT");
  assert.equal(run(data(), {kind:"mortality_summary", month:10}, opening).result.deathAndCullRate, 0.5);
  assert.equal(run(data(), {kind:"mortality_summary", month:12}, opening).filters_applied.startDate, "2025-12-01");
  assert.equal(run(data(), {kind:"mortality_summary", month:2,year:2024}, opening).filters_applied.endDate, "2024-02-29");
});
test("mortality counts farm-local boundaries and excludes sales from death/cull", () => {
  const result = mortalityAnalysis(data(), definition, opening);
  assert.equal(result.denominator, 4); assert.equal(result.deathCount, 1); assert.equal(result.cullCount, 1);
  assert.equal(result.soldCount, 1); assert.equal(result.deathAndCullRate, 0.5);
});
test("ambiguous removals block rates rather than pretending completeness", () => {
  const snapshot = data(); snapshot.analyticsSource.removals.push({ id: "x", sheepID: null, kind: "deceased", at: "2026-10-05T00:00:00Z" });
  const result = mortalityAnalysis(snapshot, definition, opening); assert.equal(result.deathAndCullRate, null); assert.equal(result.missingLinkedRemovalCount, 1);
});
test("death after an earlier sale cannot be counted as an in-farm rate without a return", () => {
  const snapshot = data();
  snapshot.analyticsSource.removals.push({ id: "later", sheepID: "c", kind: "deceased", at: "2026-10-20T00:00:00Z" });
  const result = mortalityAnalysis(snapshot, definition, opening);
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
test("unknown entry dates and a transfer after exit still prevent inferring period exposure", () => {
  const s = data();
  s.analyticsSource.sheep[0].enteredAt = "0000-12-30T00:00:00.000Z";
  s.analyticsSource.sheep[1].enteredAt = null;
  s.analyticsSource.removals.push({ id: "prior", sheepID: "c", kind: "sold", at: "2026-09-02T00:00:00Z" });
  s.analyticsSource.transfers.push({ id: "moved", sheepID: "c", at: "2026-09-05T00:00:00Z" });
  const r = mortalityAnalysis(s, { ...definition, denominator:"period_exposed" });
  assert.equal(r.denominator, 1);
  assert.equal(r.deathAndCullRate, null);
  assert.equal(r.issueCounts["入群日期缺失或为占位日期"], 2);
  assert.equal(r.issueCounts["离群同一时刻或之后仍有圈舍记录，需核对原始记录"], 1);
});

test("opening membership is decided by identity on the opening day, despite duplicate tags, later statuses and repeated events", () => {
  const s = data();
  s.analyticsSource.sheep[0].enteredAt = null;
  s.analyticsSource.sheep[0].isHistoricalArchive = true;
  s.analyticsSource.sheep[1].earTag = s.analyticsSource.sheep[0].earTag;
  s.analyticsSource.removals.push({id:"duplicate", kind:"deceased", sheepID:"A", at:"2026-10-20T00:00:00Z"},
    {id:"deleted", kind:"culled", sheepID:"d", at:"2026-10-20T00:00:00Z", deletedAt:1});
  const r = mortalityAnalysis(s,{month:10},{...opening,count:3,memberIDs:["a","c","d"]});
  assert.deepEqual([r.denominator,r.deathCount,r.cullCount,r.soldCount,r.deathAndCullRate], [3,1,0,1,1/3]);
});

test("mismatched or absent rosters are unavailable and distinct from an empty verified roster", () => {
  for (const bad of [undefined, {count:4}, {...opening, day:"2026-09-30"}, {...opening,farm_generation:0},
    {...opening, farm_id:"other"}, {...opening, cloud_head:6}, {...opening, memberIDs:["a","A","c","d"]},
    {...opening,filters_applied:{...opening.filters_applied,sex:"ram"}}]) {
    const r = mortalityAnalysis(data(),{month:10},bad);
    assert.equal(r.denominator,null); assert.equal(r.deathCount,null); assert.equal(r.deathAndCullRate,null);
  }
  const empty = mortalityAnalysis(data(),{month:10},{...opening,count:0,memberIDs:[]});
  assert.equal(empty.denominator,0); assert.equal(empty.deathCount,0); assert.equal(empty.deathAndCullRate,null);
});
