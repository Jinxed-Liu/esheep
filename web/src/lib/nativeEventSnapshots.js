import { decimalRound } from "./decimal.js";
import { farmDateText } from "./eventExport.js";
import { sha256 } from "./cloudV2Writes.js";

export async function stableUUID(namespace, name) {
  const hex = await sha256(new TextEncoder().encode(`${namespace.toLowerCase()}\n${name}`));
  const bytes = Array.from({ length: 16 }, (_, i) => parseInt(hex.slice(i * 2, i * 2 + 2), 16));
  bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128;
  const s = bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}
export const liveRows = (models, model) => (models?.[model] ?? []).filter((row) => row.deletedAt == null);
const index = (items) => new Map(items.map((row) => [row.id, row]));
const sexNames = { ewe: "母羊", ram: "公羊", unknown: "未知" };
const removalNames = { sold: "出售", culled: "淘汰", deceased: "死亡", transferredOut: "转出" };
const reproNames = { parityBaseline: "胎次确认", breeding: "配种", pregnancyCheck: "孕检", lambing: "产羔", abortion: "流产" };
const fieldList = (pairs) => pairs.map(([label, value]) => ({ label, value: String(value ?? "") }));

// Business snapshots mirror FarmEventHistoryActor. Export facts once by their
// native record ID; command/receipt history is separate from business history.
export async function nativeEventSnapshots(models, { timeZone = "Asia/Shanghai", purposeEvents = [] } = {}) {
  const rows = (model) => liveRows(models, model);
  const sheep = index(models.SheepRecord ?? []), pens = index(models.PenRecord ?? []);
  const tag = (id, fallback = "未知羊只") => sheep.get(id)?.earTag ?? fallback;
  const pen = (id, fallback = "未分圈") => pens.get(id)?.name ?? fallback;
  const day = (value) => value == null ? "" : farmDateText(value, timeZone, false);
  const events = [];
  function add(record, entityType, scope, category, title, subject, detail, pairs, overrides = {}) {
    const related = [record.sheepID, record.eweID, record.sireID].filter(Boolean);
    events.push({ id: record.id, entityType, scope, category, type: scope, label: title, object: subject,
      detail, note: record.note ?? "", at: new Date(record.occurredAt ?? record.createdAt).toISOString(),
      recordedAt: new Date(record.recordedAt ?? record.createdAt).toISOString(), fields: fieldList(pairs),
      relatedSheepIDs: related, status: "synced", actor: "未记录", revision:record.revision, ...overrides });
  }
  for (const row of rows("SheepRecord").filter((r) => !r.isHistoricalArchive)) {
    const sex = sexNames[row.sexRawValue] ?? "未知";
    add({ ...row, occurredAt: row.enteredAt }, "sheep", "sheep", "herd", "新建羊只", row.earTag,
      `${sex} · ${row.breed} · ${pen(row.initialPenID)}`, [["耳号", row.earTag], ["性别", sex], ["品种", row.breed], ["入场圈舍", pen(row.initialPenID)]], { relatedSheepIDs: [row.id] });
    if (row.birthAt != null) add({ ...row, id: await stableUUID(row.id, "farm-event-birth"), occurredAt: row.birthAt, note: "" },
      "sheep", "birth", "herd", "出生", row.earTag, `${sex} · ${row.breed}`,
      [["耳号", row.earTag], ["性别", sex], ["品种", row.breed], ["出生日期", day(row.birthAt)], ["初始圈舍", pen(row.initialPenID)],
        ["母本", tag(row.damID, "未关联")], ["父本来源", tag(row.sireID, row.semenDonorNameSnapshot ?? "未关联")], ["羊只档案ID", row.id]],
      { isDerived: true, relatedSheepIDs: [row.id] });
  }
  const previousBySheep = new Map();
  const purposes = rows("DomainOperation").filter(r=>r.kindRawValue==="care").flatMap(row=>{
    const payload=typeof row.payload==="string"?JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(row.payload),c=>c.charCodeAt(0)))):row.payload?.json??row.payload;
    const args=payload?.careCommand?.setSheepPurpose;
    if(!args||(args.sheepID??args._0)?.toLowerCase()!==row.entityID)return [];
    return [{...row,args,previous:payload.optionalStrings?.previousSheepPurpose,occurredAt:payload.dates?.sheepPurposeChangedAt?Date.parse(payload.dates.sheepPurposeChangedAt):row.occurredAt}];
  }).sort((a,b)=>a.occurredAt-b.occurredAt||a.createdAt-b.createdAt||a.id.localeCompare(b.id));
  for(const row of purposes){const sheepID=row.entityID,purpose=row.args.purpose??row.args._1,reason=(row.args.reason??row.args._2??"").trim(),previous=row.previous?.trim()||previousBySheep.get(sheepID)||"历史用途（未记录）";previousBySheep.set(sheepID,purpose);
    add({...row,note:reason},"sheep","purpose","herd","用途变更",tag(sheepID),`${previous} → ${purpose}`,[["原用途",previous],["新用途",purpose],["变更原因",reason],["羊只修订",row.resultingRevision],["操作账号ID",row.accountID]],{isDerived:true,relatedSheepIDs:[sheepID]});
  }
  for (const row of rows("WeightRecord")) {
    const kg = decimalRound(row.kilogramsText,2,true);
    add(row, "weight", "weight", "herd", "称重", tag(row.sheepID), `${kg} 千克`, [["体重", `${kg} 千克`]]);
  }
  const weightsBySheep = new Map();
  for (const weight of rows("WeightRecord")) { const values = weightsBySheep.get(weight.sheepID) ?? []; values.push(weight); weightsBySheep.set(weight.sheepID, values); }
  for (const row of rows("WeaningRecord")) {
    const child = sheep.get(row.sheepID), birth = row.birthAt ?? child?.birthAt;
    const baseline = (weightsBySheep.get(row.sheepID) ?? []).filter((w) => Number(w.kilogramsText) > 0 && w.occurredAt < row.occurredAt && (birth == null || w.occurredAt >= birth))
      .sort((a, b) => a.occurredAt - b.occurredAt || a.id.localeCompare(b.id))[0];
    const days = baseline ? Math.round((Date.parse(day(row.occurredAt)) - Date.parse(day(baseline.occurredAt))) / 86400000) : 0;
    const gain = days > 0 && Number(row.weanWeightText) > Number(baseline.kilogramsText)
      ? Number(((Number(row.weanWeightText) - Number(baseline.kilogramsText)) / days).toFixed(6)).toString() : "";
    add(row, "weaning", "weaning", "herd", "断奶", tag(row.sheepID), `断奶重 ${row.weanWeightText} 千克`,
      [["耳号", child?.earTag ?? "未知羊只"], ["性别", sexNames[child?.sexRawValue] ?? "未知"], ["品种", child?.breed ?? ""],
        ["状态", { active: "在场", removed: "离场", deceased: "死亡" }[child?.statusRawValue] ?? "未知"], ["当前圈舍", pen(child?.currentPenID)],
        ["出生日期", day(birth)], ["断奶重kg", row.weanWeightText], ["出生重kg", row.birthWeightText],
        ["日增重起算体重kg", baseline ? String(Number(Number(baseline.kilogramsText).toFixed(6))) : ""], ["日增重起算日期", day(baseline?.occurredAt)],
        ["日增重计算天数", gain ? days : ""], ["日增重kg/天", gain], ["母本", tag(row.damID ?? child?.damID, row.legacyDamEarTag ?? "未关联")],
        ["父本来源", tag(child?.sireID, child?.semenDonorNameSnapshot ?? "未关联")], ["胎只数", row.litterSize]]);
  }
  for (const row of rows("TransferRecord")) add(row, "transfer", "transfer", "herd", "转群", tag(row.sheepID),
    `${pen(row.fromPenID)} → ${pen(row.toPenID)}`, [["原圈舍", pen(row.fromPenID)], ["目标圈舍", pen(row.toPenID)]]);
  const removals = rows("RemovalRecord");
  const batchCounts = new Map();
  for (const row of removals) if (row.removalBatchID) batchCounts.set(row.removalBatchID, (batchCounts.get(row.removalBatchID) ?? 0) + 1);
  for (const row of removals) {
    const name = removalNames[row.kindRawValue] ?? row.kindRawValue;
    const fields = [["类型", name], ["原因", row.reason]];
    if (row.removalBatchID) { fields.push(["同批离场数量", `${batchCounts.get(row.removalBatchID)} 只`]);
      if (row.kindRawValue === "sold") fields.push(["同批总售卖金额", row.batchTotalAmountText ?? "未填写"]);
    } else fields.push(["售卖金额", row.amountText ?? "未填写"]);
    add(row, "removal", "removal", "herd", name, tag(row.sheepID), row.reason, fields);
  }
  const batches = index(rows("ProductionBatchRecord").filter((r) => r.sourceRawValue === "manual"));
  for (const row of rows("BatchMembershipRecord")) if (row.leftAt != null && batches.has(row.batchID)) {
    const batch = batches.get(row.batchID), reason = row.leaveReason?.trim() || "手工移出批次";
    add({ ...row, occurredAt: row.leftAt, recordedAt: row.updatedAt }, "batchMembership", "all", "herd", "移出批次", tag(row.sheepID), `${batch.name} · ${reason}`,
      [["生产批次", batch.name], ["生产目的", batch.purpose], ["加入时间", farmDateText(row.joinedAt, timeZone)], ["移出时间", farmDateText(row.leftAt, timeZone)], ["移出原因", reason]]);
  }
  const linesByFeed = new Map();
  for (const line of rows("FeedRecordLine")) { const group = linesByFeed.get(line.feedRecordID) ?? []; group.push(line); linesByFeed.set(line.feedRecordID, group); }
  const runs = index(rows("TMRFeedingRunRecord")), allocations = new Map();
  for (const allocation of rows("TMRFeedingAllocationRecord").sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))) allocations.set(allocation.feedRecordID, allocation);
  for (const row of rows("FeedRecord")) {
    const allocation = allocations.get(row.id), run = runs.get(allocation?.runID);
    const mode = row.modeRawValue === "freeChoice" ? "自由采食" : "限量投喂";
    const lines = (linesByFeed.get(row.id) ?? []).sort((a, b) => a.ingredientNameSnapshot.localeCompare(b.ingredientNameSnapshot, "zh-CN", { numeric: true }))
      .map((line) => `${line.ingredientNameSnapshot} ${line.kilogramsText} ${line.unitSnapshot || "千克"}`).join("；");
    const fields = [["圈舍", pen(row.penID, "未知圈舍")], ["来源", run ? "TMR 投喂" : "直接投喂"], ["方式", mode],
      ["顿次", row.mealName || "未填写"], ["原料明细", lines], ["剩料kg", row.remainingKilogramsText], ["废弃kg", row.discardedKilogramsText]];
    if (run) fields.push(["TMR批次", run.batchCodeSnapshot], ["TMR配方", `${run.formulaNameSnapshot} v${run.formulaRevision}`], ["实际TMR kg", allocation.actualKilogramsText], ["目标TMR kg", allocation.targetKilogramsTextSnapshot]);
    else fields.push(["旧位置备注", row.feederName || "无"]);
    add(row, "feed", "feed", "feeding", run ? "TMR 投喂" : "直接投喂", pen(row.penID, "未知圈舍"), row.mealName || mode, fields);
  }
  const links = rows("HealthSubjectLink");
  for (const row of rows("HealthRecord")) {
    const ids = links.filter((l) => l.healthRecordID === row.id).map((l) => l.sheepID);
    const names = ids.map((id) => tag(id));
    const subject = names.length > 1 ? `${names.length} 只羊` : names[0] ?? (row.sheepID ? tag(row.sheepID) : row.penID ? pen(row.penID, "未知圈舍") : "未关联对象");
    add(row, "health", "health", "health", row.kindRawValue === "vaccination" ? "疫苗" : "治疗", subject, row.itemNameSnapshot,
      [["项目", row.itemNameSnapshot], ["对象", names.length ? names.join("、") : subject], ["剂量", [row.quantityText, row.unit].filter(Boolean).join(" ")], ["途径", row.route || "未填写"]],
      { relatedSheepIDs: [...new Set([...ids, row.sheepID].filter(Boolean))] });
  }
  for (const row of rows("ReproductionRecord")) add(row, "reproduction", "reproduction", "reproduction", reproNames[row.kindRawValue] ?? row.kindRawValue,
    tag(row.eweID, "未知母羊"), row.kindRawValue === "lambing" ? `产羔 ${row.lambCount} 只` : row.result || row.semenNameSnapshot || tag(row.sireID, "已录入"),
    [["母羊", tag(row.eweID, "未知母羊")], ["公羊", tag(row.sireID, "未关联")], ["冻精", row.semenNameSnapshot ?? "未使用"], ["冻精供体", row.semenDonorNameSnapshot],
      ["胎次", row.parity], ["产羔数", row.kindRawValue === "lambing" ? row.lambCount : ""], ["死胎数", row.birthDeadCount], ["结果", row.result || "未填写"]]);
  for (const row of rows("NoteRecord")) add({ ...row, note: "" }, "note", "note", "note", "备注", row.sheepID ? tag(row.sheepID) : row.penID ? pen(row.penID) : "未关联对象", row.text, [["内容", row.text]]);
  for (const [model, entity, targetModel, fk, nameKey, label, reversal] of [
    ["InventoryTransactionRecord", "inventoryTransaction", "InventoryLotRecord", "inventoryLotID", "catalogName", "药品疫苗", "删除健康记录反向恢复库存："],
    ["SemenTransactionRecord", "semenTransaction", "SemenRecord", "semenID", "code", "冻精", "撤销繁殖记录反向恢复冻精："],
  ]) {
    const targets = index(models[targetModel]??[]);
    for (const row of rows(model).filter((r) => r.kindRawValue !== "consumption" && !r.note?.startsWith(reversal))) {
      const target = targets.get(row[fk]), quantity = row.kindRawValue === "receipt" && !row.quantityText.startsWith("-") ? `+${row.quantityText}` : row.quantityText;
      const name = target ? target[nameKey] + (target.batchNumber ? ` · ${target.batchNumber}` : "") : "未知批次";
      add(row, entity, "inventory", "inventory", label + (row.kindRawValue === "receipt" ? "入库" : "盘点"), name, quantity, [["数量变化", quantity]]);
    }
  }
  return events.sort((a, b) => Date.parse(b.at) - Date.parse(a.at) || Date.parse(b.recordedAt) - Date.parse(a.recordedAt) || b.id.localeCompare(a.id));
}
