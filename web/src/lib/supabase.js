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
        headers: { "x-client-info": "esheepnext-web/0.1" },
      },
    }))
  : null;

const roleNames = {
  owner: "所有者",
  administrator: "管理员",
  worker: "成员",
};

const eventLabels = {
  sheep: "羊只资料更新",
  pen: "圈舍资料更新",
  weight: "称重记录",
  transfer: "转群记录",
  removal: "离场记录",
  weaning: "断奶记录",
  reproduction: "繁殖记录",
  feed: "投喂记录",
  health: "健康记录",
  note: "备注记录",
  tmrFormula: "TMR 配方更新",
  tmrFeedingPlan: "TMR 计划更新",
  tmrBatch: "TMR 批次更新",
  tmrMealCompletion: "TMR 顿次完成",
  tmrDeviationAcknowledgement: "TMR 偏差确认",
};

const eventIconTypes = {
  weight: "weight",
  transfer: "transfer",
  health: "health",
  reproduction: "reproduction",
  feed: "feed",
  tmrFormula: "tmr",
  tmrFeedingPlan: "tmr",
  tmrBatch: "tmr",
  tmrMealCompletion: "tmr",
  saveFeedIngredient: "feed",
  addIngredient: "feed",
};

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

const eventKindLabels = {
  addSheep: "新建羊只",
  updateSheepProfile: "羊只资料更新",
  recordWeight: "称重记录",
  transferSheep: "转群记录",
  removeSheep: "离场记录",
  recordFeed: "投喂记录",
  recordHealth: "健康记录",
  recordReproduction: "繁殖记录",
  recordWeaning: "断奶记录",
  saveFeedIngredient: "原料更新",
  addIngredient: "新建原料",
  saveTMRFormula: "TMR 配方更新",
  saveTMRFeedingPlan: "TMR 计划更新",
  care: "照护记录",
  addNote: "备注记录",
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
      .select("operation_id,entity_type,entity_id,revision,occurred_at,modified_at,server_received_at,payload_base64")
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

function entityToSheep(row, penNameByID, latestWeightBySheep, latestTransferBySheep) {
  const payload = payloadForRow(row);
  const sheepKey = normalizedIdentifier(row.entity_id);
  const transfer = latestTransferBySheep.get(sheepKey);
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
  const sex = firstPayloadValue(payload, "strings", "sex");
  const weight = latestWeightBySheep.get(sheepKey);
  return {
    id: row.entity_id,
    penID: penID ?? null,
    earTag: earTag ?? "资料未展开",
    breed: breed ?? "资料未展开",
    sex: sex ? humanSex(sex) : "—",
    stage: purpose || statusLabels[statusRaw] || "未标注",
    pen: penNameByID.get(normalizedIdentifier(penID)) ?? "未分圈",
    weight: weight?.kilograms ?? null,
    profileIncomplete: !earTag || !breed || !sex,
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
  const dryMatter = lines.reduce((sum, line) => {
    const kilogramsForLine = parseNumber(line.kilogramsText) ?? 0;
    const dryMatterPercent = parseNumber(line.dryMatterTextSnapshot);
    return sum + (dryMatterPercent == null ? 0 : kilogramsForLine * dryMatterPercent / 100);
  }, 0);
  const penID = firstPayloadValue(payload, "identifiers", "penID");
  return {
    id: row.entity_id,
    at: entityDate(row, payload),
    pen: penNameByID.get(normalizedIdentifier(penID)) ?? "未识别圈舍",
    meal: firstPayloadValue(payload, "strings", "mealName", "meal") || "全天",
    recipe: firstPayloadValue(payload, "optionalStrings", "recipeName") || "按原料记录",
    mode: feedModeLabels[firstPayloadValue(payload, "strings", "mode")] ?? (firstPayloadValue(payload, "strings", "mode") || "投喂"),
    kilograms,
    dryMatter: dryMatter > 0 ? dryMatter : null,
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
    const penID = firstPayloadValue(payload, "optionalIdentifiers", "toPenID");
    if (!sheepID || !penID) continue;
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

function entityToEvent(row, actorName, sheepByID, penNameByID) {
  const entityType = row.entity_type;
  const payload = payloadForRow(row);
  const kind = payload.kind;
  const sheepID = firstPayloadValue(payload, "identifiers", "sheepID") ?? nestedPayloadValue(payload, "sheepID");
  const penID = firstPayloadValue(payload, "optionalIdentifiers", "toPenID", "penID") ?? firstPayloadValue(payload, "identifiers", "penID") ?? nestedPayloadValue(payload, "penID");
  const sheep = sheepByID.get(normalizedIdentifier(sheepID));
  const penName = penNameByID.get(normalizedIdentifier(penID));
  const formulaName = payload?.tmrCommand?.saveFormula?._0?.name ?? payload?.tmrCommand?.saveFormula?.name;
  const ingredientName = firstPayloadValue(payload, "strings", "name");
  return {
    id: row.operation_id,
    at: row.occurred_at ?? row.modified_at ?? row.server_received_at,
    type: eventIconTypes[kind] ?? eventIconTypes[entityType] ?? "note",
    label: eventKindLabels[kind] ?? eventLabels[entityType] ?? `${entityType} 记录`,
    object: sheep
      ? `羊只 ${sheep.earTag}`
      : penName
        ? penName
        : formulaName
          ? `配方 ${formulaName}`
          : ingredientName && ["feedIngredient"].includes(entityType)
            ? `原料 ${ingredientName}`
            : entityType === "tmrFeedingPlan"
              ? "TMR 计划"
              : `对象 ${row.entity_id.slice(0, 8)}`,
    actor: actorName || "牧场成员",
    status: "synced",
    revision: Number(row.revision),
  };
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
  if (!accessRows?.length) throw new Error("当前账号没有可访问的牧场。");

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
  const sheep = activeSheepRows.map((row) => entityToSheep(row, penNameByID, latestWeightBySheep, latestTransferBySheep));
  const sheepByID = new Map(sheep.map((item) => [normalizedIdentifier(item.id), item]));

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
  const recentWeightCutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
  const recentWeightCount = expandedWeightRows.filter((row) => {
    const at = dateValue(payloadForRow(row), "occurredAt") ?? parseDate(row.modified_at);
    return at && at.getTime() >= recentWeightCutoff;
  }).length;
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
  const events = operationRows.map((row) => entityToEvent(row, profile.display_name, sheepByID, penNameByID));

  return {
    mode: "cloud",
    loadedSections,
    projectionCoverage: {
      real: [...requestedEntityTypes, "farm_operations"],
      preview: ["alerts", "tmrMeals", "tmrMonitoring", "insights"],
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
    insightData: {
      recentWeightCount,
      feedKilogramsToday: feedRecords
        .filter((record) => dateKey(record.at, farmTimeZone) === todayKey)
        .reduce((sum, record) => sum + record.kilograms, 0),
    },
    lastSyncedAt: new Date().toISOString(),
  };
}
