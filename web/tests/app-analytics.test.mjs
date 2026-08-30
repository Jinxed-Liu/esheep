import assert from "node:assert/strict";
import test from "node:test";
import {
  calculateFeedIntakeAnalytics,
  calculateLambAnalytics,
  calculateReproductionAnalytics,
  calculateWeightAnalytics,
  dailyCanonicalWeightSamples,
  feedFilterOptions,
} from "../src/lib/appAnalytics.js";

const penA = "00000000-0000-0000-0000-0000000000a1";
const penB = "00000000-0000-0000-0000-0000000000b1";
const cornID = "10000000-0000-0000-0000-000000000001";
const mealID = "10000000-0000-0000-0000-000000000002";

function sheep(id, overrides = {}) {
  return {
    id,
    earTag: id,
    sex: "ram",
    purpose: "育肥羊",
    breed: "杜泊",
    status: "active",
    initialPenID: penA,
    enteredAt: "2026-08-01T00:00:00Z",
    removedAt: null,
    ...overrides,
  };
}

function nutrientLine(ingredientID, ingredientName, freshKilograms, nutrients = {}) {
  return {
    ingredientID,
    ingredientName,
    freshKilograms,
    nutrients: {
      dryMatter: 88,
      crudeProtein: 12,
      ndf: 30,
      adf: 15,
      me: 3,
      rdp: 7,
      rup: 5,
      adip: 0.5,
      ...nutrients,
    },
  };
}

function cornComposition(kilograms) {
  return kilograms > 0 ? [{
    ingredientID: cornID,
    ingredientNameSnapshot: "玉米",
    freshKilograms: kilograms,
    nutrients: { dryMatter: 88, crudeProtein: 12, ndf: 30, adf: 15, me: 3, rdp: 7, rup: 5, adip: 0.5 },
  }] : [];
}

test("daily canonical weights use App priority, latest same-source sample, and farm calendar day", () => {
  const source = {
    sheep: [sheep("a")],
    weights: [
      { id: "w-early", sheepID: "a", kilograms: 10, at: "2026-01-01T16:30:00Z" },
      { id: "w-late", sheepID: "a", kilograms: 11, at: "2026-01-02T15:00:00Z" },
      { id: "w-next", sheepID: "a", kilograms: 13, at: "2026-01-02T16:30:00Z" },
    ],
    weanings: [{ id: "wean", sheepID: "a", weanWeight: 20, at: "2026-01-02T10:00:00Z" }],
  };

  const samples = dailyCanonicalWeightSamples(source, "Asia/Shanghai");
  assert.deepEqual(samples.map((item) => [item.day, item.kilograms, item.source]), [
    ["2026-01-02", 11, "weighing"],
    ["2026-01-03", 13, "weighing"],
  ]);

  const result = calculateWeightAnalytics(source, { cutoff: "2026-01-03T12:00:00Z", timeZone: "Asia/Shanghai" });
  assert.equal(result.canonicalSampleCount, 2);
  assert.equal(result.latestAverageADG, 2);
});

test("weight cutoff and production-batch membership match App event-time slicing", () => {
  const source = {
    sheep: [sheep("a")],
    weights: [
      { id: "w1", sheepID: "a", kilograms: 10, at: "2026-08-02T08:00:00Z" },
      { id: "w2", sheepID: "a", kilograms: 20, at: "2026-08-10T08:00:00Z" },
    ],
    batches: [{ id: "batch", name: "手工育肥批次", source: "manual" }],
    batchMemberships: [{ id: "member", batchID: "batch", sheepID: "a", joinedAt: "2026-08-05T00:00:00Z", leftAt: null }],
  };

  const result = calculateWeightAnalytics(source, { batchID: "batch", cutoff: "2026-08-10T08:00:00Z", timeZone: "UTC" });
  assert.equal(result.sheepIDs.length, 1);
  assert.equal(result.canonicalSampleCount, 1);
  assert.equal(result.latestAverageWeight, 20);
  assert.equal(result.latestAverageADG, null);
});

