import test from "node:test";
import assert from "node:assert/strict";
import { workflowFixture } from "./helpers/workflowFixture.mjs";
import { buildBusinessCommands } from "../src/lib/businessCommands.js";
import { applyV2Event, finishV2Projection } from "../src/lib/cloudV2Projection.js";
import { penCommandSpec, penNameKey, validatePenName, resolvePen, penHasReferences, penDeletionBlock, penStatus, penMatchesScope, penPermissions } from "../src/lib/penManagement.js";

function fixture(role = "owner") {
  const source = workflowFixture();
  const workspace = source.workspace(); workspace.farm.role = role;
  const pen = workspace.models.PenRecord[1];
  return { ...source, workspace, pen, draft: { penID: pen.id, name: pen.name, note: pen.note,
    expected: { name: pen.name, note: pen.note, isActive: pen.isActive } } };
}
test("names match App trim and case rules, keep fullwidth distinct, reserve inactive names, and permit legacy note edits", () => {
  const pens = [{ id: "a", name: " A舍 ", isActive: false }, { id: "b", name: "a舍" }, { id: "c", name: "已删除", deletedAt: 1 }];
  assert.equal(penNameKey(" \nA舍\t"), "a舍"); assert.notEqual(penNameKey("Ａ舍"), penNameKey("A舍"));
  assert.throws(() => validatePenName(" \n ", pens), /不能为空/);
  assert.throws(() => validatePenName("a舍", pens), /已停用/);
  assert.doesNotThrow(() => validatePenName("a舍", pens, "a"));
  assert.doesNotThrow(() => validatePenName("已删除", pens));
  assert.throws(() => resolvePen("a舍", pens), /多个羊舍/);
  assert.throws(() => resolvePen("a舍", pens.slice(0, 1)), /已停用/);
});
test("empty, occupied and inactive scopes are independent of lifecycle", () => {
  const empty = { isActive: true, headCount: 0 }, inactive = { isActive: false, headCount: 0 };
  assert.equal(penStatus(empty), "启用 · 空舍"); assert.equal(penStatus(inactive), "已停用 · 空舍");
  assert(penMatchesScope(empty, "empty")); assert(!penMatchesScope(inactive, "empty"));
  assert(penMatchesScope({ ...inactive, headCount: 2 }, "occupied")); assert(penMatchesScope(inactive, "inactive"));
  assert(!penMatchesScope({ isActive: true, headCount: null }, "empty"));
});
test("workers may create and edit but cannot manage lifecycle even with a capability override", async () => {
  const { workspace, draft } = fixture("worker"); workspace.capabilities = ["manageCatalogs"];
  assert.deepEqual(penPermissions(workspace), { ready: true, edit: true, lifecycle: false });
  assert.equal((await penCommandSpec("update", { ...draft, note: "用途" }, workspace)).kind, "pen.update");
  await assert.rejects(() => penCommandSpec("setActive", { ...draft, isActive: false }, workspace), /牧场主或管理员/);
  await assert.rejects(() => penCommandSpec("delete", { ...draft, reason: "测试" }, workspace), /牧场主或管理员/);
  workspace.farm.role = "viewer";
  await assert.rejects(() => penCommandSpec("create", { penID: crypto.randomUUID(), name: "新舍" }, workspace), /权限/);
});
test("pen commands preserve typed changes, field observations, stable IDs and stale edit protection", async () => {
  const { workspace, draft } = fixture();
  workspace.models.ESheepCloudStreamState.push({ streamType: "pen", streamID: draft.penID, fieldVersionsData: { json: [{ field: "name", version: 3, valueDigest: "a".repeat(64) }] } });
  const spec = await penCommandSpec("update", { ...draft, name: " 新名称 ", note: " 用途 " }, workspace);
  assert.deepEqual(spec.body, { update: { penID: draft.penID, name: "新名称", note: "用途" } });
  assert.equal(spec.fields[0].observedVersion, 3); assert.equal(spec.fields[0].baseValueDigest, "a".repeat(64));
  assert.equal(spec.changes[0].mutation.value.type, "string");
  assert.equal((await penCommandSpec("setActive", { ...draft, isActive: false }, workspace)).changes[0].mutation.value.type, "boolean");
  const spec2 = (await buildBusinessCommands({ penAction: "update", penDraft: draft }, workspace))[0];
  assert.equal(spec2.streams[0].id, draft.penID);
  workspace.models.PenRecord[1].note = "另一位成员已修改";
  await assert.rejects(() => penCommandSpec("update", draft, workspace), /其他成员/);
});
test("occupied pens cannot be disabled and historical deleted references cannot be erased", async () => {
  const { workspace, pen, draft } = fixture();
  const occupied = workspace.models.PenRecord[0];
  await assert.rejects(() => penCommandSpec("setActive", { penID: occupied.id, isActive: false, expected: occupied }, workspace), /仍有羊只/);
  assert.equal(penDeletionBlock(workspace, pen), "");
  for (const [model, row] of [
    ["SheepRecord", { initialPenID: pen.id, statusRawValue: "removed" }],
    ["TransferRecord", { fromPenID: pen.id }], ["FeedRecipeRecord", { targetPenID: pen.id }],
    ["TMRFeedingPlanPenRecord", { penID: pen.id }], ["NoteRecord", { penID: pen.id }],
    ["DailyPenCountRecord", { penID: pen.id, count: 2 }],
  ]) {
    const copy = structuredClone(workspace.models);
    (copy[model] ??= []).push({ farmID: workspace.farm.id, deletedAt: 1, ...row });
    assert(penHasReferences(copy, pen.id, workspace.farm.id), model);
  }
  workspace.models.NoteRecord.push({ farmID: workspace.farm.id, penID: pen.id, deletedAt: 1 });
  await assert.rejects(() => penCommandSpec("delete", { ...draft, reason: "不用了" }, workspace), /历史记录/);
});
test("historical envelope references are decoded and free text UUIDs or zero head counts do not block deletion", () => {
  const { workspace, pen } = fixture();
  const operation = { entityType: "feed", farmID: workspace.farm.id, payload: { base64: Buffer.from(JSON.stringify({ field: "targetPenID", mutation: { value: { type: "identifier", value: pen.id } } })).toString("base64") } };
  workspace.models.DomainOperation.push(operation);
  assert(penHasReferences(workspace.models, pen.id, workspace.farm.id));
  operation.payload = { json: { note: pen.id } };
  workspace.models.DailyPenCountRecord.push({ farmID: workspace.farm.id, penID: pen.id, count: 0 });
  assert(!penHasReferences(workspace.models, pen.id, workspace.farm.id));
});
test("create and safe delete use audited commands, require a reason and preserve unrelated records on replay and restore", async () => {
  const { workspace, projection, pen, draft } = fixture();
  const originalSheep = structuredClone(workspace.models.SheepRecord);
  const newID = crypto.randomUUID();
  const create = await penCommandSpec("create", { penID: newID, name: " 空舍 ", note: "用途" }, workspace);
  assert.equal(create.streams[0].id, newID); assert.equal(create.body.create.name, "空舍");
  await assert.rejects(() => penCommandSpec("delete", { ...draft, reason: " " }, workspace), /删除原因/);
  const spec = await penCommandSpec("delete", { ...draft, reason: "建立错误" }, workspace);
  assert.equal(spec.kind, "record.revoke"); assert.equal(spec.fields[0].field, "lifecycle");
  const commandID = crypto.randomUUID();
  const event = { event_id: crypto.randomUUID(), command_id: commandID, event_sequence: 1, event_kind: "lifecycle", stream_type: "pen", stream_id: pen.id, source_command_digest: "a".repeat(64), occurred_at_millis: Date.now(), received_at_millis: Date.now() };
  applyV2Event(projection, event, { command_kind: spec.kind, command_payload: { kind: spec.kind, body: spec.body }, affected_streams: spec.streams });
  let result = finishV2Projection(projection);
  assert(!result.rowsByType.get("pen").some(p => p.entity_id === pen.id));
  assert(result.models.PenRecord.find(p => p.id === pen.id).deletedAt);
  assert.equal(result.models.TombstoneRecord[0].reason, "建立错误");
  assert.deepEqual(result.models.SheepRecord, originalSheep);
  applyV2Event(projection, { ...event, command_id: crypto.randomUUID(), event_id: crypto.randomUUID(), event_sequence: 2 }, {
    command_kind: "record.restore", command_payload: { kind: "record.restore", body: { restore: { tombstoneID: commandID } } }, affected_streams: spec.streams });
  result = finishV2Projection(projection);
  assert(result.rowsByType.get("pen").some(p => p.entity_id === pen.id));
  assert(result.models.TombstoneRecord[0].restoredAt);
});
test("the canonical Excel create entry applies the same names and inactive pen resolution", async () => {
  const { workspace } = fixture(); workspace.models.PenRecord[0].isActive = false;
  await assert.rejects(() => buildBusinessCommands({ sheet: "圈舍", values: { 圈舍名称: ` ${workspace.models.PenRecord[0].name} ` } }, workspace), /已停用/);
  await assert.rejects(() => buildBusinessCommands({ sheet: "新建羊只", values: { 耳号: "TEST1", 品种: "湖羊", 性别: "母羊", 入场日期: "2026-10-01", 圈舍: workspace.models.PenRecord[0].name } }, workspace), /已停用/);
});
