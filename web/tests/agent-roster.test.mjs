import test from "node:test";
import assert from "node:assert/strict";
import { dailyRosterEvidence, rosterFilters } from "../server/agent-roster.mjs";
import { runFarmAgent } from "../server/agent-runtime.mjs";

const farm = { id: "farm" };
const boundary = { day: "2026-09-30", zone: "Asia/Shanghai", head: 15 };
const sheep = [
  { id: "in", statusRawValue: "active", enteredAt: null, currentPenID: "pen", sexRawValue: "ewe" },
  { id: "out", statusRawValue: "removed", currentPenID: "pen" },
  { id: "unassigned", statusRawValue: "active", currentPenID: null },
  { id: "archive", statusRawValue: "active", isHistoricalArchive: true },
  { id: "deleted", statusRawValue: "active", deletedAt: 1 },
];
const projection = { revision: 15, models: { FarmRecord: [{ id: "farm", timeZoneIdentifier: "Asia/Shanghai" }],
  SheepRecord: sheep, PenRecord: [{ id: "pen", name: "三舍" }] } };

test("roster counts the same live profiles as home, including unknown entry dates and unassigned sheep", () => {
  assert.equal(dailyRosterEvidence(projection, farm, boundary, rosterFilters({})).count, 2);
  assert.equal(dailyRosterEvidence(projection, farm, boundary, rosterFilters({ penName: "三舍", sex: "ewe" })).count, 1);
  assert.equal(dailyRosterEvidence(projection, farm, boundary, rosterFilters({ penName: "不存在" })).count, null);
  assert.throws(() => dailyRosterEvidence(projection, farm, { ...boundary, head: 16 }, rosterFilters({})));
  assert.throws(() => rosterFilters({day: "2026-02-30"}));
  assert.throws(() => rosterFilters({purpose:"羔羊"}));
});

for (const provider of ["openai", "mimo"]) {
  test(provider + " answers from a single daily roster read without a second model turn", async () => {
    let models = 0, reads = 0;
    const args = { day: "2026-10-01", opening: true };
    const result = await runFarmAgent({ provider, input: [{ role: "user", content: "十月期初在群多少只？" }],
      emit() {}, loadSnapshot: () => assert.fail("unrelated snapshot requested"),
      modelTurn: async ({ tools }) => {
        assert.ok(tools.some(t => t.name === "read_daily_herd_roster")); assert.equal(++models, 1);
        return { output: [{ type: "function_call", call_id: "r", name: "read_daily_herd_roster", arguments: JSON.stringify(args) }], usage: {output_tokens: 12} };
      },
      loadRoster: async filters => { reads++; assert.deepEqual(filters, rosterFilters(args));
        return dailyRosterEvidence(projection, farm, { ...boundary, day: args.day }, filters); },
    });
    assert.equal(reads, 1); assert.match(result.text, /2026-10-01 期初在群名册共 2 只/);
  });
}
test("no roster and a known empty roster produce different answers", () => {
  const filters = rosterFilters({});
  assert.equal(dailyRosterEvidence(null, farm, { day:"2020-01-01", unavailable:"no_roster" }, filters).count, null);
  assert.equal(dailyRosterEvidence({ ...projection, models: { ...projection.models, SheepRecord: [] } }, farm, boundary, filters).count, 0);
});
