import test from "node:test";
import assert from "node:assert/strict";
import { isReproductionCheckEligible, isPreBreedingLamb } from "../src/lib/reproductionManagement.js";
import { managementProjection } from "../src/lib/managementProjection.js";

const at = value => Date.parse(`${value}T00:00:00+08:00`);
const now = at("2026-10-17");
const eligible = (sheep, records = [], parity = null, date = now) =>
  isReproductionCheckEligible(sheep, records, { completedParity: parity }, { minimumAgeMonths: 10 }, "Asia/Shanghai", date);
const birth = (id, day, parity) => ({ id, kindRawValue: "lambing", occurredAt: at(day), parity });

test("maturity uses a strict calendar-month boundary in farm time", () => {
  const sheep = { birthAt: at("2025-12-17") };
  assert.equal(eligible(sheep), false);
  assert.equal(eligible(sheep, [], null, at("2026-10-18")), true);
  assert.equal(eligible({ birthAt: at("2025-12-16") }), true);
  assert.equal(eligible({ birthAt: now + 86400000 }), false);
  assert.equal(eligible({}), false);
});

test("reliable postpartum evidence qualifies without age; contradictory evidence does not", () => {
  const records = [birth("a", "2026-09-01", 1)];
  assert.equal(eligible({}, records, 1), true);
  assert.equal(eligible({}, records, 0), false);
  assert.equal(eligible({}, records, 2), false);
  assert.equal(eligible({}, [...records, birth("b", "2026-09-01", 1)], 1), false);
  assert.equal(eligible({}, [birth("future", "2026-11-01", 1)], 1), false);
  assert.equal(eligible({}, [{ ...records[0], deletedAt: now }], 1), false);
});

test("management separates scoped ewes from eligible ewes and excludes inactive pens and future entries", async () => {
  const sheep = (id, pen, birthAt, enteredAt = at("2026-01-01")) => ({
    id, farmID: "farm", earTag: id, sexRawValue: "ewe", statusRawValue: "active", currentPenID: pen, birthAt, enteredAt,
  });
  const result = await managementProjection({
    SheepRecord: [sheep("mature", "live", at("2025-01-01")), sheep("young", "live", at("2026-09-01")), sheep("inactive", "closed", at("2025-01-01")), sheep("future", "live", at("2025-01-01"), now + 1)],
    PenRecord: [{ id: "live", isActive: true }, { id: "closed", isActive: false }],
    FarmCareRuleRecord: [{ reproductionSettingsJSON: JSON.stringify({ scopeConfigured: true, selectedPenIDs: ["live", "closed"], minimumAgeMonths: 10 }) }],
  }, { id: "farm", timeZoneIdentifier: "Asia/Shanghai" }, now);
  assert.equal(result.reproductionScopeCount, 2);
  assert.equal(result.reproductionEligibleCount, 1);
  assert.equal(Object.values(result.reproductionSummary).reduce((a, b) => a + b, 0), 1);
});

test("global review retains historical ewe uncertainty without adding it to current analysis", async () => {
  const result = await managementProjection({
    SheepRecord: [{ id: "historical", earTag: "HISTORICAL", sexRawValue: "ewe", statusRawValue: "removed", enteredAt: 1 }],
  }, { id: "farm", timeZoneIdentifier: "Asia/Shanghai" }, now);
  assert.equal(result.reproductionReview.length, 1);
  assert.equal(result.reproductionReview[0].isCurrentlyPresent, false);
  assert.equal(result.reproductionScopeCount, 0);
  assert.equal(result.alerts.filter(a => a.kind === "reproductionReview").length, 1);
});

test("review deferral uses the native fingerprint and persisted update date", async () => {
  const { stableUUID } = await import("../src/lib/nativeEventSnapshots.js");
  const farm = { id: "11111111-1111-4111-8111-111111111111", timeZoneIdentifier: "Asia/Shanghai" };
  const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const models = { SheepRecord: [{ id, earTag: "TEST", sexRawValue: "ewe", statusRawValue: "active", enteredAt: 1 }] };
  const first = await managementProjection(models, farm, now);
  const fingerprint = `reproduction-review:${id.toUpperCase()}:none:缺少可确认的胎次，不能判定为未产羔`;
  const expectedID = await stableUUID(farm.id, `operational-alert:reproductionReview:${id}:none:${fingerprint}`);
  assert.equal(first.alerts[0].id, expectedID);
  models.FarmAlertDeferralRecord = [{ alertID: expectedID, conditionFingerprint: fingerprint, updatedAt: now, deferredUntil: now + 86400000 }];
  assert.equal((await managementProjection(models, farm, now)).alerts.length, 0);
  assert.equal((await managementProjection(models, farm, now + 2 * 86400000)).alerts.length, 1);
});


test("known unbred lambs are excluded from review without inventing parity; historical conflicts remain", async () => {
  const sheep = (id, extra = {}) => ({ id, earTag: id, sexRawValue: "ewe", statusRawValue: "active",
    purpose: "哺乳羔羊", enteredAt: at("2026-09-11"), birthAt: at("2026-09-11"), ...extra });
  const models = {
    SheepRecord: [sheep("lamb"), sheep("deceased", { statusRawValue: "deceased", removedAt: at("2026-09-14") }),
      sheep("has-fact"), sheep("unknown-birth", { birthAt: null }),
      sheep("historical-adult", { statusRawValue: "removed", purpose: "繁殖母羊", birthAt: at("2024-01-01") })],
    ReproductionRecord: [{ id: "check", eweID: "has-fact", kindRawValue: "pregnancyCheck", result: "空怀", occurredAt: at("2026-10-01") }],
  };
  const result = await managementProjection(models, { id: "farm", timeZoneIdentifier: "Asia/Shanghai" }, now);
  assert.deepEqual(result.reproductionReview.map(r => r.earTag).sort(), ["has-fact", "historical-adult", "unknown-birth"]);
  assert.deepEqual(result.alerts.filter(r => r.kind === "reproductionReview").map(r => r.subjectID).sort(), ["has-fact", "historical-adult", "unknown-birth"]);
  assert.deepEqual(result.reproductionPreBreedingLambIDs.sort(), ["deceased", "lamb"]);
  assert.equal(result.reproductionStates.lamb.completedParity, null);
  assert.equal(result.reproductionStates.lamb.targetParity, null);
  assert.equal(isPreBreedingLamb(models.SheepRecord[1], [], {}, "Asia/Shanghai", at("2030-10-17")), true);
  assert.equal(isPreBreedingLamb(sheep("old", { birthAt: at("2025-01-01") }), [], {}, "Asia/Shanghai", now), false);
  assert.equal(isPreBreedingLamb(sheep("future", { birthAt: at("2026-11-01") }), [], {}, "Asia/Shanghai", now), false);
  const boundary = sheep("boundary", { birthAt: at("2025-12-17") });
  assert.equal(isPreBreedingLamb(boundary, [], {}, "Asia/Shanghai", now), true);
  assert.equal(isPreBreedingLamb(boundary, [], {}, "Asia/Shanghai", at("2026-10-18")), false);
  assert.equal(isPreBreedingLamb(models.SheepRecord[0], [{ occurredAt: now + 1 }], {}, "Asia/Shanghai", now), true);
  assert.equal(isPreBreedingLamb(models.SheepRecord[0], [{ occurredAt: now - 1, deletedAt: now }], {}, "Asia/Shanghai", now), true);
});
