import assert from "node:assert/strict";
import test from "node:test";
import schema from "../../tools/esheep_cloud_checkpoint_schema_v1.json" with { type: "json" };
import { createV2Projection, finishV2Projection } from "../src/lib/cloudV2Projection.js";
import { snapshotFromCloudProjection } from "../server/agent-cloud.mjs";
import { farmDataCatalog, queryCloudRecords } from "../server/agent-records.mjs";
import { createFarmQueryEngine } from "../server/farm-query-core.mjs";
import * as analytics from "../src/lib/appAnalytics.js";
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const farmID = id(1), sheepID = id(2), penID = id(3);
const apple = text => (+new Date(text) - 978307200000) / 1000;
const at = apple("2026-08-01T00:00:00Z");
function record(model, fields) {
  return { model, values: { ...Object.fromEntries(Object.entries(schema[model].fields).map(([key, type]) => [key,
    type.endsWith("?") ? null : type === "UUID" ? farmID : type === "Date" ? at : type === "Bool" ? false : type === "String" ? "" : type === "Data" ? { json: {} } : 0])), ...fields } };
}
async function fixture() {
  const records = [record("FarmRecord", { id: farmID, name: "隔离测试牧场", timeZoneIdentifier: "Asia/Shanghai" }),
    record("PenRecord", { id: penID, name: "十二舍", isActive: true }),
    record("SheepRecord", { id: sheepID, earTag: "A001", sexRawValue: "ewe", breed: "湖羊", statusRawValue: "active", initialPenID: penID, currentPenID: penID }),
    record("WeightRecord", { id: id(4), sheepID, kilogramsText: "40", occurredAt: apple("2026-09-01T00:00:00Z") }),
    record("WeightRecord", { id: id(5), sheepID, kilogramsText: "37", occurredAt: apple("2026-09-11T00:00:00Z") }),
    record("RemovalRecord", { id: id(6), sheepID, kindRawValue: "deceased", occurredAt: apple("2026-10-01T00:00:00Z") })];
  const manifest = { farmID, farmGeneration: 1, checkpointID: id(50), boundaryEventSequence: 42,
    modelCounts: Object.fromEntries([...new Set(records.map(r => r.model))].map(model => [model, records.filter(r => r.model === model).length])) };
  const projection = { ...finishV2Projection(createV2Projection(records, manifest), { now: +new Date("2026-11-05T00:00:00Z") }), manifest, revision: 42 };
  return snapshotFromCloudProjection(projection, { id: farmID, generation: 1 }, new Date("2026-11-05T00:00:00Z"));
}
test("server snapshot uses verified cloud history and preserves removed sheep and weight units", async () => {
  const snapshot = await fixture();
  assert.equal(snapshot.activeSheep.length, 0);
  assert.equal(snapshot.analyticsSource.sheep.length, 1);
  assert.equal(snapshot.analyticsSource.removals[0].kind, "deceased");
  assert.equal(snapshot.analyticsSource.weights[0].kilograms, 40);
  assert.equal(snapshot.farm.name, "隔离测试牧场"); assert.equal(snapshot.farm.revision, 42);
  const result = createFarmQueryEngine(analytics)(snapshot, { kind: "weight_summary", startDate: "2026-09-01", endDate: "2026-09-11", scope: "all" });
  assert.equal(result.result.averageDailyGainGrams, -300);
  assert.equal(result.result.latestAverageADGSampleCount, 1);
});
test("catalog and record queries exclude identity/security datasets and honor date boundaries", async () => {
  const snapshot = await fixture(); const catalog = farmDataCatalog(snapshot);
  assert.ok(catalog.datasets.some(d => d.name === "weights"));
  assert.ok(!catalog.datasets.some(d => d.name === "profiles"));
  const result = queryCloudRecords(snapshot, { dataset: "weights", fields: ["id", "kilogramsText", "occurredAt"],
    filtersJSON: JSON.stringify([{ field: "occurredAt", op: "gte", value: "2026-09-11" }, { field: "occurredAt", op: "lte", value: "2026-09-11" }]), limit: 10, aggregate: "none" });
  assert.equal(result.totalRows, 1); assert.equal(result.rows[0].kilogramsText, "37");
  assert.equal(result.rows[0].occurredAt, "2026-09-11T00:00:00.000Z");
  assert.throws(() => queryCloudRecords(snapshot, { dataset: "auth.users" }), /未知业务/);
  assert.throws(() => queryCloudRecords(snapshot, { dataset: "weights", fields: ["farmID"] }), /选择字段/);
  assert.throws(() => queryCloudRecords(snapshot, { dataset: "weights", aggregate: "average", metricField: "kilogramsText" }), /专业计算/);
  assert.throws(() => queryCloudRecords(snapshot, { dataset: "weights", filtersJSON: '[{"field":"occurredAt","op":"gte","value":"2026-02-31"}]' }), /日期条件无效/);
  assert.throws(() => queryCloudRecords(snapshot, { dataset: "weights", filtersJSON: '[{"field":"occurredAt","op":"eq","value":"2026-09-11"}]' }), /自然日查询/);
});