test("weaning analytics use earliest ordinary post-birth weight and weighted sample averages", () => {
  const source = {
    sheep: [
      sheep("lamb-1", { birthAt: "2026-01-01T00:00:00Z", sex: "ram" }),
      sheep("lamb-2", { birthAt: "2026-01-01T00:00:00Z", sex: "ewe" }),
      sheep("lamb-3", { birthAt: "2026-02-01T00:00:00Z", sex: "ewe" }),
      sheep("ewe", { sex: "ewe", purpose: "繁殖母羊" }),
    ],
    weights: [
      { id: "baseline", sheepID: "lamb-1", kilograms: 5, at: "2026-01-02T00:00:00Z" },
      { id: "later", sheepID: "lamb-1", kilograms: 7, at: "2026-01-10T00:00:00Z" },
    ],
    weanings: [
      { id: "wean-1", sheepID: "lamb-1", birthAt: "2026-01-01T00:00:00Z", weanWeight: 15, at: "2026-01-20T00:00:00Z" },
      { id: "wean-2", sheepID: "lamb-2", birthAt: "2026-01-01T00:00:00Z", weanWeight: 20, at: "2026-01-20T00:00:00Z" },
      { id: "wean-3", sheepID: "lamb-3", birthAt: "2026-02-01T00:00:00Z", weanWeight: 40, at: "2026-02-20T00:00:00Z" },
    ],
    reproduction: [{
      id: "birth", eweID: "ewe", kind: "lambing", parity: 2, birthDeadCount: 0, lambCount: 1,
      at: "2026-01-01T00:00:00Z", offspring: [{ id: "child", sheepID: "lamb-1", sex: "ram", birthWeight: 4, isStillborn: false }],
    }],
  };

  const result = calculateLambAnalytics(source, { timeZone: "UTC" });
  assert.equal(result.weaningWeightSampleCount, 3);
  assert.ok(Math.abs(result.averageWeaningWeightKg - 25) < 1e-10);
  assert.equal(result.weaningADGSampleCount, 1);
  assert.ok(Math.abs(result.weaning.averageADG - (10 / 18 * 1_000)) < 1e-10);
  assert.equal(result.weaning.abnormalCount, 2);
});

test("reproduction fixes the ewe cohort at the inclusive end date and keeps prior lambings as interval evidence", () => {
  const source = {
    pens: [{ id: penA, name: "一圈" }, { id: penB, name: "二圈" }],
    sheep: [
      sheep("ewe-1", { sex: "ewe", purpose: "繁殖母羊", enteredAt: "2024-01-01T00:00:00Z", initialPenID: penA }),
      sheep("ewe-2", { sex: "ewe", purpose: "繁殖母羊", enteredAt: "2024-01-01T00:00:00Z", initialPenID: penA }),
      sheep("ewe-removed", { sex: "ewe", purpose: "繁殖母羊", enteredAt: "2024-01-01T00:00:00Z", initialPenID: penB, removedAt: "2026-08-01T00:00:00Z" }),
    ],
    transfers: [{ id: "transfer", sheepID: "ewe-1", fromPenID: penA, toPenID: penB, at: "2026-07-01T00:00:00Z", recordedAt: "2026-07-01T00:00:00Z" }],
    reproduction: [
      { id: "prior", eweID: "ewe-1", kind: "lambing", at: "2025-12-01T00:00:00Z", parity: 1, birthDeadCount: 0, lambCount: 1, offspring: [{ id: "p", sex: "ram" }] },
      { id: "current", eweID: "ewe-1", kind: "lambing", at: "2026-05-30T00:00:00Z", parity: 2, birthDeadCount: 0, lambCount: 1, offspring: [{ id: "c", sex: "ewe", birthWeight: 4 }] },
      { id: "other", eweID: "ewe-2", kind: "lambing", at: "2026-06-01T00:00:00Z", parity: 2, birthDeadCount: 0, lambCount: 1, offspring: [{ id: "o", sex: "ram" }] },
    ],
  };
  const result = calculateReproductionAnalytics(source, {
    filter: { startDate: "2026-01-01", endDate: "2026-08-20", penScope: "pen", penID: penB, breed: null },
    now: new Date("2026-08-20T12:00:00Z"),
    timeZone: "UTC",
  });

  assert.equal(result.cohortCount, 1);
  assert.equal(result.completeLambingCount, 1);
  assert.equal(result.overview.averageTotal, 1);
  assert.equal(result.intervalPoints.at(-1).average, 180);
  assert.equal(result.postpartumPoints.at(-1).average, 82);
  assert.equal(result.qualifiedRates.at(-1).qualified, 100);
});

test("limited meals merge and subtract one measured mixture remainder by ratio", () => {
  const source = {
    pens: [{ id: penA, name: "一圈" }],
    sheep: [sheep("a", { enteredAt: "2026-08-01T00:00:00Z" })],
    feeds: [
      { id: "first", penID: penA, mode: "limited", at: "2026-08-02T08:00:00Z", feederName: "一号槽", lines: [nutrientLine(cornID, "玉米", 8), nutrientLine(mealID, "豆粕", 2)] },
      { id: "second", penID: penA, mode: "limited", at: "2026-08-02T17:00:00Z", feederName: "一号槽", lines: [nutrientLine(cornID, "玉米", 4), nutrientLine(mealID, "豆粕", 1)] },
    ],
    troughObservations: [{ id: "remaining", penID: penA, relatedFeedRecordID: "first", feederName: "一号槽", observedAt: "2026-08-02T20:00:00Z", actualRemainingKilograms: 3, discardedKilograms: 1, measurementMethod: "weighed", composition: [] }],
  };
  const result = calculateFeedIntakeAnalytics(source, { startDate: "2026-08-02", endDateExclusive: "2026-08-03", now: new Date("2026-08-04T00:00:00Z"), timeZone: "UTC" });
  const pen = result.pens[0];
  assert.ok(Math.abs(pen.freshKilograms - 12) < 1e-10);
  assert.ok(Math.abs(pen.ingredients.find((item) => item.ingredientID === cornID).freshKilograms - 9.6) < 1e-10);
  assert.ok(Math.abs(pen.ingredients.find((item) => item.ingredientID === mealID).freshKilograms - 2.4) < 1e-10);
  assert.equal(pen.evidence.has("measured"), true);
  assert.equal(pen.evidence.has("estimated"), false);
});

