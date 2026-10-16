import { decodeCheckpointData } from "./checkpointData.js";

const sameID = (a, b) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };
// Match PenManagementPolicy and the cloud name key: trim + lowercase, without
// compatibility normalization that could merge distinct existing farm names.
export const penName = (value) => String(value ?? "").trim();
export const penNameKey = (value) => penName(value).toLowerCase();
export const penScopes = [
  { id: "all", label: "全部羊舍" }, { id: "occupied", label: "有羊羊舍" },
  { id: "empty", label: "启用空舍" }, { id: "inactive", label: "已停用" },
];
export function penMatchesScope(pen, scope) {
  return scope === "occupied" ? pen.headCount > 0 : scope === "empty" ? pen.isActive && pen.headCount === 0
    : scope === "inactive" ? !pen.isActive : true;
}
export function penStatus(pen) {
  return `${pen.isActive ? "启用" : "已停用"} · ${pen.headCount == null ? "存栏待确认" : pen.headCount > 0 ? `${pen.headCount} 只` : "空舍"}`;
}
export function penPermissions(workspace) {
  const role = workspace.farm?.role ?? workspace.farm?.memberRole ?? workspace.profile?.role;
  const ready = Boolean(workspace.models?.PenRecord && workspace.models?.SheepRecord);
  return { ready, edit: ready && ["owner", "administrator", "worker"].includes(role),
    lifecycle: ready && ["owner", "administrator"].includes(role) };
}
export function validatePenName(name, pens, excludingID) {
  const key = penNameKey(name);
  requireValue(key, "羊舍名称不能为空。");
  const live = pens.filter(p => p.deletedAt == null);
  // Existing duplicate names may keep their note edited, just like the App.
  if (excludingID && live.some(p => sameID(p.id, excludingID) && penNameKey(p.name) === key)) return;
  requireValue(!live.some(p => !sameID(p.id, excludingID) && penNameKey(p.name) === key),
    `已有名为“${penName(name)}”的羊舍（包括已停用羊舍），请使用其他名称。`);
}
export function resolvePen(name, pens, optional = false) {
  if (optional && !penName(name)) return null;
  const matches = pens.filter(p => p.deletedAt == null && penNameKey(p.name) === penNameKey(name));
  requireValue(matches.length === 1, `羊舍“${name}”${matches.length ? "对应多个羊舍，请先区分名称" : "不存在，请先在羊舍管理中新建"}。`);
  requireValue(matches[0].isActive, `羊舍“${name}”已停用，请先重新启用或选择其他羊舍。`);
  return matches[0];
}
export function containsPenReference(value, penID) {
  const containsID = item => typeof item === "string" ? sameID(item, penID)
    : item && typeof item === "object" ? Object.values(item).some(containsID) : false;
  if (!value || typeof value !== "object") return false;
  if (typeof value.field === "string" && /penids?$/i.test(value.field)
      && containsID(value.chosen_value ?? value.value ?? value.mutation)) return true;
  return Object.entries(value).some(([key, item]) => /penids?$/i.test(key) && containsID(item) || containsPenReference(item, penID));
}
export function penHasReferences(models, penID, farmID) {
  for (const [model, rows] of Object.entries(models ?? {})) {
    if (["PenRecord", "ESheepCloudStreamState", "TombstoneRecord"].includes(model)) continue;
    for (const row of rows) {
      if (row.farmID && !sameID(row.farmID, farmID)) continue;
      if (model === "DailyPenCountRecord" && !(row.count > 0)) continue;
      if (containsPenReference(row, penID)) return true;
      if (model === "DomainOperation" && row.entityType !== "pen" && row.payload) {
        if (containsPenReference(decodeCheckpointData(row.payload), penID)) return true;
      }
      if (model === "ESheepCloudPendingIntent" && !row.commandKind?.startsWith("pen.") && row.commandEnvelopeData) {
        if (containsPenReference(decodeCheckpointData(row.commandEnvelopeData), penID)) return true;
      }
    }
  }
  return false;
}
export function currentPenCount(models, penID, farmID) {
  return (models?.SheepRecord ?? []).filter(s => sameID(s.farmID, farmID) && s.deletedAt == null
    && s.statusRawValue === "active" && !s.isHistoricalArchive && sameID(s.currentPenID, penID)).length;
}
export function penDeletionBlock(workspace, pen) {
  if (!penPermissions(workspace).ready) return "完整牧场资料尚未读取，暂不能核对删除条件。";
  if (currentPenCount(workspace.models, pen.id, workspace.farm.id) > 0) return "羊舍中仍有羊只，请先完成转群。";
  try {
    if (penHasReferences(workspace.models, pen.id, workspace.farm.id)) return "此羊舍有关联业务或历史记录，不能删除；清空后可停用，历史记录会保留。";
  } catch { return "历史记录尚未核对完整，暂不能删除，请刷新后重试。"; }
  return "";
}
export async function penCommandSpec(action, draft, workspace) {
  const permissions = penPermissions(workspace);
  requireValue(permissions.edit, "当前账号没有羊舍编辑权限，或完整牧场资料尚未读取。");
  const pens = workspace.models.PenRecord.filter(p => sameID(p.farmID, workspace.farm.id));
  const current = pens.find(p => sameID(p.id, draft.penID) && p.deletedAt == null);
  const stream = { type: "pen", id: draft.penID };
  requireValue(/^[\da-f]{8}(-[\da-f]{4}){3}-[\da-f]{12}$/i.test(draft.penID), "羊舍标识无效。");
  if (action !== "create") {
    requireValue(current, "羊舍不存在或已经删除，请刷新后重试。");
    requireValue(draft.expected && ["name", "note", "isActive"].every(key => current[key] === draft.expected[key]),
      "羊舍已被其他成员修改，请关闭窗口并刷新资料后重试。");
  }
  let kind, body, values = {}, fieldNames = [];
  if (action === "create" || action === "update") {
    validatePenName(draft.name, pens, action === "update" ? draft.penID : undefined);
    if (action === "create") requireValue(!pens.some(p => sameID(p.id, draft.penID)), "羊舍标识已存在，请核对原始回执。");
    const name = penName(draft.name), note = String(draft.note ?? "").trim();
    kind = action === "create" ? "pen.create" : "pen.update";
    body = action === "create" ? { create: { name, note } } : { update: { penID: draft.penID, name, note } };
    if (action === "update") values = { name: { type: "string", value: name }, note: { type: "string", value: note } };
  } else {
    requireValue(permissions.lifecycle, "只有牧场主或管理员可以停用、启用和删除羊舍。");
    if (action === "setActive") {
      requireValue(typeof draft.isActive === "boolean", "启用状态无效。");
      requireValue(draft.isActive || currentPenCount(workspace.models, draft.penID, workspace.farm.id) === 0, "羊舍中仍有羊只，不能停用，请先完成转群。");
      kind = "pen.setActive"; body = { setActive: { penID: draft.penID, isActive: draft.isActive } };
      values = { isActive: { type: "boolean", value: draft.isActive } };
    } else {
      requireValue(action === "delete", "未知羊舍操作。");
      const block = penDeletionBlock(workspace, current);
      requireValue(!block, block);
      requireValue(penName(draft.reason), "请填写删除原因。");
      kind = "record.revoke"; body = { tombstone: { entityType: "pen", entityID: draft.penID, reason: penName(draft.reason) } };
      fieldNames = ["lifecycle"];
    }
  }
  fieldNames = [...fieldNames, ...Object.keys(values)];
  const raw = workspace.models.ESheepCloudStreamState?.find(s => s.streamType === "pen" && sameID(s.streamID, draft.penID))?.fieldVersionsData;
  const versions = raw ? decodeCheckpointData(raw) : [];
  requireValue(Array.isArray(versions), "牧场字段版本记录格式不正确。");
  const nullDigest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("null"))), b => b.toString(16).padStart(2, "0")).join("");
  const fields = fieldNames.map(field => {
    const version = versions.find(v => v.field === field);
    return { stream, field, observedVersion: version?.version ?? 0, baseValueDigest: version?.valueDigest ?? nullDigest };
  });
  return { kind, body, occurredAt: Date.now(), streams: [stream], fields,
    changes: Object.entries(values).map(([field, value]) => ({ field, mutation: { action: "set", value } })) };
}
