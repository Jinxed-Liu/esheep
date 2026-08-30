import assert from "node:assert/strict";
import test from "node:test";
import {
  buildFarmInsightData,
  projectFarmOperationEvent,
  projectionToReproductionRecord,
  projectionToWeaningRecord,
  projectionToWeightRecord,
} from "../src/lib/farmReadModels.js";

function operation(overrides = {}) {
  return {
    operation_id: "op-1",
    entity_id: "entity-1",
    entity_type: "note",
    revision: 7,
    occurred_at: "2026-08-29T08:00:00Z",
    ...overrides,
  };
}

const sheepByID = new Map([
  ["sheep-a", { id: "SHEEP-A", earTag: "A001", pen: "一号舍" }],
  ["sheep-b", { id: "SHEEP-B", earTag: "B002", pen: "二号舍" }],
  ["ewe-1", { id: "EWE-1", earTag: "M101", pen: "产羔舍" }],
  ["sire-1", { id: "SIRE-1", earTag: "G201", pen: "种公羊舍" }],
]);

const penNameByID = new Map([
  ["pen-1", "一号舍"],
  ["pen-2", "二号舍"],
]);

test("event projection resolves an archived sheep and exposes removal values", () => {
  const event = projectFarmOperationEvent({
    row: operation({ entity_type: "removal", entity_id: "remove-1" }),
    payload: {
      kind: "removeSheep",
      dates: { occurredAt: "2026-08-03T02:41:00Z" },
      identifiers: { sheepID: "SHEEP-A" },
      strings: { kind: "deceased", reason: "梭菌致死", note: "肺部感染和梭菌" },
      optionalStrings: { amountText: null, batchTotalAmountText: null },
    },
    sheepByID,
    penNameByID,
    actorName: "张三",
  });

  assert.equal(event.object, "羊只 A001");
  assert.equal(event.label, "死亡记录");
  assert.equal(event.detail, "死亡 · 梭菌致死");
  assert.equal(event.note, "肺部感染和梭菌");
  assert.equal(event.at, "2026-08-03T02:41:00Z");
  assert.deepEqual(event.fields.slice(0, 2), [
    { label: "离场类型", value: "死亡" },
    { label: "原因", value: "梭菌致死" },
  ]);
});

test("event projection exposes concrete weight, transfer, note, and care lambing values", () => {
  const weight = projectFarmOperationEvent({
    row: operation({ entity_type: "weight" }),
    payload: { kind: "recordWeight", identifiers: { sheepID: "SHEEP-A" }, strings: { kilogramsText: "43.25", note: "晨间" }, dates: { occurredAt: "2026-08-20T01:00:00Z" } },
    sheepByID,
    penNameByID,
    actorName: "李四",
  });
  assert.equal(weight.detail, "43.25 kg");
  assert.equal(weight.object, "羊只 A001");

  const transfer = projectFarmOperationEvent({
    row: operation({ entity_type: "transfer" }),
    payload: { kind: "transferSheep", identifiers: { sheepID: "SHEEP-A" }, optionalIdentifiers: { toPenID: "PEN-2" }, strings: { note: "断奶调舍" } },
    sheepByID,
    penNameByID,
    actorName: "李四",
  });
  assert.equal(transfer.detail, "转入 二号舍");

  const note = projectFarmOperationEvent({
    row: operation(),
    payload: { kind: "addNote", optionalIdentifiers: { sheepID: "SHEEP-A" }, strings: { text: "观察采食" } },
    sheepByID,
    penNameByID,
    actorName: "李四",
  });
  assert.equal(note.object, "羊只 A001");
  assert.equal(note.detail, "观察采食");

  const lambing = projectFarmOperationEvent({
    row: operation({ entity_type: "reproduction" }),
    payload: {
      kind: "care",
      careCommand: {
        recordLambing: {
          _0: {
            eweID: "EWE-1",
            sireID: "SIRE-1",
            parity: 3,
            birthDeadCount: 1,
            occurredAt: "2026-07-01T04:49:00Z",
            offspring: [
              { sheepID: "LAMB-1", earTag: "L001", sex: "ewe", isStillborn: false },
              { sheepID: "LAMB-2", earTag: "L002", sex: "ram", isStillborn: true },
            ],
          },
        },
      },
    },
    sheepByID,
    penNameByID,
    actorName: "王五",
  });
  assert.equal(lambing.object, "母羊 M101");
  assert.equal(lambing.detail, "产羔 2 只，其中死羔 1 只");
  assert.ok(lambing.fields.some((field) => field.label === "羔羊" && field.value.includes("L002（公，死羔）")));
});

