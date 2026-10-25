import assert from "node:assert/strict";
import test from "node:test";
import { workflowFixture } from "./helpers/workflowFixture.mjs";
import { applyExtendedV2Event } from "../src/lib/cloudV2BusinessReplay.js";
import { decodeCheckpointValues } from "../src/lib/cloudV2Projection.js";

function draft(fixture, ruleID) {
  const pen = fixture.workspace().models.PenRecord[0];
  const ewe = fixture.workspace().models.SheepRecord.find((row) => row.sexRawValue === "ewe");
  return { id: ruleID, pregnancyCheckDays: 45, gestationDays: 150, weaningAgeDays: 60,
    warningLeadDays: 0, digestEnabled: false, digestMinuteOfDay: 480, updatesReproductionOnly: true,
    reproductionSettings: { minimumAgeMonths: 10, penUsages: { [pen.id]: "繁殖母羊" }, scopeConfigured: true,
      selectedPenIDs: [pen.id], youthBreedingConfirmedSheepIDs: [ewe.id],
      postpartumReminderDays: 90, postpartumWarningDays: 120, maidenReminderMonths: 10, maidenWarningMonths: 12 } };
}

async function replay(fixture, args) {
  const kind = "care.operationalAlertRules.update";
  return applyExtendedV2Event(fixture.projection, {
    event_kind: "state_machine", command_id: crypto.randomUUID(), event_id: crypto.randomUUID(),
    source_command_digest: "a".repeat(64), actor_account_id: crypto.randomUUID(),
    received_at_millis: Date.UTC(2026, 9, 16), occurred_at_millis: Date.UTC(2026, 9, 16),
  }, { command_kind: kind, command_payload: { kind, body: { updateOperationalAlertRules: { _0: args } } },
    affected_streams: [{ type: "careRule", id: args.id }] });
}

test("native reproduction-only settings replay preserves disabled legacy rules and UUID JSON encoding", async () => {
  const fixture = workflowFixture(), ruleID = crypto.randomUUID(), args = draft(fixture, ruleID);
  await replay(fixture, args);
  const rule = fixture.projection.models.get("FarmCareRuleRecord").get(ruleID);
  assert.equal(rule.operationalAlertsConfiguredAt, null);
  assert.equal(rule.weaningAgeDays, null);
  assert.equal(rule.pregnancyCheckDays, 45);
  assert.equal(rule.alertDigestEnabled, false);
  assert.equal(rule.alertDigestMinuteOfDay, 480);
  const settings = JSON.parse(rule.reproductionSettingsJSON);
  assert.equal(settings.scopeConfigured, true);
  assert.deepEqual(settings.selectedPenIDs, args.reproductionSettings.selectedPenIDs.map((id) => id.toUpperCase()));
  assert.deepEqual(settings.youthBreedingConfirmedSheepIDs, args.reproductionSettings.youthBreedingConfirmedSheepIDs.map((id) => id.toUpperCase()));
  assert.deepEqual(settings.penUsages, args.reproductionSettings.penUsages);
});

test("legacy rule edits keep reproduction scope and manual readiness; reproduction edits preserve legacy thresholds", async () => {
  const fixture = workflowFixture(), ruleID = crypto.randomUUID(), args = draft(fixture, ruleID);
  await replay(fixture, args);
  const originalJSON = fixture.projection.models.get("FarmCareRuleRecord").get(ruleID).reproductionSettingsJSON;
  await replay(fixture, { id: ruleID, pregnancyCheckDays: 42, gestationDays: 151, weaningAgeDays: 65,
    warningLeadDays: 5, digestEnabled: true, digestMinuteOfDay: 510 });
  const afterLegacy = fixture.projection.models.get("FarmCareRuleRecord").get(ruleID);
  assert.equal(afterLegacy.reproductionSettingsJSON, originalJSON);
  assert.equal(afterLegacy.weaningAgeDays, 65);
  assert.equal(afterLegacy.alertDigestEnabled, true);
  assert.notEqual(afterLegacy.operationalAlertsConfiguredAt, null);
  args.reproductionSettings.minimumAgeMonths = 9;
  await replay(fixture, args);
  const afterReproduction = fixture.projection.models.get("FarmCareRuleRecord").get(ruleID);
  assert.equal(afterReproduction.pregnancyCheckDays, 42);
  assert.equal(afterReproduction.weaningAgeDays, 65);
  assert.equal(afterReproduction.alertDigestMinuteOfDay, 510);
  assert.equal(JSON.parse(afterReproduction.reproductionSettingsJSON).minimumAgeMonths, 9);
});

test("fieldless legacy care checkpoints and new reproduction documents are both readable", () => {
  const farmID = crypto.randomUUID();
  const values = { id: crypto.randomUUID(), farmID, pregnancyCheckDays: 45, gestationDays: 150,
    warningLeadDays: 0, alertDigestEnabled: false, alertDigestMinuteOfDay: 480,
    createdAt: 0, updatedAt: 0, revision: 1 };
  assert.equal(decodeCheckpointValues("FarmCareRuleRecord", values).reproductionSettingsJSON, undefined);
  const json = '{"minimumAgeMonths":10,"scopeConfigured":false}';
  assert.equal(decodeCheckpointValues("FarmCareRuleRecord", { ...values, reproductionSettingsJSON: json }).reproductionSettingsJSON, json);
  assert.throws(() => decodeCheckpointValues("FarmCareRuleRecord", { ...values, unknownBusinessField: "x" }));
});
