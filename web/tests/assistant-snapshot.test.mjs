import assert from "node:assert/strict";
import test from "node:test";
import { ASSISTANT_SNAPSHOT_SCHEMA, buildAssistantSnapshot } from "../src/lib/assistantSnapshot.js";

test("builds a JSON-safe cloud snapshot without account or owner secrets", () => {
  const workspace = {
    mode: "cloud",
    farm: {
      id: "farm-1",
      name: "测试牧场",
      role: "owner",
      roleName: "所有者",
      ownerUserID: "must-not-leak",
      timeZoneIdentifier: "Asia/Shanghai",
      revision: 42,
    },
    profile: { accountID: "account-1", email: "private@example.com" },
    metrics: { activeSheep: 1, activePens: 1, feedsToday: 0 },
    projectionCoverage: { real: ["sheep"], incompleteSheep: 0 },
    sheep: [{ id: "sheep-1", earTag: "A001", penID: "pen-1", status: "active" }],
    pens: [{ id: "pen-1", name: "一号圈", headCount: 1 }],
    events: [{ id: "event-1", at: "2026-08-30T00:00:00Z", type: "weight" }],
    analyticsSource: { sheep: [], pens: [], weights: [], weanings: [], reproduction: [], removals: [], transfers: [], batches: [], batchMemberships: [], feeds: [], troughObservations: [], dailyPenCounts: [] },
    lastSyncedAt: "2026-08-31T00:00:00Z",
  };

  const snapshot = buildAssistantSnapshot(workspace);
  const serialized = JSON.stringify(snapshot);
  assert.equal(snapshot.schemaVersion, ASSISTANT_SNAPSHOT_SCHEMA);
  assert.equal(snapshot.farm.id, "farm-1");
  assert.equal(snapshot.activeSheep[0].earTag, "A001");
  assert.equal(serialized.includes("private@example.com"), false);
  assert.equal(serialized.includes("must-not-leak"), false);
  assert.equal(serialized.includes("account-1"), false);
});

test("refuses to build farm evidence without an authorized cloud workspace", () => {
  assert.throws(() => buildAssistantSnapshot({ mode: "unauthenticated", farm: null }), /已登录用户有权访问/);
});