test("free-choice tanks share one sheep-day interval and require two trough boundaries", () => {
  const feed = (id, tank, at, kilograms) => ({ id, penID: penA, mode: "freeChoice", at, feederName: tank, lines: [nutrientLine(cornID, "玉米", kilograms)] });
  const trough = (id, tank, at, remaining) => ({ id, penID: penA, feederName: tank, observedAt: at, actualRemainingKilograms: remaining, discardedKilograms: 0, measurementMethod: "weighed", composition: cornComposition(remaining) });
  const source = {
    pens: [{ id: penA, name: "一圈" }],
    sheep: [sheep("a", { enteredAt: "2026-08-01T00:00:00Z" })],
    feeds: [
      feed("a-1", "A罐", "2026-08-02T06:00:00Z", 10),
      feed("a-2", "A罐", "2026-08-02T12:00:00Z", 2),
      feed("b-1", "B罐", "2026-08-02T10:00:00Z", 6),
    ],
    troughObservations: [
      trough("ta-1", "A罐", "2026-08-02T00:00:00Z", 5),
      trough("ta-2", "A罐", "2026-08-03T00:00:00Z", 4),
      trough("tb-1", "B罐", "2026-08-02T00:00:00Z", 0),
      trough("tb-2", "B罐", "2026-08-03T00:00:00Z", 1),
    ],
  };
  const result = calculateFeedIntakeAnalytics(source, { startDate: "2026-08-02", endDateExclusive: "2026-08-03", now: new Date("2026-08-04T00:00:00Z"), timeZone: "UTC" });
  const pen = result.pens[0];
  assert.equal(pen.freshKilograms, 18);
  assert.equal(pen.sheepDays, 1);
  assert.equal(pen.completeIntervalCount, 2);
  assert.equal(pen.incompleteIntervalCount, 0);
});

test("feed pen options use App occupancy segments and authoritative daily count change points", () => {
  const penC = "00000000-0000-0000-0000-0000000000c1";
  const penD = "00000000-0000-0000-0000-0000000000d1";
  const source = {
    pens: [
      { id: penA, name: "一圈" },
      { id: penB, name: "二圈" },
      { id: penC, name: "三圈" },
      { id: penD, name: "四圈" },
    ],
    sheep: [
      sheep("moving", { enteredAt: "2026-08-01T00:00:00Z", initialPenID: penA }),
      sheep("unprovable", { status: "removed", enteredAt: "2026-08-01T00:00:00Z", initialPenID: penD }),
    ],
    transfers: [{ id: "move", sheepID: "moving", toPenID: penB, at: "2026-08-02T12:00:00Z", recordedAt: "2026-08-02T12:01:00Z" }],
    dailyPenCounts: [{ id: "count", penID: penC, purpose: "育肥", date: "2026-08-01T23:00:00Z", count: 4, rebuiltAt: "2026-08-02T00:00:00Z" }],
  };
  const pens = feedFilterOptions(source, { startDate: "2026-08-02", endDateExclusive: "2026-08-04", timeZone: "UTC" });
  assert.deepEqual(pens.map((pen) => pen.id), [penA, penB, penC]);
});

test("nutrition uses fresh-to-dry-matter conversion and never fills missing CP", () => {
  const source = {
    pens: [{ id: penA, name: "一圈" }],
    sheep: [sheep("a", { enteredAt: "2026-08-01T00:00:00Z" })],
    feeds: [{
      id: "feed", penID: penA, mode: "limited", at: "2026-08-02T08:00:00Z",
      lines: [
        nutrientLine(cornID, "有 CP", 5, { dryMatter: 100, crudeProtein: 15, me: 3 }),
        nutrientLine(mealID, "缺 CP", 5, { dryMatter: 100, crudeProtein: null, me: 3 }),
      ],
    }],
  };
  const result = calculateFeedIntakeAnalytics(source, { startDate: "2026-08-02", endDateExclusive: "2026-08-03", now: new Date("2026-08-04T00:00:00Z"), timeZone: "UTC" });
  const nutrition = result.pens[0].nutrition;
  assert.equal(nutrition.summary.dryMatterKilograms, 10);
  assert.equal(nutrition.crudeProteinGramsPerSheepDay, null);
  assert.equal(nutrition.metabolizableProteinGramsPerSheepDay, null);
  assert.deepEqual(nutrition.summary.coverage.crudeProtein.missingIngredientNames, ["缺 CP"]);
});
