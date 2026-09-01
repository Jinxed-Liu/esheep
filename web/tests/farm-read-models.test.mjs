import assert from "node:assert/strict";
import test from "node:test";
import {
  buildEventSheepIndex,
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

const batchNameByID = new Map([["batch-1", "育肥一批"]]);
const membershipByID = new Map([["member-1", { id: "MEMBER-1", batchID: "BATCH-1", sheepID: "SHEEP-A" }]]);

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

test("care purpose history resolves tuple payloads to ear tags and a concrete event", () => {
  const rows = [{
    ...operation({ entity_type: "sheep", entity_id: "SHEEP-A" }),
    payload_json: {
      kind: "care",
      careCommand: { setSheepPurpose: { _0: "SHEEP-A", _1: "繁殖母羊", _2: "选留", _3: 8 } },
      optionalStrings: { previousSheepPurpose: "后备母羊" },
      dates: { sheepPurposeChangedAt: "2026-08-30T02:00:00Z" },
    },
  }];
  const sheepIndex = buildEventSheepIndex(rows);
  const event = projectFarmOperationEvent({
    row: rows[0],
    payload: rows[0].payload_json,
    sheepByID,
    penNameByID,
    sheepIDByEntityID: sheepIndex,
    actorName: "张三",
  });
  assert.equal(event.label, "用途变更");
  assert.equal(event.object, "羊只 A001");
  assert.equal(event.detail, "调整为 繁殖母羊");
  assert.equal(event.note, "选留");
  assert.equal(event.at, "2026-08-30T02:00:00Z");
  assert.ok(event.fields.some((field) => field.label === "原用途" && field.value === "后备母羊"));
});

test("unknown sheep operations use the current ear tag instead of exposing a raw id", () => {
  const event = projectFarmOperationEvent({
    row: operation({ entity_type: "sheep", entity_id: "SHEEP-B" }),
    payload: { strings: { note: "旧版稀疏载荷" } },
    sheepByID,
    penNameByID,
    actorName: "历史迁移",
  });
  assert.equal(event.object, "羊只 B002");
  assert.equal(event.label, "羊只档案同步");
  assert.equal(event.detail.includes("SHEEP-B"), false);
  assert.equal(event.fields.some((field) => field.label === "实体 ID"), false);
});

test("batch operations expose batch names and sheep ear tags instead of entity ids", () => {
  const assigned = projectFarmOperationEvent({
    row: operation({ entity_type: "batchMembership", entity_id: "MEMBER-1" }),
    payload: { kind: "assignBatchMembership", identifiers: { batchID: "BATCH-1", sheepID: "SHEEP-A" }, dates: { joinedAt: "2026-08-31T04:38:00Z" } },
    sheepByID,
    penNameByID,
    batchNameByID,
    membershipByID,
    actorName: "张三",
  });
  assert.equal(assigned.label, "加入生产批次");
  assert.equal(assigned.object, "羊只 A001");
  assert.equal(assigned.detail, "加入 育肥一批");
  assert.equal(JSON.stringify({ label: assigned.label, object: assigned.object, detail: assigned.detail, fields: assigned.fields }).includes("MEMBER-1"), false);

  const restored = projectFarmOperationEvent({
    row: operation({ entity_type: "batchMembership", entity_id: "MEMBER-1" }),
    payload: { kind: "restoreBatchMembership", identifiers: { membershipID: "MEMBER-1" }, strings: { reason: "误操作" }, dates: { restoredAt: "2026-08-31T05:00:00Z" } },
    sheepByID,
    penNameByID,
    batchNameByID,
    membershipByID,
    actorName: "张三",
  });
  assert.equal(restored.label, "恢复生产批次成员");
  assert.equal(restored.object, "羊只 A001");
  assert.equal(restored.detail, "恢复加入 育肥一批 · 误操作");
});

test("bootstrap history unwraps the original batch operation", () => {
  const encode = (value) => Buffer.from(JSON.stringify(value), "utf8").toString("base64");
  const sourcePayload = {
    kind: "createBatch",
    strings: { name: "育肥一批", purpose: "育肥", sheepIDs: "SHEEP-A,SHEEP-B", note: "" },
    dates: { startedAt: "2026-08-01T00:00:00Z" },
  };
  const event = projectFarmOperationEvent({
    row: operation({ entity_type: "productionBatch", entity_id: "BATCH-1" }),
    payload: { kind: "bootstrapEntity", dataValues: { snapshot: encode({ sourcePayload: encode(sourcePayload) }) } },
    sheepByID,
    penNameByID,
    batchNameByID,
    membershipByID,
    actorName: "历史迁移",
  });
  assert.equal(event.label, "生产批次建档");
  assert.equal(event.object, "育肥一批");
  assert.equal(event.detail, "育肥 · 2 只羊");
});

test("generic batch history never exposes English entity names or short ids", () => {
  const event = projectFarmOperationEvent({
    row: operation({ entity_type: "batchMembership", entity_id: "MEMBER-1" }),
    payload: {},
    sheepByID,
    penNameByID,
    batchNameByID,
    membershipByID,
    actorName: "历史迁移",
  });
  assert.equal(event.label, "批次成员历史同步");
  assert.equal(event.object, "羊只 A001");
  assert.equal(event.detail, "生产批次 育肥一批");
  const visible = JSON.stringify({ label: event.label, object: event.object, detail: event.detail, fields: event.fields });
  assert.equal(visible.includes("batchMembership"), false);
  assert.equal(visible.includes("MEMBER-1"), false);
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
