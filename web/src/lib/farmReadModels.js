import { buildDefaultAppAnalytics } from "./appAnalytics.js";

const DAY_MILLISECONDS = 24 * 60 * 60 * 1000;

const reproductionKindLabels = {
  parityBaseline: "胎次确认",
  breeding: "配种",
  pregnancyCheck: "孕检",
  lambing: "产羔",
  abortion: "流产",
};

const removalKindLabels = {
  sold: "出售",
  culled: "淘汰",
  deceased: "死亡",
  transferredOut: "转出",
  removed: "离场",
};

const feedModeLabels = {
  limited: "限量投喂",
  freeChoice: "自由采食",
};

const sexLabels = {
  ewe: "母",
  female: "母",
  ram: "公",
  male: "公",
};

function normalizeID(value) {
  return String(value ?? "").trim().replaceAll("-", "").toLowerCase();
}

function firstValue(payload, group, ...keys) {
  const values = payload?.[group];
  if (!values || typeof values !== "object") return undefined;
  return keys.map((key) => values[key]).find((value) => value !== undefined && value !== null && value !== "");
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number.parseFloat(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}

function finiteInteger(value) {
  const parsed = finiteNumber(value);
  return parsed == null ? null : Math.trunc(parsed);
}

function validDate(value) {
  if (!value || value === "0001-01-01T00:00:00Z") return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function isoDate(value) {
  return validDate(value)?.toISOString() ?? null;
}

function formatDayKey(value, timeZone) {
  const date = validDate(value);
  if (!date) return null;
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(date);
    const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return `${values.year}-${values.month}-${values.day}`;
  } catch {
    return date.toISOString().slice(0, 10);
  }
}

function formatNumber(value, maximumFractionDigits = 2) {
  return Number(value).toLocaleString("zh-CN", { maximumFractionDigits });
}

function mapLookup(map, id) {
  if (!map || !id) return null;
  const text = String(id).trim();
  return map.get(normalizeID(text)) ?? map.get(text.toLowerCase()) ?? map.get(text) ?? null;
}

function nestedValue(value, key, depth = 0) {
  if (!value || typeof value !== "object" || depth > 5) return undefined;
  if (value[key] !== undefined && value[key] !== null) return value[key];
  for (const child of Object.values(value)) {
    const found = nestedValue(child, key, depth + 1);
    if (found !== undefined) return found;
  }
  return undefined;
}

function decodeEmbeddedPayload(value) {
  if (!value || typeof value !== "string" || typeof globalThis.atob !== "function") return null;
  try {
    const binary = globalThis.atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

function unwrapBootstrapPayload(payload) {
  if (payload?.kind !== "bootstrapEntity") return payload;
  const snapshot = decodeEmbeddedPayload(payload?.dataValues?.snapshot);
  const sourcePayload = decodeEmbeddedPayload(snapshot?.sourcePayload);
  return sourcePayload ? { ...sourcePayload, historySource: "bootstrapEntity" } : payload;
}

function commandValue(payload, commandName) {
  const direct = payload?.careCommand?.[commandName] ?? nestedValue(payload?.careCommand, commandName);
  if (direct?._0 && typeof direct._0 === "object" && !Array.isArray(direct._0)) return direct._0;
  return direct ?? null;
}

function commandArgument(command, index, name) {
  return command?.[name] ?? command?.[`_${index}`] ?? null;
}

function sheepLabel(sheepByID, sheepID, fallbackPrefix = "羊只") {
  const sheep = mapLookup(sheepByID, sheepID);
  if (sheep?.earTag && !["资料未展开", "未记录", "—"].includes(sheep.earTag)) return `${fallbackPrefix} ${sheep.earTag}`.trim();
  return sheepID ? `${fallbackPrefix}（耳号未找到）` : `${fallbackPrefix}未记录`;
}

function penLabel(penNameByID, penID) {
  return mapLookup(penNameByID, penID) ?? (penID ? "圈舍（名称未找到）" : "未分圈");
}

function batchLabel(batchNameByID, batchID) {
  return mapLookup(batchNameByID, batchID) ?? (batchID ? "生产批次（名称未找到）" : "生产批次");
}

function addField(fields, label, value) {
  if (value === undefined || value === null || value === "") return;
  fields.push({ label, value: String(value) });
}

function eventBase(row, payload, actorName) {
  const careOccurredAt = nestedValue(payload?.careCommand, "occurredAt");
  return {
    id: row.operation_id ?? row.entity_id,
    at: firstValue(payload, "dates", "occurredAt") ?? careOccurredAt ?? row.occurred_at ?? row.modified_at ?? row.server_received_at,
    actor: actorName || "历史迁移",
    status: "synced",
    revision: Number(row.revision ?? 0),
    entityID: row.entity_id ?? null,
    fields: [],
    note: "",
  };
}

function eventFallback(row, payload, actorName, sheepByID, penNameByID, batchNameByID, membershipByID) {
  const base = eventBase(row, payload, actorName);
  const entityType = row.entity_type || "unknown";
  const labels = {
    sheep: "羊只档案同步",
    pen: "圈舍档案同步",
    photoAsset: "照片记录",
    tmrFormula: "TMR 配方更新",
    tmrFeedingPlan: "TMR 计划更新",
    careRule: "照护规则更新",
    productionBatch: "生产批次历史同步",
    batchMembership: "批次成员历史同步",
    feedIngredient: "饲料原料历史同步",
    feed: "投喂历史同步",
    weight: "称重历史同步",
    transfer: "转群历史同步",
    removal: "离场历史同步",
    reproduction: "繁殖历史同步",
    weaning: "断奶历史同步",
    note: "备注历史同步",
  };
  const label = labels[entityType] ?? "牧场历史同步";
  const membership = mapLookup(membershipByID, row.entity_id);
  const object = entityType === "sheep"
    ? sheepLabel(sheepByID, row.entity_id)
    : entityType === "pen"
      ? penLabel(penNameByID, row.entity_id)
      : entityType === "productionBatch"
        ? batchLabel(batchNameByID, row.entity_id)
        : entityType === "batchMembership" && membership
          ? sheepLabel(sheepByID, membership.sheepID)
          : label;
  const visibleFields = [];
  addField(visibleFields, "耳号", payload?.strings?.earTag ?? mapLookup(sheepByID, row.entity_id)?.earTag);
  addField(visibleFields, "品种", payload?.strings?.breed);
  addField(visibleFields, "用途", payload?.strings?.purpose);
  if (entityType === "batchMembership" && membership) {
    addField(visibleFields, "生产批次", batchLabel(batchNameByID, membership.batchID));
  }
  return {
    ...base,
    type: entityType === "tmrFormula" || entityType === "tmrFeedingPlan" ? "tmr" : "note",
    label,
    object,
    detail: visibleFields.length ? visibleFields.map((field) => `${field.label} ${field.value}`).join(" · ") : "历史业务记录已同步",
    fields: visibleFields,
  };
}

/**
 * Projects one immutable farm operation into the same kind of human-readable
 * snapshot used by the native event history: subject, concrete value, note,
 * and labeled business fields. The payload must already be decoded.
 */
export function projectFarmOperationEvent({
  row,
  payload = {},
  sheepByID = new Map(),
  penNameByID = new Map(),
  sheepIDByEntityID = new Map(),
  batchNameByID = new Map(),
  membershipByID = new Map(),
  actorName,
}) {
  payload = unwrapBootstrapPayload(payload);
  const base = eventBase(row, payload, actorName);
  const kind = payload.kind;
  const fields = [];
  const identifiers = payload.identifiers ?? {};
  const optionalIdentifiers = payload.optionalIdentifiers ?? {};
  const strings = payload.strings ?? {};
  const optionalStrings = payload.optionalStrings ?? {};
  const entitySheepID = mapLookup(sheepIDByEntityID, row.entity_id);
  const sheepID = identifiers.sheepID ?? optionalIdentifiers.sheepID ?? nestedValue(payload?.careCommand, "sheepID") ?? entitySheepID ?? (row.entity_type === "sheep" ? row.entity_id : null);
  const sheep = mapLookup(sheepByID, sheepID);

  if (kind === "createBatch") {
    const batchName = strings.name || batchLabel(batchNameByID, row.entity_id);
    const memberCount = String(strings.sheepIDs ?? "").split(",").filter(Boolean).length;
    addField(fields, "批次名称", batchName);
    addField(fields, "生产目的", strings.purpose);
    addField(fields, "开始日期", firstValue(payload, "dates", "startedAt"));
    addField(fields, "初始成员", memberCount ? `${memberCount} 只` : null);
    return {
      ...base,
      type: "note",
      label: payload.historySource === "bootstrapEntity" ? "生产批次建档" : "新建生产批次",
      object: batchName,
      detail: [strings.purpose, memberCount ? `${memberCount} 只羊` : null].filter(Boolean).join(" · ") || "批次资料已保存",
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "assignBatchMembership" || kind === "leaveBatchMembership") {
    const batchID = identifiers.batchID;
    const operationSheepID = identifiers.sheepID;
    const batchName = batchLabel(batchNameByID, batchID);
    addField(fields, "生产批次", batchName);
    addField(fields, kind === "leaveBatchMembership" ? "移出时间" : "加入时间", firstValue(payload, "dates", kind === "leaveBatchMembership" ? "leftAt" : "joinedAt"));
    addField(fields, "原因", strings.reason);
    return {
      ...base,
      type: "note",
      label: kind === "leaveBatchMembership" ? "移出生产批次" : "加入生产批次",
      object: sheepLabel(sheepByID, operationSheepID),
      detail: `${kind === "leaveBatchMembership" ? "从" : "加入"} ${batchName}${strings.reason ? ` · ${strings.reason}` : ""}`,
      note: strings.reason ?? "",
      fields,
    };
  }

  if (kind === "restoreBatchMembership") {
    const membership = mapLookup(membershipByID, identifiers.membershipID ?? row.entity_id);
    const batchName = batchLabel(batchNameByID, membership?.batchID);
    addField(fields, "生产批次", batchName);
    addField(fields, "恢复时间", firstValue(payload, "dates", "restoredAt"));
    addField(fields, "原因", strings.reason);
    return {
      ...base,
      type: "note",
      label: "恢复生产批次成员",
      object: sheepLabel(sheepByID, membership?.sheepID),
      detail: `恢复加入 ${batchName}${strings.reason ? ` · ${strings.reason}` : ""}`,
      note: strings.reason ?? "",
      fields,
    };
  }

  if (kind === "recordWeight" || kind === "correctWeight") {
    const kilograms = finiteNumber(strings.kilogramsText);
    addField(fields, "体重", kilograms == null ? null : `${formatNumber(kilograms)} kg`);
    addField(fields, "当前圈舍", sheep?.pen);
    return {
      ...base,
      type: "weight",
      label: kind === "correctWeight" ? "称重修正" : "称重记录",
      object: sheepLabel(sheepByID, sheepID),
      detail: kilograms == null ? "体重值未记录" : `${formatNumber(kilograms)} kg`,
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "recordWeaning") {
    const weanWeight = finiteNumber(strings.weanWeightText);
    const damID = optionalIdentifiers.damID;
    addField(fields, "断奶重", weanWeight == null ? null : `${formatNumber(weanWeight)} kg`);
    addField(fields, "出生日期", firstValue(payload, "optionalDates", "birthAt"));
    addField(fields, "出生重", optionalStrings.birthWeightText ? `${optionalStrings.birthWeightText} kg` : null);
    addField(fields, "日增重", optionalStrings.averageDailyGainText ? `${optionalStrings.averageDailyGainText} kg/天` : null);
    addField(fields, "母羊", damID ? sheepLabel(sheepByID, damID, "母羊") : null);
    addField(fields, "窝产数", payload.integers?.litterSize == null ? null : `${payload.integers.litterSize} 只`);
    return {
      ...base,
      type: "reproduction",
      label: "断奶记录",
      object: sheepLabel(sheepByID, sheepID, "羔羊"),
      detail: weanWeight == null ? "已记录断奶" : `断奶重 ${formatNumber(weanWeight)} kg`,
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "transferSheep" || kind === "correctTransfer") {
    const toPenID = optionalIdentifiers.toPenID;
    const target = penLabel(penNameByID, toPenID);
    addField(fields, "转入圈舍", target);
    return {
      ...base,
      type: "transfer",
      label: kind === "correctTransfer" ? "转群修正" : "转群记录",
      object: sheepLabel(sheepByID, sheepID),
      detail: `转入 ${target}`,
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "removeSheep" || kind === "correctRemoval") {
    const removalKind = strings.kind || "removed";
    const kindLabel = removalKindLabels[removalKind] ?? removalKind;
    addField(fields, "离场类型", kindLabel);
    addField(fields, "原因", strings.reason || "未填写");
    addField(fields, "金额", optionalStrings.amountText ? `¥${optionalStrings.amountText}` : null);
    addField(fields, "批次总金额", optionalStrings.batchTotalAmountText ? `¥${optionalStrings.batchTotalAmountText}` : null);
    return {
      ...base,
      type: "removal",
      label: kind === "correctRemoval" ? `${kindLabel}修正` : `${kindLabel}记录`,
      object: sheepLabel(sheepByID, sheepID),
      detail: strings.reason ? `${kindLabel} · ${strings.reason}` : kindLabel,
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "recordFeed") {
    const penID = identifiers.penID;
    const lines = Array.isArray(payload.feedLines) ? payload.feedLines : [];
    const kilograms = lines.reduce((sum, line) => sum + (finiteNumber(line.kilogramsText) ?? 0), 0);
    const lineSummary = lines
      .slice(0, 6)
      .map((line) => `${line.ingredientNameSnapshot || "未命名原料"} ${formatNumber(finiteNumber(line.kilogramsText) ?? 0)} kg`)
      .join("；");
    const mode = feedModeLabels[strings.mode] ?? strings.mode ?? "投喂";
    addField(fields, "投喂方式", mode);
    addField(fields, "顿次", strings.mealName || strings.meal);
    addField(fields, "总投喂量", `${formatNumber(kilograms)} kg`);
    addField(fields, "原料明细", lineSummary);
    return {
      ...base,
      type: "feed",
      label: "投喂记录",
      object: penLabel(penNameByID, penID),
      detail: `${mode} · ${lines.length} 种原料 · ${formatNumber(kilograms)} kg`,
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "recordReproduction") {
    const eweID = identifiers.eweID;
    const sireID = optionalIdentifiers.sireID;
    const reproductionKind = strings.kind || "reproduction";
    const kindLabel = reproductionKindLabels[reproductionKind] ?? reproductionKind;
    const lambCount = finiteInteger(payload.integers?.lambCount);
    addField(fields, "类型", kindLabel);
    addField(fields, "结果", strings.result);
    addField(fields, "父本", sireID ? sheepLabel(sheepByID, sireID, "公羊") : optionalStrings.semenName);
    addField(fields, "胎次", payload.integers?.parity == null ? null : `${payload.integers.parity} 胎`);
    addField(fields, "产羔数", lambCount == null ? null : `${lambCount} 只`);
    addField(fields, "死羔数", payload.integers?.birthDeadCount == null ? null : `${payload.integers.birthDeadCount} 只`);
    const detail = reproductionKind === "lambing" && lambCount != null
      ? `产羔 ${lambCount} 只`
      : [kindLabel, strings.result].filter(Boolean).join(" · ");
    return {
      ...base,
      type: "reproduction",
      label: `${kindLabel}记录`,
      object: sheepLabel(sheepByID, eweID, "母羊"),
      detail: detail || "繁殖记录",
      note: strings.note ?? "",
      fields,
    };
  }

  const lambing = commandValue(payload, "recordLambing");
  if (kind === "care" && lambing) {
    const offspring = Array.isArray(lambing.offspring) ? lambing.offspring : [];
    addField(fields, "父本", lambing.sireID ? sheepLabel(sheepByID, lambing.sireID, "公羊") : null);
    addField(fields, "胎次", lambing.parity == null ? null : `${lambing.parity} 胎`);
    addField(fields, "产羔数", `${offspring.length} 只`);
    addField(fields, "死羔数", lambing.birthDeadCount == null ? null : `${lambing.birthDeadCount} 只`);
    addField(fields, "羔羊", offspring.map((item) => {
      const sex = item.sex ?? item.sexRawValue;
      return `${item.earTag || item.legacyEarTag || "耳号未记录"}（${sexLabels[String(sex).toLowerCase()] ?? sex ?? "性别未记"}${item.isStillborn ? "，死羔" : ""}）`;
    }).join("、"));
    return {
      ...base,
      at: lambing.occurredAt ?? base.at,
      type: "reproduction",
      label: "产羔记录",
      object: sheepLabel(sheepByID, lambing.eweID, "母羊"),
      detail: `产羔 ${offspring.length} 只${lambing.birthDeadCount ? `，其中死羔 ${lambing.birthDeadCount} 只` : ""}`,
      note: lambing.note ?? "",
      fields,
    };
  }

  const pedigree = commandValue(payload, "updateSheepPedigree");
  if (kind === "care" && pedigree) {
    const pedigreeSheepID = commandArgument(pedigree, 0, "sheepID") ?? row.entity_id;
    const damID = commandArgument(pedigree, 2, "damID");
    const sireID = commandArgument(pedigree, 4, "sireID");
    const reason = commandArgument(pedigree, 10, "reason");
    addField(fields, "母本", damID ? sheepLabel(sheepByID, damID, "母羊") : "未设置");
    addField(fields, "父本", sireID ? sheepLabel(sheepByID, sireID, "公羊") : "未设置");
    addField(fields, "依据", reason);
    return {
      ...base,
      type: "reproduction",
      label: "系谱更新",
      object: sheepLabel(sheepByID, pedigreeSheepID),
      detail: `母本 ${damID ? sheepLabel(sheepByID, damID, "") : "未设置"} · 父本 ${sireID ? sheepLabel(sheepByID, sireID, "") : "未设置"}`,
      note: reason ?? "",
      fields,
    };
  }

  if (kind === "addNote") {
    const penID = optionalIdentifiers.penID;
    const object = sheepID
      ? sheepLabel(sheepByID, sheepID)
      : penID
        ? penLabel(penNameByID, penID)
        : "牧场";
    addField(fields, "备注内容", strings.text);
    return {
      ...base,
      type: "note",
      label: "备注记录",
      object,
      detail: strings.text || "空备注",
      note: "",
      fields,
    };
  }

  if (kind === "addSheep" || kind === "updateSheepProfile") {
    const rowSheepID = sheepID ?? row.entity_id;
    const earTag = strings.earTag || strings.legacyEarTag || mapLookup(sheepByID, rowSheepID)?.earTag;
    const penID = optionalIdentifiers.penID;
    addField(fields, "耳号", earTag);
    addField(fields, "品种", strings.breed);
    addField(fields, "性别", sexLabels[String(strings.sex).toLowerCase()] ?? strings.sex);
    addField(fields, "用途", strings.purpose);
    addField(fields, "圈舍", penID ? penLabel(penNameByID, penID) : null);
    return {
      ...base,
      type: "note",
      label: kind === "addSheep" ? "新建羊只" : "羊只档案保存（耳号、品种、性别）",
      object: earTag ? `羊只 ${earTag}` : sheepLabel(sheepByID, rowSheepID),
      detail: [strings.breed, sexLabels[String(strings.sex).toLowerCase()] ?? strings.sex, strings.purpose].filter(Boolean).join(" · ") || "档案字段已更新",
      note: strings.note ?? "",
      fields,
    };
  }

  if (kind === "createPen" || kind === "updatePen") {
    const penID = identifiers.penID ?? row.entity_id;
    const name = strings.name || penLabel(penNameByID, penID);
    addField(fields, "圈舍名称", name);
    addField(fields, "用途 / 备注", strings.note);
    return {
      ...base,
      type: "note",
      label: kind === "createPen" ? "新建圈舍" : "圈舍资料更新",
      object: name,
      detail: strings.note || "圈舍资料已更新",
      note: "",
      fields,
    };
  }

  if (kind === "resolveConflict") {
    const entityID = identifiers.entityID ?? row.entity_id;
    const resolvedPayload = decodeEmbeddedPayload(payload.dataValues?.resolvedPayload);
    const resolvedName = resolvedPayload?.strings?.name;
    const decisionLabels = { acceptedRemote: "采用远端权威", keptLocal: "保留本地版本", merged: "合并版本" };
    const decision = decisionLabels[strings.decision] ?? strings.decision ?? "已解决";
    addField(fields, "对象名称", resolvedName);
    addField(fields, "处理决定", decision);
    addField(fields, "本地修订", payload.integers?.localRevision);
    addField(fields, "远端修订", payload.integers?.remoteRevision);
    addField(fields, "结果修订", payload.integers?.resolvedRevision);
    return {
      ...base,
      type: "note",
      label: "冲突处理",
      object: resolvedName || (row.entity_type === "pen" ? penLabel(penNameByID, entityID) : "业务记录"),
      detail: decision,
      note: strings.note ?? "",
      fields,
    };
  }

  const breedingRam = commandValue(payload, "setBreedingRam");
  if (kind === "care" && breedingRam) {
    const breedingSheepID = commandArgument(breedingRam, 0, "sheepID") ?? row.entity_id;
    const enabled = commandArgument(breedingRam, 1, "isBreedingRam") === true;
    addField(fields, "种公羊状态", enabled ? "是" : "否");
    return {
      ...base,
      type: "reproduction",
      label: "种公羊状态更新",
      object: sheepLabel(sheepByID, breedingSheepID, "公羊"),
      detail: enabled ? "设为种公羊" : "取消种公羊标记",
      note: "",
      fields,
    };
  }

  const purpose = commandValue(payload, "setSheepPurpose");
  if (kind === "care" && purpose) {
    const purposeSheepID = commandArgument(purpose, 0, "sheepID") ?? row.entity_id;
    const purposeLabels = { unclassified: "未分类", sucklingLamb: "哺乳羔羊", weanedLamb: "断奶羔羊", growing: "育成羊", replacementEwe: "后备母羊", breedingEwe: "繁殖母羊", breedingRam: "种公羊", fattening: "育肥羊" };
    const purposeValue = commandArgument(purpose, 1, "purpose");
    const purposeLabel = purposeLabels[purposeValue] ?? purposeValue ?? "未分类";
    const reason = commandArgument(purpose, 2, "reason");
    addField(fields, "新用途", purposeLabel);
    addField(fields, "修改原因", reason);
    addField(fields, "原用途", optionalStrings.previousSheepPurpose);
    return {
      ...base,
      at: firstValue(payload, "dates", "sheepPurposeChangedAt") ?? base.at,
      type: "note",
      label: "用途变更",
      object: sheepLabel(sheepByID, purposeSheepID),
      detail: `调整为 ${purposeLabel}`,
      note: reason ?? "",
      fields,
    };
  }

  if (kind === "addPhoto") {
    const photoSheepID = optionalIdentifiers.sheepID;
    const dimensions = payload.integers?.cloudPixelWidth && payload.integers?.cloudPixelHeight
      ? `${payload.integers.cloudPixelWidth} × ${payload.integers.cloudPixelHeight}`
      : null;
    addField(fields, "原耳号快照", strings.originalEarTag);
    addField(fields, "文件类型", strings.mimeType);
    addField(fields, "像素", dimensions);
    addField(fields, "文件大小", payload.integers?.byteCount ? `${formatNumber(payload.integers.byteCount / 1024, 0)} KB` : null);
    return {
      ...base,
      type: "note",
      label: "照片记录",
      object: photoSheepID ? sheepLabel(sheepByID, photoSheepID) : `羊只 ${strings.originalEarTag || "未识别"}`,
      detail: [strings.originalEarTag ? `耳号 ${strings.originalEarTag}` : null, strings.mimeType, dimensions].filter(Boolean).join(" · ") || "照片已保存",
      note: "",
      fields,
    };
  }

  const health = commandValue(payload, "recordHealth") ?? (kind === "recordHealth" ? payload : null);
  if (health) {
    const healthSheepID = health.sheepID ?? sheepID;
    addField(fields, "项目", health.itemName ?? strings.itemName ?? strings.kind);
    addField(fields, "剂量", health.doseText ?? optionalStrings.doseText);
    addField(fields, "途径", health.route ?? optionalStrings.route);
    return {
      ...base,
      at: health.occurredAt ?? base.at,
      type: "health",
      label: "健康记录",
      object: sheepLabel(sheepByID, healthSheepID),
      detail: [health.itemName ?? strings.itemName ?? strings.kind, health.doseText ?? optionalStrings.doseText].filter(Boolean).join(" · ") || "健康事项已记录",
      note: health.note ?? strings.note ?? "",
      fields,
    };
  }

  const formula = payload?.tmrCommand?.saveFormula?._0 ?? payload?.tmrCommand?.saveFormula;
  if (formula) {
    const componentCount = Array.isArray(formula.components) ? formula.components.length : 0;
    addField(fields, "配方名称", formula.name);
    addField(fields, "适用阶段", formula.stage);
    addField(fields, "原料数", `${componentCount} 种`);
    return {
      ...base,
      type: "tmr",
      label: "TMR 配方更新",
      object: `配方 ${formula.name || "名称未记录"}`,
      detail: `${formula.stage || "阶段未标注"} · ${componentCount} 种原料`,
      note: formula.note ?? "",
      fields,
    };
  }

  const feedingPlan = payload?.tmrCommand?.saveFeedingPlan?._0 ?? payload?.tmrCommand?.saveFeedingPlan;
  if (feedingPlan) {
    const pens = Array.isArray(feedingPlan.pens) ? feedingPlan.pens : [];
    const planPens = pens.map((item) => penLabel(penNameByID, item.penID)).join("、");
    addField(fields, "适用圈舍", planPens);
    addField(fields, "圈舍数", `${pens.length} 个`);
    addField(fields, "分配方式", feedingPlan.allocationMode);
    addField(fields, "记录粒度", feedingPlan.granularity);
    addField(fields, "早 / 中 / 晚", [feedingPlan.morningShareText, feedingPlan.noonShareText, feedingPlan.eveningShareText].filter((value) => value != null).join(" / "));
    addField(fields, "偏差容忍", feedingPlan.tolerancePercentText ? `${feedingPlan.tolerancePercentText}%` : null);
    addField(fields, "监控", feedingPlan.monitoringEnabled ? "已开启" : "未开启");
    return {
      ...base,
      type: "tmr",
      label: "TMR 计划更新",
      object: "TMR 投喂计划",
      detail: `${pens.length} 个圈舍 · ${feedingPlan.monitoringEnabled ? "监控已开启" : "监控未开启"}`,
      note: feedingPlan.note ?? "",
      fields,
    };
  }

  const alertRules = commandValue(payload, "updateOperationalAlertRules");
  if (alertRules) {
    addField(fields, "妊娠期", `${alertRules.gestationDays} 天`);
    addField(fields, "孕检日龄", `${alertRules.pregnancyCheckDays} 天`);
    addField(fields, "断奶日龄", `${alertRules.weaningAgeDays} 天`);
    addField(fields, "提前提醒", `${alertRules.warningLeadDays} 天`);
    addField(fields, "每日摘要", alertRules.digestEnabled ? "已开启" : "未开启");
    return {
      ...base,
      type: "note",
      label: "照护提醒规则更新",
      object: "牧场照护规则",
      detail: `妊娠 ${alertRules.gestationDays} 天 · 孕检 ${alertRules.pregnancyCheckDays} 天 · 断奶 ${alertRules.weaningAgeDays} 天`,
      note: "",
      fields,
    };
  }

  const ingredientName = strings.name;
  if ((kind === "saveFeedIngredient" || kind === "addIngredient") && ingredientName) {
    addField(fields, "原料名称", ingredientName);
    addField(fields, "分类", strings.category);
    addField(fields, "单位", strings.unit);
    return {
      ...base,
      type: "feed",
      label: kind === "addIngredient" ? "新建原料" : "原料更新",
      object: `原料 ${ingredientName}`,
      detail: [strings.category, strings.unit].filter(Boolean).join(" · ") || "原料资料已更新",
      note: strings.note ?? "",
      fields,
    };
  }

  return eventFallback(row, payload, actorName, sheepByID, penNameByID, batchNameByID, membershipByID);
}

export function buildEventSheepIndex(operationRows) {
  const result = new Map();
  for (const row of operationRows ?? []) {
    const payload = row.payload_json ?? {};
    const identifiers = payload.identifiers ?? {};
    const optionalIdentifiers = payload.optionalIdentifiers ?? {};
    const careSheepID = nestedValue(payload.careCommand, "sheepID") ?? nestedValue(payload.careCommand, "eweID");
    const sheepID = identifiers.sheepID ?? identifiers.eweID ?? optionalIdentifiers.sheepID ?? careSheepID ?? (row.entity_type === "sheep" ? row.entity_id : null);
    if (row.entity_id && sheepID) result.set(normalizeID(row.entity_id), sheepID);
  }
  return result;
}

export function projectionToWeightRecord(row, payload = {}) {
  const sheepID = firstValue(payload, "identifiers", "sheepID");
  const kilograms = finiteNumber(firstValue(payload, "strings", "kilogramsText"));
  const at = firstValue(payload, "dates", "occurredAt") ?? row.modified_at;
  if (!sheepID || kilograms == null || !validDate(at)) return null;
  return {
    id: row.entity_id,
    sheepID,
    at: isoDate(at),
    kilograms,
    note: firstValue(payload, "strings", "note") ?? "",
    source: "weight",
  };
}

export function projectionToWeaningRecord(row, payload = {}) {
  const sheepID = firstValue(payload, "identifiers", "sheepID");
  const at = firstValue(payload, "dates", "occurredAt") ?? row.modified_at;
  if (!sheepID || !validDate(at)) return null;
  return {
    id: row.entity_id,
    sheepID,
    damID: firstValue(payload, "optionalIdentifiers", "damID") ?? null,
    at: isoDate(at),
    birthAt: isoDate(firstValue(payload, "optionalDates", "birthAt")),
    weanWeight: finiteNumber(firstValue(payload, "strings", "weanWeightText")),
    birthWeight: finiteNumber(firstValue(payload, "optionalStrings", "birthWeightText")),
    recordedADG: finiteNumber(firstValue(payload, "optionalStrings", "averageDailyGainText")),
    litterSize: finiteInteger(firstValue(payload, "integers", "litterSize")),
    note: firstValue(payload, "strings", "note") ?? "",
  };
}

export function projectionToReproductionRecord(row, payload = {}) {
  const lambing = commandValue(payload, "recordLambing");
  if (lambing) {
    const offspring = Array.isArray(lambing.offspring) ? lambing.offspring : [];
    const at = lambing.occurredAt ?? row.modified_at;
    if (!lambing.eweID || !validDate(at)) return null;
    return {
      id: row.entity_id,
      eweID: lambing.eweID,
      sireID: lambing.sireID ?? null,
      penID: lambing.penID ?? null,
      at: isoDate(at),
      kind: "lambing",
      result: "",
      lambCount: offspring.length,
      parity: finiteInteger(lambing.parity),
      birthDeadCount: finiteInteger(lambing.birthDeadCount),
      offspring: offspring.map((item, index) => ({
        id: item.id ?? `${row.entity_id}:offspring:${index}`,
        sheepID: item.sheepID ?? null,
        earTag: item.earTag ?? item.legacyEarTag ?? null,
        sex: item.sex ?? item.sexRawValue ?? null,
        birthWeight: finiteNumber(item.birthWeightText),
        isStillborn: item.isStillborn === true,
      })),
      note: lambing.note ?? "",
      source: "care",
    };
  }

  const eweID = firstValue(payload, "identifiers", "eweID");
  const at = firstValue(payload, "dates", "occurredAt") ?? row.modified_at;
  if (!eweID || !validDate(at)) return null;
  const offspring = Array.isArray(payload.lambingOffspring) ? payload.lambingOffspring : [];
  return {
    id: row.entity_id,
    eweID,
    sireID: firstValue(payload, "optionalIdentifiers", "sireID") ?? null,
    penID: firstValue(payload, "optionalIdentifiers", "penID") ?? null,
    at: isoDate(at),
    kind: firstValue(payload, "strings", "kind") ?? "reproduction",
    result: firstValue(payload, "strings", "result") ?? "",
    lambCount: finiteInteger(firstValue(payload, "integers", "lambCount")),
    parity: finiteInteger(firstValue(payload, "integers", "parity")),
    birthDeadCount: finiteInteger(firstValue(payload, "integers", "birthDeadCount")),
    offspring: offspring.map((item, index) => ({
      id: item.id ?? `${row.entity_id}:offspring:${index}`,
      sheepID: item.sheepID ?? null,
      earTag: item.earTag ?? item.legacyEarTag ?? null,
      sex: item.sex ?? item.sexRawValue ?? null,
      birthWeight: finiteNumber(item.birthWeightText),
      isStillborn: item.isStillborn === true,
    })),
    note: firstValue(payload, "strings", "note") ?? "",
    source: "projection",
  };
}

function average(values) {
  const usable = values.filter((value) => Number.isFinite(value));
  if (!usable.length) return null;
  return usable.reduce((sum, value) => sum + value, 0) / usable.length;
}

function recordBoundary(records) {
  const dates = records.map((record) => validDate(record.at)).filter(Boolean).sort((left, right) => left - right);
  return {
    firstAt: dates[0]?.toISOString() ?? null,
    lastAt: dates.at(-1)?.toISOString() ?? null,
    sampleCount: records.length,
  };
}

function groupAverageByDay(records, valueKey, timeZone) {
  const groups = new Map();
  for (const record of records) {
    const key = formatDayKey(record.at, timeZone);
    const value = record[valueKey];
    if (!key || !Number.isFinite(value)) continue;
    const group = groups.get(key) ?? [];
    group.push(value);
    groups.set(key, group);
  }
  return [...groups.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([date, values]) => ({ date, value: average(values), sampleCount: values.length }));
}

function canonicalWeightSamples(weightRecords, weaningRecords, reproductionRecords, timeZone) {
  const candidates = [];
  for (const record of weightRecords) {
    candidates.push({ ...record, priority: 0, source: "weight" });
  }
  for (const record of weaningRecords) {
    if (record.weanWeight != null) {
      candidates.push({ id: `${record.id}:weaning`, sheepID: record.sheepID, at: record.at, kilograms: record.weanWeight, priority: 1, source: "weaning" });
    }
  }
  for (const record of reproductionRecords) {
    if (record.kind !== "lambing") continue;
    for (const [index, offspring] of record.offspring.entries()) {
      if (offspring.sheepID && offspring.birthWeight != null) {
        candidates.push({ id: `${record.id}:birth:${index}`, sheepID: offspring.sheepID, at: record.at, kilograms: offspring.birthWeight, priority: 2, source: "lambingBirth" });
      }
    }
  }
  for (const record of weaningRecords) {
    if (record.birthAt && record.birthWeight != null) {
      candidates.push({ id: `${record.id}:birth`, sheepID: record.sheepID, at: record.birthAt, kilograms: record.birthWeight, priority: 3, source: "weaningBirth" });
    }
  }

  const bySheepDay = new Map();
  candidates.forEach((candidate, index) => {
    const day = formatDayKey(candidate.at, timeZone);
    if (!candidate.sheepID || !day || !Number.isFinite(candidate.kilograms)) return;
    const key = `${normalizeID(candidate.sheepID)}:${day}`;
    const existing = bySheepDay.get(key);
    if (!existing || candidate.priority < existing.priority || (candidate.priority === existing.priority && index > existing.index)) {
      bySheepDay.set(key, { ...candidate, day, index });
    }
  });
  return [...bySheepDay.values()].sort((left, right) => new Date(left.at) - new Date(right.at) || left.index - right.index);
}

function monthlyLambingTrend(completeLambings, timeZone) {
  const groups = new Map();
  for (const record of completeLambings) {
    const month = formatDayKey(record.at, timeZone)?.slice(0, 7);
    if (!month) continue;
    const group = groups.get(month) ?? { month, lambingCount: 0, born: 0, dead: 0 };
    group.lambingCount += 1;
    group.born += record.lambCount;
    group.dead += record.birthDeadCount;
    groups.set(month, group);
  }
  return [...groups.values()].sort((left, right) => left.month.localeCompare(right.month)).slice(-12);
}

function monthlyWeaningTrend(weaningRecords, timeZone) {
  const groups = new Map();
  for (const record of weaningRecords) {
    const month = formatDayKey(record.at, timeZone)?.slice(0, 7);
    if (!month) continue;
    const group = groups.get(month) ?? { month, count: 0, weights: [] };
    group.count += 1;
    if (record.weanWeight > 0) group.weights.push(record.weanWeight);
    groups.set(month, group);
  }
  return [...groups.values()]
    .sort((left, right) => left.month.localeCompare(right.month))
    .slice(-12)
    .map((group) => ({ month: group.month, count: group.count, averageWeight: average(group.weights), weightSampleCount: group.weights.length }));
}

/** Builds the four default insight views with the same filters and semantics as the App. */
export function buildFarmInsightData({
  source = null,
  sheep = [],
  pens = [],
  weightRecords = [],
  weaningRecords = [],
  reproductionRecords = [],
  removalRecords = [],
  transferRecords = [],
  batches = [],
  batchMemberships = [],
  feedRecords = [],
  troughObservations = [],
  dailyPenCounts = [],
  timeZone = "Asia/Shanghai",
  asOf = new Date(),
}) {
  const identifiers = new Map();
  const remember = (id, overrides = {}) => {
    if (!id) return;
    const key = normalizeID(id);
    identifiers.set(key, { id, earTag: String(id).slice(0, 8), breed: "未知", purpose: "未分类", sex: "unknown", status: "active", enteredAt: "1900-01-01T00:00:00Z", initialPenID: null, ...identifiers.get(key), ...overrides });
  };
  for (const record of weightRecords) remember(record.sheepID);
  for (const record of weaningRecords) remember(record.sheepID);
  for (const record of reproductionRecords) {
    remember(record.eweID, { sex: "ewe", purpose: "繁殖母羊" });
    for (const child of record.offspring ?? []) remember(child.sheepID, { sex: child.sex ?? "unknown" });
  }
  const snapshot = source ?? {
    sheep: sheep.length ? sheep : [...identifiers.values()],
    pens,
    weights: weightRecords,
    weanings: weaningRecords,
    reproduction: reproductionRecords,
    removals: removalRecords,
    transfers: transferRecords,
    batches,
    batchMemberships,
    feeds: feedRecords,
    troughObservations,
    dailyPenCounts,
  };
  return buildDefaultAppAnalytics(snapshot, { now: asOf, timeZone });
}