test("projection normalizers parse direct and CareCommand farm payloads", () => {
  const weight = projectionToWeightRecord(
    { entity_id: "weight-1", modified_at: "2026-01-02T00:00:00Z" },
    { identifiers: { sheepID: "SHEEP-A" }, strings: { kilogramsText: "12.26" }, dates: { occurredAt: "2026-01-01T23:35:00Z" } },
  );
  assert.equal(weight.kilograms, 12.26);

  const weaning = projectionToWeaningRecord(
    { entity_id: "weaning-1", modified_at: "2026-02-01T00:00:00Z" },
    { identifiers: { sheepID: "SHEEP-A" }, optionalIdentifiers: { damID: "EWE-1" }, dates: { occurredAt: "2026-01-20T00:00:00Z" }, optionalDates: { birthAt: "2026-01-01T00:00:00Z" }, strings: { weanWeightText: "14.5" } },
  );
  assert.equal(weaning.weanWeight, 14.5);

  const direct = projectionToReproductionRecord(
    { entity_id: "repro-1", modified_at: "2026-01-10T00:00:00Z" },
    {
      identifiers: { eweID: "EWE-1" },
      optionalIdentifiers: { sireID: "SIRE-1" },
      dates: { occurredAt: "2026-01-10T00:00:00Z" },
      strings: { kind: "lambing" },
      integers: { lambCount: 1, parity: 2, birthDeadCount: 0 },
      lambingOffspring: [{ sheepID: "LAMB-1", legacyEarTag: "L001", sexRawValue: "母", birthWeightText: "4.2", isStillborn: false }],
    },
  );
  assert.equal(direct.kind, "lambing");
  assert.equal(direct.offspring[0].birthWeight, 4.2);
  assert.equal(direct.offspring[0].earTag, "L001");
  assert.equal(direct.offspring[0].sex, "母");

  const care = projectionToReproductionRecord(
    { entity_id: "repro-2", modified_at: "2026-02-10T00:00:00Z" },
    { kind: "care", careCommand: { recordLambing: { _0: { eweID: "EWE-1", parity: 3, birthDeadCount: 0, occurredAt: "2026-02-10T00:00:00Z", offspring: [{ sheepID: "LAMB-2", earTag: "L002", birthWeightText: "3.8" }] } } } },
  );
  assert.equal(care.source, "care");
  assert.equal(care.lambCount, 1);
});

test("insight model applies canonical weight priority and explicit lambing denominators", () => {
  const weightRecords = [
    { id: "w1", sheepID: "SHEEP-A", at: "2026-01-01T00:00:00Z", kilograms: 10 },
    { id: "w2", sheepID: "SHEEP-A", at: "2026-01-01T08:00:00Z", kilograms: 11 },
    { id: "w3", sheepID: "SHEEP-A", at: "2026-01-10T00:00:00Z", kilograms: 20 },
    { id: "w4", sheepID: "SHEEP-B", at: "2026-01-05T00:00:00Z", kilograms: 6 },
  ];
  const weaningRecords = [
    { id: "wean-1", sheepID: "SHEEP-A", at: "2026-01-10T00:00:00Z", birthAt: "2026-01-01T00:00:00Z", weanWeight: 21, birthWeight: 4 },
  ];
  const reproductionRecords = [
    {
      id: "r1", eweID: "EWE-1", at: "2026-01-05T00:00:00Z", kind: "lambing", parity: 2, birthDeadCount: 1, lambCount: 2,
      offspring: [
        { sheepID: "SHEEP-B", birthWeight: 5, isStillborn: false },
        { sheepID: "LAMB-2", birthWeight: null, isStillborn: true },
      ],
    },
    {
      id: "r2", eweID: "EWE-1", at: "2026-02-05T00:00:00Z", kind: "lambing", parity: null, birthDeadCount: 0, lambCount: 1,
      offspring: [{ sheepID: "LAMB-3", birthWeight: 3.5, isStillborn: false }],
    },
  ];
  const insight = buildFarmInsightData({
    weightRecords,
    weaningRecords,
    reproductionRecords,
    timeZone: "UTC",
    asOf: "2026-02-10T00:00:00Z",
  });

  // Same sheep/day ordinary weight wins over weaning/birth projections, and
  // the later ordinary weight wins within the same source priority. Matching
  // the App, the analysis cutoff is the latest ordinary weighing date, so the
  // later lambing-only birth sample is not pulled into this historical slice.
  assert.equal(insight.weight.canonicalSampleCount, 3);
  assert.equal(insight.weight.sheepSampleCount, 2);
  assert.equal(insight.weight.latestAverageKg, (20 + 6) / 2);
  assert.equal(insight.weight.adgSampleCount, 1);
  assert.ok(Math.abs(insight.weight.averageADGKgPerDay - 1) < 1e-10);

  assert.equal(insight.lamb.allLambingCount, 2);
  assert.equal(insight.lamb.completeLambingCount, 1);
  assert.equal(insight.lamb.totalBorn, 2);
  assert.equal(insight.lamb.deadBorn, 1);
  assert.equal(insight.lamb.mortalityRate, 0.5);
  assert.equal(insight.lamb.weaningWeightSampleCount, 1);
  assert.ok(Math.abs(insight.lamb.averageWeaningADGKgPerDay - (11 / 9)) < 1e-10);

  // App feed analytics requires pen identity, whole-day sheep-days and feed
  // lines; the legacy flat kilogram shortcut deliberately no longer exists.
  assert.equal(insight.feed.recordCount, 0);
  assert.equal(insight.feed.overview.effectivePenCount, 0);
});
