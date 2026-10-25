import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveReproductionState, entryAssociation } from "../src/lib/reproductionCycles.js";
const fixtures = JSON.parse(readFileSync(new URL("../../eSheepNextTests/Fixtures/reproduction-cycle-cases.json", import.meta.url)));
for (const fixture of fixtures) test(`shared cycle contract: ${fixture.name}`, () => {
  for (const records of [fixture.records, [...fixture.records].reverse()]) {
    const state = resolveReproductionState(fixture.eweID, records, fixture.asOf);
    assert.equal(state.pregnancy, fixture.expectedState);
    assert.equal(state.completedParity, fixture.expectedParity);
    assert.equal(state.breedingRoundID, fixture.expectedRoundID);
    assert.equal(state.cycleID, fixture.expectedCycleID);
  }
});
test("entry refuses stale cycle and invalid supplement", () => {
  const fixture = fixtures[1];
  assert.throws(() => entryAssociation({ eweID:fixture.eweID,recordID:"new",kind:"breeding",occurredAt:fixture.asOf,records:fixture.records,intent:"supplement" }), /必须选择/);
  assert.throws(() => entryAssociation({ eweID:fixture.eweID,recordID:"new",kind:"pregnancyCheck",occurredAt:fixture.asOf,records:fixture.records,expectedCycleID:fixture.eweID }), /周期已变更/);
});
