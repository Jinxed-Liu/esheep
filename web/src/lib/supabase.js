import { createClient } from "@supabase/supabase-js";
import { decodeCompactCheckpoint } from "./lzfse";
import { isSupabaseConfigured, supabaseBrowserConfiguration } from "./supabaseConfig.js";
import {
  countByNormalizedIdentifier,
  mergeProjectionPayload,
  normalizedIdentifier,
  uniqueByNormalizedIdentifier,
} from "./workspaceProjection.js";
import {
  normalizeWorkspaceSections,
  workspaceEntityTypesForSections,
} from "./workspaceDataSource.js";
import {
  buildEventSheepIndex,
  buildFarmInsightData,
  projectFarmOperationEvent,
  projectionToReproductionRecord,
  projectionToWeaningRecord,
  projectionToWeightRecord,
} from "./farmReadModels.js";
import { decodeFeedNutrients, farmDayKey } from "./appAnalytics.js";

const { url, publishableKey } = supabaseBrowserConfiguration;

const browserClientKey = "__esheepnextSupabaseClient";

export const supabase = isSupabaseConfigured
  ? globalThis[browserClientKey] ?? (globalThis[browserClientKey] = createClient(url, publishableKey, {
      auth: {
        autoRefreshToken: true,
        detectSessionInUrl: true,
        persistSession: true,
      },
      global: {
        headers: { "x-client-info": "esheepplus-web/0.1" },
      },
    }))
  : null;

const roleNames = {
  owner: "所有者",
  administrator: "管理员",
  worker: "成员",
};

export const NO_FARM_ACCESS_CODE = "NO_FARM_ACCESS";

const entityRowSelect = "entity_id,entity_type,revision,operation_id,modified_at,deleted_at,payload_json,payload_base64";
const entityPageSize = 1000;

const statusLabels = {
  active: "在场",
  deceased: "已死亡",
  removed: "已离场",
  sold: "已出售",
};

const feedModeLabels = {
  limited: "限量投喂",
  freeChoice: "自由采食",
};

