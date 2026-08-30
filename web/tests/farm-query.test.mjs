import assert from "node:assert/strict";
import test from "node:test";
import * as analytics from "../src/lib/appAnalytics.js";
import { createFarmQueryEngine } from "../server/farm-query-core.mjs";

const snapshot = {
  schemaVersion: "esheepnext-farm-assistant/v1",
  capturedAt: "2026-08-31T08:00:00Z",
  source: { description: "测试只读投影" },
  farm: { id: "farm-1", name: "测试牧场", revision: 12, timeZoneIdentifier: "Asia/Shanghai" },
  metrics: { activeSheep: 2, activePens: 1, feedsToday: 0 },
  projectionCoverage: { real: ["sheep", "weight"] },
  dataAvailability: { activeSheep: 2, weights: 3, events: 1 },
  activeSheep: [
    { id: "sheep-1", earTag: "A001", breed: "湖羊", purpose: "育肥", sex: "ewe", penID: "pen-1", pen: "一号圈", status: "active" },
    { id: "sheep-2", earTag: "A002", breed: "湖羊", purpose: "育肥", sex: "ram", penID: "pen-1", pen: "一号圈", status: "active" },
  ],
  pens: [{ id: "pen-1", name: "一号圈", headCount: 2 }],
  events: [{ id: "event-1", type: "weight", at: "2026-08-30T08:00:00Z", earTag: "A001", title: "称重" }],
  analyticsSource: {
    sheep: [
      { id: "sheep-1", earTag: "A001", breed: "湖羊", purpose: "育肥", sex: "ewe", status: "active", enteredAt: "2026-01-01T00:00:00Z", initialPenID: "pen-1", currentPenID: "pen-1" },
      { id: "sheep-2", earTag: "A002", breed: "湖羊", purpose: "育肥", sex: "ram", status: "active", enteredAt: "2026-01-01T00:00:00Z", initialPenID: "pen-1", currentPenID: "pen-1" },
    ],
    pens: [{ id: "pen-1", name: "一号圈" }],
    weights: [
      { id: "w1", sheepID: "sheep-1", at: "2026-08-01T08:00:00Z", kilograms: 40 },
      { id: "w2", sheepID: "sheep-1", at: "2026-08-30T08:00:00Z", kilograms: 46 },
      { id: "w3", sheepID: "sheep-2", at: "2026-08-30T09:00:00Z", kilograms: 50 },
    ],
    weanings: [], reproduction: [], removals: [], transfers: [], batches: [], batchMemberships: [], feeds: [], troughObservations: [], dailyPenCounts: [],
  },
};

const runFarmQuery = createFarmQueryEngine(analytics);

test("returns an evidence envelope for App-aligned weight analytics", () => {
  const output = runFarmQuery(snapshot, { kind: "weight_summary", scope: "all" });
  assert.equal(output.ok, true);
  assert.equal(output.query_kind, "weight_summary");
  assert.equal(output.time_zone, "Asia/Shanghai");
  assert.equal(output.result.canonicalSampleCount, 3);
  assert.equal(output.result.latestAverageWeight, 48);
  assert.equal(output.result.latestAverageWeightSampleCount, 2);
  assert.equal(output.result.latestAverageADGSampleCount, 1);
  assert.equal(output.row_count, 3);
});

test("searches only the active-sheep view and reports result truncation", () => {
  const output = runFarmQuery(snapshot, { kind: "sheep_search", query: "湖羊", limit: 1 });
  assert.equal(output.row_count, 2);
  assert.equal(output.result.rows.length, 1);
  assert.equal(output.completeness.resultTruncated, true);
});

test("does not invent unsupported query kinds", () => {
  assert.throws(() => runFarmQuery(snapshot, { kind: "profit_forecast" }), /不支持的查询类型/);
});