function decodeBase64JSON(value) {
  if (!value || typeof value !== "string") return null;
  try {
    const binary = globalThis.atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const text = new TextDecoder().decode(bytes);
    const parsed = JSON.parse(text);
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

function payloadForRow(row) {
  return row?.payload_json ?? decodeBase64JSON(row?.payload_base64) ?? {};
}

function projectionKey(entityType, entityID) {
  return `${entityType}:${normalizedIdentifier(entityID)}`;
}

function baselineProjectionPayloads(baselinePackage) {
  const result = new Map();
  for (const projection of baselinePackage?.projections ?? []) {
    if (!projection?.entityType || !projection?.entityID || !projection?.payload) continue;
    result.set(projectionKey(projection.entityType, projection.entityID), projection.payload);
  }
  return result;
}

function expandRowsFromBaseline(rows, baselinePayloads) {
  if (!baselinePayloads?.size) return rows;
  return rows.map((row) => {
    if (!row.operation_id) return row;
    const baselineEncoded = baselinePayloads.get(projectionKey(row.entity_type, row.entity_id));
    const baselinePayload = decodeBase64JSON(baselineEncoded);
    if (!baselinePayload) return row;
    return {
      ...row,
      payload_json: mergeProjectionPayload(baselinePayload, payloadForRow(row)),
      payload_base64: null,
    };
  });
}

function expandSheepRowsFromHistory(rows, baselinePayloads, operationRows) {
  const operationsBySheep = new Map();
  for (const operation of operationRows) {
    if (operation.entity_type !== "sheep" || !operation.entity_id) continue;
    const key = normalizedIdentifier(operation.entity_id);
    const list = operationsBySheep.get(key) ?? [];
    list.push(operation);
    operationsBySheep.set(key, list);
  }
  for (const list of operationsBySheep.values()) {
    list.sort((left, right) => Number(left.revision) - Number(right.revision) || String(left.operation_id).localeCompare(String(right.operation_id)));
  }

  return rows.map((row) => {
    const baselineEncoded = baselinePayloads?.get(projectionKey(row.entity_type, row.entity_id));
    const baselinePayload = decodeBase64JSON(baselineEncoded) ?? {};
    let payload = baselinePayload;
    for (const operation of operationsBySheep.get(normalizedIdentifier(row.entity_id)) ?? []) {
      payload = mergeProjectionPayload(payload, payloadForRow(operation));
    }
    payload = mergeProjectionPayload(payload, payloadForRow(row));
    // Sheep projection operations are sparse deltas. Their care/profile
    // payloads can carry an old copied authority bit, but the bit belongs to
    // the migration baseline and is released only by replayed transfer or
    // removal facts. Preserve the baseline value and default new sheep to
    // non-authoritative history.
    const integers = { ...(payload.integers ?? {}) };
    for (const key of ["legacyStatusSnapshotIsAuthoritative", "legacyPenSnapshotIsAuthoritative"]) {
      if (baselineEncoded) {
        integers[key] = Number(baselinePayload?.integers?.[key] ?? 0) === 1 ? 1 : 0;
      } else {
        delete integers[key];
      }
    }
    return {
      ...row,
      payload_json: { ...payload, integers },
      payload_base64: null,
    };
  });
}

function firstPayloadValue(payload, group, ...keys) {
  const bucket = payload?.[group];
  if (!bucket || typeof bucket !== "object") return undefined;
  return keys.map((key) => bucket[key]).find((value) => value !== undefined && value !== null && value !== "");
}

function nestedPayloadValue(value, key, depth = 0) {
  if (!value || typeof value !== "object" || depth > 4) return undefined;
  if (value[key] !== undefined && value[key] !== null && value[key] !== "") return value[key];
  for (const child of Object.values(value)) {
    const found = nestedPayloadValue(child, key, depth + 1);
    if (found !== undefined) return found;
  }
  return undefined;
}

function parseNumber(value) {
  const parsed = Number.parseFloat(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function parseDate(value) {
  if (!value || value === "0001-01-01T00:00:00Z") return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function dateValue(payload, key) {
  return parseDate(
    firstPayloadValue(payload, "dates", key) ??
    firstPayloadValue(payload, "optionalDates", key),
  );
}

function dateKey(value, timeZone) {
  const date = parseDate(value) ?? new Date(value ?? Date.now());
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

function isArchivedSheep(payload) {
  const status = String(firstPayloadValue(payload, "strings", "legacyStatusRawValue") ?? "").toLowerCase();
  const historical = String(payload?.integers?.isHistoricalArchive ?? "0") === "1";
  return historical || ["removed", "deceased", "sold", "dead"].includes(status);
}

function hasHistoricalArchiveFlag(payload) {
  return String(payload?.integers?.isHistoricalArchive ?? "0") === "1";
}

function hasAuthoritativeLegacyFlag(payload, key) {
  return String(payload?.integers?.[key] ?? "0") === "1";
}

function entityDate(row, payload, fallbackKey = "occurredAt") {
  return dateValue(payload, fallbackKey)?.toISOString() ?? row?.modified_at ?? null;
}

async function fetchEntityRows(farmID, entityType, signal) {
  const rows = [];
  let offset = 0;
  while (true) {
    let query = supabase
      .from("farm_entities")
      .select(entityRowSelect)
      .eq("farm_id", farmID)
      .eq("entity_type", entityType)
      .is("deleted_at", null)
      .order("modified_at", { ascending: false })
      .order("entity_id", { ascending: false })
      .range(offset, offset + entityPageSize - 1);
    if (signal) query = query.abortSignal(signal);
    const { data, error } = await query;
    if (error) throw error;
    const page = data ?? [];
    rows.push(...page);
    if (page.length < entityPageSize) break;
    offset += entityPageSize;
  }
  return rows;
}

async function fetchOperationRows(farmID, authorityGeneration, signal) {
  const rows = [];
  let offset = 0;
  while (true) {
    let query = supabase
      .from("farm_operations")
      .select("operation_id,entity_type,entity_id,revision,occurred_at,modified_at,server_received_at,payload_base64,actor_user_id,modified_by_account_id")
      .eq("farm_id", farmID)
      .eq("authority_generation", authorityGeneration)
      .is("deleted_at", null)
      .order("revision", { ascending: false })
      .order("operation_id", { ascending: false })
      .range(offset, offset + entityPageSize - 1);
    if (signal) query = query.abortSignal(signal);
    const { data, error } = await query;
    if (error) throw error;
    const page = data ?? [];
    rows.push(...page);
    if (page.length < entityPageSize) break;
    offset += entityPageSize;
  }
  return rows;
}

async function fetchActorDirectory(operationRows, user, profile, signal) {
  const userIDs = [...new Set(operationRows.map((row) => row.actor_user_id).filter(Boolean))];
  const byUserID = new Map();
  const byAccountID = new Map();
  const currentName = profile.display_name || user.email?.split("@")[0] || "牧场成员";
  byUserID.set(normalizedIdentifier(user.id), currentName);
  if (profile.app_account_id) byAccountID.set(normalizedIdentifier(profile.app_account_id), currentName);

  if (!userIDs.length) return { byUserID, byAccountID, currentName };
  let query = supabase
    .from("profiles")
    .select("user_id,app_account_id,display_name")
    .in("user_id", userIDs);
  if (signal) query = query.abortSignal(signal);
  const { data, error } = await query;
  // Some deployments intentionally restrict profiles to the signed-in row.
  // Event projection remains usable and keeps IDs honest when that RLS policy
  // does not expose other members' display names.
  if (!error) {
    for (const actor of data ?? []) {
      const displayName = actor.display_name || `成员 ${String(actor.user_id).slice(0, 6)}`;
      if (actor.user_id) byUserID.set(normalizedIdentifier(actor.user_id), displayName);
      if (actor.app_account_id) byAccountID.set(normalizedIdentifier(actor.app_account_id), displayName);
    }
  }
  return { byUserID, byAccountID, currentName };
}

function actorNameForOperation(row, actorDirectory) {
  const userName = actorDirectory.byUserID.get(normalizedIdentifier(row.actor_user_id));
  if (userName) return userName;
  const accountName = actorDirectory.byAccountID.get(normalizedIdentifier(row.modified_by_account_id));
  if (accountName) return accountName;
  if (row.actor_user_id) return `成员 ${String(row.actor_user_id).slice(0, 6)}`;
  if (row.modified_by_account_id) return `账户 ${String(row.modified_by_account_id).slice(0, 6)}`;
  return "历史迁移";
}

async function fetchLatestCompactCheckpoint(farmID, authorityGeneration, signal) {
  let query = supabase
    .from("farm_checkpoints")
    .select("checkpoint_id,through_revision,manifest,storage_path,checkpoint_format,archive_byte_count,archive_digest")
    .eq("farm_id", farmID)
    .eq("authority_generation", authorityGeneration)
    .eq("checkpoint_format", "compact_v1")
    .order("through_revision", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (signal) query = query.abortSignal(signal);
  const { data: checkpoint, error: checkpointError } = await query;
  if (checkpointError) throw checkpointError;
  if (!checkpoint) return null;

  const { data: archive, error: archiveError } = await supabase
    .storage
    .from("farm-checkpoints")
    .download(checkpoint.storage_path);
  if (archiveError) throw archiveError;
  const baselinePackage = await decodeCompactCheckpoint(archive);
  return { checkpoint, baselinePackage };
}

function toFarm(access) {
  return {
    id: access.farm_id,
    name: "云端牧场",
    role: access.member_role,
    roleName: roleNames[access.member_role] ?? access.member_role,
    provider: access.provider,
    status: access.farm_status,
    generation: access.authority_generation,
    revision: Number(access.current_revision ?? 0),
    ownerUserID: access.owner_user_id,
  };
}

function humanSex(value) {
  const lower = String(value ?? "").toLowerCase();
  if (["female", "ewe", "母"].includes(lower)) return "母";
  if (["male", "ram", "公"].includes(lower)) return "公";
  return value || "—";
}

function entityToSheep(row, penNameByID, latestWeightBySheep, latestTransferBySheep, latestRemovalBySheep) {
  const payload = payloadForRow(row);
  const sheepKey = normalizedIdentifier(row.entity_id);
  const transfer = latestTransferBySheep.get(sheepKey);
  const removal = latestRemovalBySheep.get(sheepKey);
  const initialPenID = firstPayloadValue(payload, "optionalIdentifiers", "penID") ??
    firstPayloadValue(payload, "identifiers", "penID") ?? null;
  const snapshotPenID = firstPayloadValue(payload, "optionalIdentifiers", "legacyCurrentPenID", "penID") ??
    firstPayloadValue(payload, "identifiers", "penID") ?? transfer?.penID;
  // Native replay preserves a migrated currentPenID while the legacy pen
  // snapshot is authoritative. Only sheep whose pen authority was released
  // are reconstructed from the transfer timeline.
  const penSnapshotIsAuthoritative = hasAuthoritativeLegacyFlag(payload, "legacyPenSnapshotIsAuthoritative") && !transfer?.hasPostBaselineOperation;
  const penID = penSnapshotIsAuthoritative
    ? snapshotPenID
    : transfer?.penID ?? snapshotPenID;
  const statusRaw = String(firstPayloadValue(payload, "strings", "legacyStatusRawValue") ?? "").toLowerCase();
  const purpose = firstPayloadValue(payload, "strings", "purpose");
  const earTag = firstPayloadValue(payload, "strings", "earTag", "legacyEarTag");
  const breed = firstPayloadValue(payload, "strings", "breed");
  const sexRaw = firstPayloadValue(payload, "strings", "sex");
  const weight = latestWeightBySheep.get(sheepKey);
  const keepsLegacyStatus = hasAuthoritativeLegacyFlag(payload, "legacyStatusSnapshotIsAuthoritative") && !removal?.hasPostBaselineOperation;
  const status = keepsLegacyStatus
    ? (statusRaw || "active")
    : removal
      ? (removal.kind === "deceased" ? "deceased" : "removed")
      : "active";
  const removedAt = keepsLegacyStatus
    ? dateValue(payload, "legacyRemovedAt")?.toISOString() ?? null
    : removal?.at?.toISOString() ?? null;
  return {
    id: row.entity_id,
    penID: penID ?? null,
    initialPenID,
    currentPenID: penID ?? null,
    earTag: earTag ?? "资料未展开",
    breed: breed ?? "资料未展开",
    sex: sexRaw ? humanSex(sexRaw) : "—",
    sexRaw: sexRaw ?? "unknown",
    purpose: purpose || "未分类",
    status,
    birthAt: dateValue(payload, "birthAt")?.toISOString() ?? null,
    enteredAt: dateValue(payload, "occurredAt")?.toISOString() ?? row.modified_at,
    removedAt,
    isBreedingRam: String(firstPayloadValue(payload, "integers", "isBreedingRam") ?? "0") === "1",
    stage: purpose || statusLabels[statusRaw] || "未标注",
    pen: penNameByID.get(normalizedIdentifier(penID)) ?? "未分圈",
    weight: weight?.kilograms ?? null,
    profileIncomplete: !earTag || !breed || !sexRaw,
    updatedAt: row.modified_at,
    revision: row.revision,
  };
}

function entityToPen(row) {
  const payload = payloadForRow(row);
  const activeFlag = firstPayloadValue(payload, "integers", "isActive");
  return {
    id: row.entity_id,
    name: firstPayloadValue(payload, "strings", "name") ?? `圈舍 ${row.entity_id.slice(0, 6)}`,
    purpose: firstPayloadValue(payload, "strings", "note") || "未填写用途",
    headCount: null,
    status: String(activeFlag) === "0" ? "停用" : "正常",
    updatedAt: row.modified_at,
  };
}

function entityToFeed(row, penNameByID) {
  const payload = payloadForRow(row);
  const lines = Array.isArray(payload.feedLines) ? payload.feedLines : [];
  const kilograms = lines.reduce((sum, line) => sum + (parseNumber(line.kilogramsText) ?? 0), 0);
  const dryMatterValues = lines.map((line) => {
    const kilogramsForLine = parseNumber(line.kilogramsText) ?? 0;
    const nutrients = decodeFeedNutrients(line.nutrientSnapshotJSON, line.dryMatterTextSnapshot);
    return nutrients.dryMatter == null ? null : kilogramsForLine * nutrients.dryMatter / 100;
  });
  const dryMatter = dryMatterValues.length && dryMatterValues.every((value) => value != null)
    ? dryMatterValues.reduce((sum, value) => sum + value, 0)
    : null;
  const penID = firstPayloadValue(payload, "identifiers", "penID");
  const modeCode = firstPayloadValue(payload, "strings", "mode") || "limited";
  const remainingKilograms = parseNumber(firstPayloadValue(payload, "optionalStrings", "remainingKilogramsText"));
  const compositionPayload = decodedPayloadJSON(firstPayloadValue(payload, "optionalStrings", "remainingCompositionJSON"), []);
  let legacyRemainingComposition = Array.isArray(compositionPayload) ? compositionPayload : [];
  if (!legacyRemainingComposition.length && compositionPayload && !Array.isArray(compositionPayload) && remainingKilograms > 0) {
    const entries = Object.entries(compositionPayload).filter(([, percent]) => parseNumber(percent) > 0);
    const totalPercent = entries.reduce((sum, [, percent]) => sum + parseNumber(percent), 0);
    if (totalPercent > 0) {
      legacyRemainingComposition = entries.map(([name, percent], index) => {
        const line = lines.find((item) => String(item.ingredientNameSnapshot ?? "").localeCompare(name, "zh-CN", { sensitivity: "base" }) === 0);
        return {
          id: `${row.entity_id}:legacy-composition:${index}`,
          ingredientID: line?.ingredientID ?? null,
          ingredientBatchID: line?.ingredientBatchID ?? null,
          ingredientNameSnapshot: name,
          kilogramsText: String(remainingKilograms * parseNumber(percent) / totalPercent),
          nutrientSnapshotJSON: line?.nutrientSnapshotJSON ?? "{}",
          dryMatterTextSnapshot: line?.dryMatterTextSnapshot ?? null,
        };
      });
    }
  }
  return {
    id: row.entity_id,
    at: entityDate(row, payload),
    occurredAt: entityDate(row, payload),
    penID: penID ?? null,
    pen: penNameByID.get(normalizedIdentifier(penID)) ?? "未识别圈舍",
    meal: firstPayloadValue(payload, "strings", "mealName", "meal") || "全天",
    recipe: firstPayloadValue(payload, "optionalStrings", "recipeName") || "按原料记录",
    mode: modeCode,
    modeName: feedModeLabels[modeCode] ?? modeCode,
    feederName: firstPayloadValue(payload, "strings", "feederName") || "",
    kilograms,
    dryMatter,
    lines: lines.map((line) => ({
      id: line.id,
      ingredientID: line.ingredientID ?? null,
      ingredientBatchID: line.ingredientBatchID ?? null,
      ingredientName: line.ingredientNameSnapshot || "未知原料",
      freshKilograms: parseNumber(line.kilogramsText) ?? 0,
      pricePerKilogram: parseNumber(line.pricePerKilogramTextSnapshot),
      nutrientSnapshotJSON: line.nutrientSnapshotJSON ?? "{}",
      dryMatterTextSnapshot: line.dryMatterTextSnapshot ?? null,
      nutrients: decodeFeedNutrients(line.nutrientSnapshotJSON, line.dryMatterTextSnapshot),
    })),
    excludedSheepIDs: decodedPayloadJSON(firstPayloadValue(payload, "optionalStrings", "excludedSheepIDsJSON"), []),
    historicalHeadCountSnapshot: parseNumber(firstPayloadValue(payload, "integers", "actualHeadCountSnapshot")),
    legacyRemainingKilograms: remainingKilograms,
    legacyDiscardedKilograms: parseNumber(firstPayloadValue(payload, "optionalStrings", "discardedKilogramsText")),
    legacyRemainingComposition,
  };
}

function decodedPayloadJSON(value, fallback) {
  if (value && typeof value === "object") return value;
  if (typeof value !== "string" || !value.trim()) return fallback;
  try {
    const decoded = JSON.parse(value);
    return decoded ?? fallback;
  } catch {
    return fallback;
  }
}

function entityToTransfer(row) {
  const payload = payloadForRow(row);
  const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
  const at = entityDate(row, payload);
  if (!sheepID || !at) return null;
  return {
    id: row.entity_id,
    sheepID,
    fromPenID: firstPayloadValue(payload, "optionalIdentifiers", "fromPenID") ?? null,
    toPenID: payload?.optionalIdentifiers && Object.hasOwn(payload.optionalIdentifiers, "toPenID")
      ? payload.optionalIdentifiers.toPenID ?? null
      : firstPayloadValue(payload, "identifiers", "toPenID") ?? null,
    at,
    occurredAt: at,
    recordedAt: row.modified_at,
  };
}

function entityToRemoval(row) {
  const payload = payloadForRow(row);
  const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
  const at = entityDate(row, payload);
  if (!sheepID || !at) return null;
  return {
    id: row.entity_id,
    sheepID,
    kind: firstPayloadValue(payload, "strings", "kind") || "culled",
    at,
    occurredAt: at,
    recordedAt: row.modified_at,
  };
}

function entityToBatch(row) {
  const payload = payloadForRow(row);
  const name = firstPayloadValue(payload, "strings", "name") || `批次 ${row.entity_id.slice(0, 6)}`;
  const note = firstPayloadValue(payload, "strings", "note") || "";
  const inferred = name.includes("历史推断") || note.includes("自动推断") || note.includes("依据批量");
  const migrated = !inferred && (note.includes("自动迁移") || note.includes("已有育肥起点"));
  const startedAt = dateValue(payload, "startedAt")?.toISOString() ?? row.modified_at;
  return {
    id: row.entity_id,
    name,
    purpose: firstPayloadValue(payload, "strings", "purpose") || "未分类",
    stage: firstPayloadValue(payload, "strings", "purpose") || "未分类",
    note,
    startedAt,
    startDate: farmDayKey(startedAt, "Asia/Shanghai") ?? "—",
    source: inferred ? "historicalInference" : migrated ? "historicalMigration" : "manual",
    sheepCount: 0,
    penCount: 0,
    status: "已归档",
  };
}

function entityToBatchMembership(row) {
  const payload = payloadForRow(row);
  const batchID = firstPayloadValue(payload, "identifiers", "batchID");
  const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
  const joinedAt = dateValue(payload, "joinedAt")?.toISOString();
  if (!batchID || !sheepID || !joinedAt) return null;
  return {
    id: row.entity_id,
    batchID,
    sheepID,
    joinedAt,
    leftAt: dateValue(payload, "leftAt")?.toISOString() ?? null,
    leaveReason: firstPayloadValue(payload, "optionalStrings", "leaveReason") ?? firstPayloadValue(payload, "strings", "reason") ?? "",
  };
}

function entityToTroughObservation(row) {
  const payload = payloadForRow(row);
  const penID = firstPayloadValue(payload, "identifiers", "penID");
  const observedAt = dateValue(payload, "observedAt")?.toISOString() ?? row.modified_at;
  if (!penID || !observedAt) return null;
  const composition = decodedPayloadJSON(firstPayloadValue(payload, "optionalStrings", "compositionSnapshotJSON"), []);
  return {
    id: row.entity_id,
    penID,
    relatedFeedRecordID: firstPayloadValue(payload, "optionalIdentifiers", "relatedFeedRecordID") ?? null,
    feederName: firstPayloadValue(payload, "strings", "feederName") || "",
    observedAt,
    actualRemainingKilograms: parseNumber(firstPayloadValue(payload, "strings", "actualRemainingKilogramsText")) ?? 0,
    discardedKilograms: parseNumber(firstPayloadValue(payload, "optionalStrings", "discardedKilogramsText")) ?? 0,
    measurementMethod: firstPayloadValue(payload, "strings", "measurementMethod") || "实称",
    composition: Array.isArray(composition) ? composition : [],
  };
}

function entityToIngredient(row) {
  const payload = payloadForRow(row);
  let nutrientSnapshot = {};
  try {
    nutrientSnapshot = JSON.parse(firstPayloadValue(payload, "strings", "nutrientSnapshotJSON") || "{}");
  } catch {
    nutrientSnapshot = {};
  }
  return {
    id: row.entity_id,
    name: firstPayloadValue(payload, "strings", "name") || "未命名原料",
    category: firstPayloadValue(payload, "strings", "category") || "未分类",
    unit: firstPayloadValue(payload, "strings", "unit") || "千克",
    dryMatter: parseNumber(firstPayloadValue(payload, "optionalStrings", "dryMatterText")) ?? parseNumber(nutrientSnapshot.dryMatter),
    stock: null,
    updatedAt: row.modified_at,
  };
}

function entityToRecipe(row) {
  const payload = payloadForRow(row);
  const command = payload?.tmrCommand?.saveFormula?._0 ?? payload?.tmrCommand?.saveFormula;
  if (!command) return null;
  const components = Array.isArray(command.components) ? command.components : [];
  return {
    id: command.id || row.entity_id,
    name: command.name || "未命名配方",
    stage: command.stage || "未标注",
    totalKg: components.reduce((sum, component) => sum + (parseNumber(component.quantityText) ?? 0), 0),
    cp: null,
    me: null,
    ndf: null,
    components,
    updatedAt: row.modified_at,
  };
}

function entityToFeedingPlan(row) {
  const payload = payloadForRow(row);
  const commandValue = payload?.tmrCommand?.saveFeedingPlan ?? nestedPayloadValue(payload, "saveFeedingPlan");
  const command = commandValue?._0 ?? commandValue;
  if (!command) return null;
  return {
    id: command.id || row.entity_id,
    formulaID: command.formulaID || null,
    penCount: Array.isArray(command.pens) ? command.pens.length : 0,
    scheduleKind: command.scheduleKind || "—",
    granularity: command.granularity || "—",
    allocationMode: command.allocationMode || "—",
    morningShare: parseNumber(command.morningShareText),
    noonShare: parseNumber(command.noonShareText),
    eveningShare: parseNumber(command.eveningShareText),
    tolerancePercent: parseNumber(command.tolerancePercentText),
    monitoringEnabled: command.monitoringEnabled === true,
    effectiveStartDate: parseDate(command.effectiveStartDate),
    updatedAt: row.modified_at,
  };
}

function latestWeights(rows) {
  const result = new Map();
  for (const row of rows) {
    const payload = payloadForRow(row);
    const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
    const kilograms = parseNumber(firstPayloadValue(payload, "strings", "kilogramsText"));
    if (!sheepID || kilograms == null) continue;
    const at = parseDate(firstPayloadValue(payload, "dates", "occurredAt")) ?? parseDate(row.modified_at);
    const key = normalizedIdentifier(sheepID);
    const existing = result.get(key);
    if (!existing || (at && (!existing.at || at > existing.at))) {
      result.set(key, { kilograms, at });
    }
  }
  return result;
}

function latestTransfers(rows) {
  const result = new Map();
  for (const row of rows) {
    const payload = payloadForRow(row);
    const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
    const hasOptionalPen = payload?.optionalIdentifiers && Object.hasOwn(payload.optionalIdentifiers, "toPenID");
    const penID = hasOptionalPen
      ? payload.optionalIdentifiers.toPenID ?? null
      : firstPayloadValue(payload, "identifiers", "toPenID") ?? null;
    if (!sheepID || (!hasOptionalPen && !penID)) continue;
    const at = parseDate(firstPayloadValue(payload, "dates", "occurredAt")) ?? parseDate(row.modified_at);
    const recordedAt = parseDate(row.modified_at);
    const stableID = normalizedIdentifier(row.entity_id);
    const key = normalizedIdentifier(sheepID);
    const existing = result.get(key);
    const isLater = !existing || (() => {
      if (at && existing.at && at.getTime() !== existing.at.getTime()) return at > existing.at;
      if (at && !existing.at) return true;
      if (!at && existing.at) return false;
      if (recordedAt && existing.recordedAt && recordedAt.getTime() !== existing.recordedAt.getTime()) {
        return recordedAt > existing.recordedAt;
      }
      if (recordedAt && !existing.recordedAt) return true;
      if (!recordedAt && existing.recordedAt) return false;
      return stableID > (existing.stableID ?? "");
    })();
    if (isLater) {
      result.set(key, {
        penID,
        at,
        recordedAt,
        stableID,
        operationID: row.operation_id,
        hasPostBaselineOperation: Boolean(row.operation_id) || Boolean(existing?.hasPostBaselineOperation),
      });
    } else if (row.operation_id && existing) {
      // A later projection may be a baseline-timestamped correction. The
      // native replay still releases the legacy pen snapshot authority once
      // any post-baseline transfer exists, even when the latest occurredAt
      // belongs to an older historical transfer.
      existing.hasPostBaselineOperation = true;
    }
  }
  return result;
}

function latestRemovals(rows) {
  const result = new Map();
  for (const row of rows) {
    const payload = payloadForRow(row);
    const sheepID = firstPayloadValue(payload, "identifiers", "sheepID");
    if (!sheepID) continue;
    const at = parseDate(firstPayloadValue(payload, "dates", "occurredAt")) ?? parseDate(row.modified_at);
    const recordedAt = parseDate(row.modified_at);
    const stableID = normalizedIdentifier(row.entity_id);
    const key = normalizedIdentifier(sheepID);
    const existing = result.get(key);
    const isEarlier = !existing || (() => {
      if (at && existing.at && at.getTime() !== existing.at.getTime()) return at < existing.at;
      if (at && !existing.at) return true;
      if (!at && existing.at) return false;
      if (recordedAt && existing.recordedAt && recordedAt.getTime() !== existing.recordedAt.getTime()) {
        return recordedAt < existing.recordedAt;
      }
      if (recordedAt && !existing.recordedAt) return true;
      if (!recordedAt && existing.recordedAt) return false;
      return stableID < (existing.stableID ?? "");
    })();
    if (isEarlier) {
      result.set(key, {
        at,
        recordedAt,
        stableID,
        kind: firstPayloadValue(payload, "strings", "kind") || "removed",
        hasPostBaselineOperation: Boolean(row.operation_id) || Boolean(existing?.hasPostBaselineOperation),
      });
    } else if (row.operation_id && existing) {
      existing.hasPostBaselineOperation = true;
    }
  }
  return result;
}

export async function getVerifiedUser() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    if (error.name === "AuthSessionMissingError") return null;
    throw error;
  }
  return data.user ?? null;
}

export async function getAssistantAccessToken() {
  if (!supabase) throw new Error("Supabase 尚未配置。");
  const user = await getVerifiedUser();
  if (!user) throw new Error("请先登录 Supabase 账号。");
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  if (!data.session?.access_token || data.session.user?.id !== user.id) {
    throw new Error("登录状态已失效，请重新登录。");
  }
  return data.session.access_token;
}

export function watchAuth(callback) {
  if (!supabase) return () => {};
  const { data } = supabase.auth.onAuthStateChange((event, session) => {
    callback({ event, session });
  });
  return () => data.subscription.unsubscribe();
}

export async function signInWithPassword(email, password) {
  if (!supabase) throw new Error("Supabase 尚未配置。");
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim().toLowerCase(),
    password,
  });
  if (error) throw error;
  return data.user;
}

export async function signUpWithPassword({ displayName, email, password }) {
  if (!supabase) throw new Error("Supabase 尚未配置。");
  const normalizedEmail = email.trim().toLowerCase();
  const normalizedDisplayName = displayName.trim();
  const redirectTo = `${window.location.origin}${window.location.pathname}`;
  const { data, error } = await supabase.auth.signUp({
    email: normalizedEmail,
    password,
    options: {
      emailRedirectTo: redirectTo,
      data: { display_name: normalizedDisplayName },
    },
  });
  if (error) throw error;
  if (data.session && data.user && normalizedDisplayName) {
    const { error: profileError } = await supabase
      .from("profiles")
      .update({ display_name: normalizedDisplayName, updated_at: new Date().toISOString() })
      .eq("user_id", data.user.id);
    if (profileError) throw profileError;
  }
  return { user: data.user ?? null, verificationRequired: !data.session };
}

export async function redeemFarmInvite(code) {
  if (!supabase) throw new Error("Supabase 尚未配置。");
  const normalizedCode = code.trim();
  if (!normalizedCode) throw new Error("请输入牧场邀请码。");
  const { data, error } = await supabase.rpc("redeem_farm_invite", { p_code: normalizedCode });
  if (error) {
    if (/farm_invite_invalid_or_expired/i.test(error.message || "")) throw new Error("邀请码无效、已使用或已过期，请联系场主重新生成。");
    if (/farm_authority_not_available/i.test(error.message || "")) throw new Error("该牧场的云端服务当前不可用，请联系场主。");
    throw error;
  }
  const redemption = data?.[0];
  if (!redemption?.farm_id) throw new Error("邀请码已处理，但没有返回可访问的牧场。");
  return redemption;
}

export async function signInWithApple() {
  if (!supabase) throw new Error("Supabase 尚未配置。");

  const redirectTo = `${window.location.origin}${window.location.pathname}`;
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: "apple",
    options: { redirectTo },
  });
  if (error) throw error;
  return data;
}

export async function signOut() {
  if (!supabase) return;
  const { error } = await supabase.auth.signOut({ scope: "local" });
  if (error) throw error;
}

export async function loadCloudWorkspace(preferredFarmID, { signal, sections } = {}) {
  if (!supabase) throw new Error("Supabase 尚未配置。");
  signal?.throwIfAborted();

  const loadedSections = normalizeWorkspaceSections(sections);
  const requestedEntityTypes = new Set(
    workspaceEntityTypesForSections(loadedSections),
  );

  const user = await getVerifiedUser();
  if (!user) throw new Error("请先登录 Supabase 账号。");

  let accessQuery = supabase.rpc("list_my_active_farm_access");
  let profileQuery = supabase
    .from("profiles")
    .select("app_account_id,display_name")
    .eq("user_id", user.id)
    .single();
  if (signal) {
    accessQuery = accessQuery.abortSignal(signal);
    profileQuery = profileQuery.abortSignal(signal);
  }
  const [{ data: accessRows, error: accessError }, { data: profile, error: profileError }] = await Promise.all([
    accessQuery,
    profileQuery,
  ]);
  if (accessError) throw accessError;
  if (profileError) throw profileError;
  if (!accessRows?.length) {
    const error = new Error("当前账号尚未加入任何云端牧场。");
    error.code = NO_FARM_ACCESS_CODE;
    throw error;
  }

  const farms = accessRows.map(toFarm);
  const farm = farms.find((item) => item.id === preferredFarmID) ?? farms[0];

  const checkpointPromise = fetchLatestCompactCheckpoint(farm.id, farm.generation, signal)
    .then((result) => ({ result, error: null }))
    .catch((error) => ({ result: null, error }));

  const fetchRequestedEntity = (entityType) => requestedEntityTypes.has(entityType)
    ? fetchEntityRows(farm.id, entityType, signal)
    : Promise.resolve([]);

  const [
    farmRows,
    penRows,
    sheepRows,
    feedRows,
    weightRows,
    transferRows,
    removalRows,
    ingredientRows,
    formulaRows,
    feedingPlanRows,
    weaningRows,
    reproductionRows,
    productionBatchRows,
    batchMembershipRows,
    troughObservationRows,
    operationRows,
  ] = await Promise.all([
    fetchRequestedEntity("farm"),
    fetchRequestedEntity("pen"),
    fetchRequestedEntity("sheep"),
    fetchRequestedEntity("feed"),
    fetchRequestedEntity("weight"),
    fetchRequestedEntity("transfer"),
    fetchRequestedEntity("removal"),
    fetchRequestedEntity("feedIngredient"),
    fetchRequestedEntity("tmrFormula"),
    fetchRequestedEntity("tmrFeedingPlan"),
    fetchRequestedEntity("weaning"),
    fetchRequestedEntity("reproduction"),
    fetchRequestedEntity("productionBatch"),
    fetchRequestedEntity("batchMembership"),
    fetchRequestedEntity("feedTroughObservation"),
    fetchOperationRows(farm.id, farm.generation, signal),
  ]);
  signal?.throwIfAborted();

  const checkpointResult = await checkpointPromise;
  const baselinePackage = checkpointResult.result?.baselinePackage ?? null;
  const baselinePayloads = baselineProjectionPayloads(baselinePackage);
  const expandRows = (rows) => expandRowsFromBaseline(rows, baselinePayloads);
  const expandedFarmRows = expandRows(farmRows);
  const expandedPenRows = expandRows(penRows);
  const expandedSheepRows = expandSheepRowsFromHistory(sheepRows, baselinePayloads, operationRows);
  const expandedFeedRows = expandRows(feedRows);
  const expandedWeightRows = expandRows(weightRows);
  const expandedTransferRows = expandRows(transferRows);
  const expandedRemovalRows = expandRows(removalRows);
  const expandedIngredientRows = expandRows(ingredientRows);
  const expandedFormulaRows = expandRows(formulaRows);
  const expandedFeedingPlanRows = expandRows(feedingPlanRows);
  const expandedWeaningRows = expandRows(weaningRows);
  const expandedReproductionRows = expandRows(reproductionRows);
  const expandedProductionBatchRows = expandRows(productionBatchRows);
  const expandedBatchMembershipRows = expandRows(batchMembershipRows);
  const expandedTroughObservationRows = expandRows(troughObservationRows);

  const pens = expandedPenRows.map(entityToPen);
  const penNameByID = new Map(pens.map((pen) => [normalizedIdentifier(pen.id), pen.name]));
  const farmPayload = payloadForRow(expandedFarmRows[0]);
  const resolvedFarmName = firstPayloadValue(farmPayload, "strings", "displayName", "name") ?? "云端牧场";
  const farmTimeZone = firstPayloadValue(farmPayload, "strings", "timeZoneIdentifier") || "Asia/Shanghai";
  farm.name = resolvedFarmName;
  farm.timeZoneIdentifier = farmTimeZone;

  const latestWeightBySheep = latestWeights(expandedWeightRows);
  const latestTransferBySheep = latestTransfers(expandedTransferRows);
  const latestRemovalBySheep = latestRemovals(expandedRemovalRows);
  const activeSheepRows = expandedSheepRows.filter((row) => {
    const key = normalizedIdentifier(row.entity_id);
    const payload = payloadForRow(row);
    const removal = latestRemovalBySheep.get(key);
    if (hasHistoricalArchiveFlag(payload)) return false;
    if (hasAuthoritativeLegacyFlag(payload, "legacyStatusSnapshotIsAuthoritative")) {
      // A post-baseline removal releases the native snapshot authority. A
      // baseline removal alone must not overwrite an authoritative migration
      // status, matching FarmHistoryRebuilder.rebuildProjection.
      return !isArchivedSheep(payload) && !removal?.hasPostBaselineOperation;
    }
    // Once status authority is released, every live removal fact participates
    // in replay, including historical rows restored by the compact baseline.
    return !removal;
  });
  const allSheep = expandedSheepRows.map((row) => entityToSheep(
    row,
    penNameByID,
    latestWeightBySheep,
    latestTransferBySheep,
    latestRemovalBySheep,
  ));
  const allSheepByID = new Map(allSheep.map((item) => [normalizedIdentifier(item.id), item]));
  const activeSheepIDs = new Set(activeSheepRows.map((row) => normalizedIdentifier(row.entity_id)));
  const sheep = allSheep.filter((item) => activeSheepIDs.has(normalizedIdentifier(item.id)));

  const sheepCountByPenID = countByNormalizedIdentifier(sheep, (item) => item.penID);
  const pensWithCounts = pens.map((pen) => ({
    ...pen,
    headCount: sheepCountByPenID.get(normalizedIdentifier(pen.id)) ?? 0,
  }));
  const occupiedPenCount = pensWithCounts.filter((pen) => pen.headCount > 0).length;
  const feedRecords = expandedFeedRows
    .map((row) => entityToFeed(row, penNameByID))
    .sort((left, right) => new Date(right.at).getTime() - new Date(left.at).getTime());
  const todayKey = dateKey(new Date(), farmTimeZone);
  const feedsToday = feedRecords.filter((record) => dateKey(record.at, farmTimeZone) === todayKey).length;
  const weightRecords = expandedWeightRows
    .map((row) => projectionToWeightRecord(row, payloadForRow(row)))
    .filter(Boolean);
  const weaningRecords = expandedWeaningRows
    .map((row) => projectionToWeaningRecord(row, payloadForRow(row)))
    .filter(Boolean);
  const reproductionRecords = expandedReproductionRows
    .map((row) => projectionToReproductionRecord(row, payloadForRow(row)))
    .filter(Boolean)
    .map((record) => ({
      ...record,
      eweEarTag: allSheepByID.get(normalizedIdentifier(record.eweID))?.earTag ?? null,
      sireEarTag: allSheepByID.get(normalizedIdentifier(record.sireID))?.earTag ?? null,
    }));
  const transferRecords = expandedTransferRows.map(entityToTransfer).filter(Boolean);
  const removalRecords = expandedRemovalRows.map(entityToRemoval).filter(Boolean);
  const batchMemberships = expandedBatchMembershipRows.map(entityToBatchMembership).filter(Boolean);
  const troughObservations = expandedTroughObservationRows.map(entityToTroughObservation).filter(Boolean);
  const rawBatches = expandedProductionBatchRows.map(entityToBatch);
  const membershipsByBatch = new Map();
  for (const membership of batchMemberships) {
    const key = normalizedIdentifier(membership.batchID);
    const list = membershipsByBatch.get(key) ?? [];
    list.push(membership);
    membershipsByBatch.set(key, list);
  }
  const batches = rawBatches.map((batch) => {
    const memberships = membershipsByBatch.get(normalizedIdentifier(batch.id)) ?? [];
    const openMemberships = memberships.filter((membership) => !membership.leftAt);
    const penIDs = new Set(openMemberships.map((membership) => allSheepByID.get(normalizedIdentifier(membership.sheepID))?.penID).filter(Boolean).map(normalizedIdentifier));
    return {
      ...batch,
      sheepCount: openMemberships.length,
      penCount: penIDs.size,
      status: openMemberships.length ? "进行中" : "已结束",
    };
  });
  const batchNameByID = new Map(batches.map((batch) => [normalizedIdentifier(batch.id), batch.name]));
  const membershipByID = new Map(batchMemberships.map((membership) => [normalizedIdentifier(membership.id), membership]));
  const ingredients = expandedIngredientRows.map(entityToIngredient);
  const recipes = uniqueByNormalizedIdentifier(
    expandedFormulaRows.map(entityToRecipe).filter(Boolean),
    (recipe) => recipe.id,
  );
  const tmrPlan = expandedFeedingPlanRows
    .map(entityToFeedingPlan)
    .filter(Boolean)
    .sort((left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime())[0] ?? null;
  if (tmrPlan) {
    tmrPlan.formulaName = recipes.find((recipe) => normalizedIdentifier(recipe.id) === normalizedIdentifier(tmrPlan.formulaID))?.name ?? "未命名配方";
  }
  const tmrMeals = [];
  const actorDirectory = await fetchActorDirectory(operationRows, user, profile, signal);
  signal?.throwIfAborted();
  const decodedOperationRows = operationRows.map((row) => ({ ...row, payload_json: payloadForRow(row) }));
  const sheepIDByEntityID = buildEventSheepIndex(decodedOperationRows);
  const events = decodedOperationRows
    .map((row) => projectFarmOperationEvent({
      row,
      payload: row.payload_json,
      actorName: actorNameForOperation(row, actorDirectory),
      sheepByID: allSheepByID,
      penNameByID,
      sheepIDByEntityID,
      batchNameByID,
      membershipByID,
    }))
    .sort((left, right) => new Date(right.at).getTime() - new Date(left.at).getTime() || right.revision - left.revision);
  const analyticsSource = {
    sheep: allSheep.map((item) => ({
      id: item.id,
      earTag: item.earTag,
      breed: item.breed,
      purpose: item.purpose,
      sex: item.sexRaw,
      status: item.status,
      initialPenID: item.initialPenID,
      currentPenID: item.currentPenID,
      birthAt: item.birthAt,
      enteredAt: item.enteredAt,
      removedAt: item.removedAt,
      isBreedingRam: item.isBreedingRam,
    })),
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
    dailyPenCounts: [],
  };
  const insightData = buildFarmInsightData({ source: analyticsSource, timeZone: farmTimeZone });

  return {
    mode: "cloud",
    loadedSections,
    projectionCoverage: {
      real: [...requestedEntityTypes, "farm_operations"],
      preview: ["alerts", "tmrMeals", "tmrMonitoring"],
      baseline: baselinePackage
        ? {
            status: "loaded",
            throughRevision: Number(baselinePackage.manifest?.frozenOperationSequence ?? 0),
            projectionCount: Number(baselinePackage.manifest?.projectionCount ?? baselinePackage.projections?.length ?? 0),
          }
        : {
            status: "unavailable",
            reason: checkpointResult.error?.message || "云端没有可读取的紧凑基线。",
          },
      incompleteSheep: sheep.filter((item) => item.profileIncomplete).length,
      occupiedPens: occupiedPenCount,
      totalPens: pensWithCounts.length,
    },
    farm,
    farms,
    profile: {
      accountID: profile.app_account_id,
      displayName: profile.display_name || user.email?.split("@")[0] || "牧场成员",
      email: user.email,
    },
    weather: null,
    metrics: {
      activeSheep: sheep.length,
      activePens: occupiedPenCount,
      feedsToday,
    },
    alerts: [],
    events,
    sheep,
    pens: pensWithCounts,
    feedRecords,
    ingredients,
    recipes,
    tmrMeals,
    tmrPlan,
    batches,
    careItems: [],
    analyticsSource,
    insightData,
    lastSyncedAt: new Date().toISOString(),
  };
}
