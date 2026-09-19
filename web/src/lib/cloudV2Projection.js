import { decimalRound } from "./decimal.js";
import checkpointSchema from "../../../tools/esheep_cloud_checkpoint_schema_v1.json" with { type: "json" };

// The checkpoint's field types come from the same closed registry as the
// native importer. Checkpoint Date values use Apple's 2001 epoch; command
// Date values use Unix milliseconds. Never guess one from its magnitude.
const appleEpochMilliseconds = 978307200000;
const normalizeID = (id) => id == null ? null : String(id).toLowerCase();
const entityModels = {
  sheepLabel: "SheepLabelRecord", sheepLabels: "SheepLabelAssignmentRecord",
  farm: "FarmRecord", pen: "PenRecord", sheep: "SheepRecord", weight: "WeightRecord",
  weaning: "WeaningRecord", transfer: "TransferRecord", removal: "RemovalRecord",
  reproduction: "ReproductionRecord", feed: "FeedRecord", feedIngredient: "FeedIngredientRecord",
  productionBatch: "ProductionBatchRecord", batchMembership: "BatchMembershipRecord",
  feedTroughObservation: "FeedTroughObservationRecord", note: "NoteRecord",
  photoAsset: "PhotoAssetRecord",
  health: "HealthRecord", healthCatalogItem: "HealthCatalogItemRecord", inventoryLot: "InventoryLotRecord",
  inventoryTransaction: "InventoryTransactionRecord", semen: "SemenRecord", semenDonor: "SemenDonorRecord",
  semenTransaction: "SemenTransactionRecord", feedIngredientBatch: "FeedIngredientBatchRecord",
  feedStockTransaction: "FeedStockTransactionRecord", tmrBatch: "TMRBatchRecord",
};
const modelEntities = Object.fromEntries(Object.entries(entityModels).map(([entity, model]) => [model, entity]));
export const webCheckpointModels = new Set([
  ...Object.values(entityModels), "FeedRecordLine", "FeedRecipeRecord", "FeedRecipeComponentRecord",
  "TMRFormulaProfileRecord", "TMRFeedingPlanRecord", "TMRFeedingPlanPenRecord", "LambingOffspringRecord",
  "DomainOperation", "TombstoneRecord", "SheepLabelChangeRecord",
  "HealthSubjectLink", "CareBatchRecord", "CareReminderRecord", "FarmCareRuleRecord", "FarmAlertDeferralRecord",
  "BreedingProgramRecord", "BreedingProgramStepRecord", "PedigreeChangeRecord", "SheepAvatarRecord",
  "FeedStockCountRecord", "TMRBatchIngredientRecord", "TMRBatchLoadLineRecord", "TMRBatchMovementRecord",
  "TMRDeviationAcknowledgementRecord", "TMRFeedingAllocationRecord", "TMRFeedingRunRecord",
  "TMRMealCompletionRecord", "TMRMonitoringRuleRecord", "ESheepCloudStreamState",
]);

function invalid(detail = "") {
  const error = new Error(`牧场资料核对未通过，请刷新重试。${detail}`);
  error.code = "CLOUD_V2_INTEGRITY";
  return error;
}

function unsupported(kind) {
  const error = new Error(`牧场成员权限有效，但网页版需要更新才能读取新的业务记录（${kind}）。`);
  error.code = "CLOUD_V2_UPDATE_REQUIRED";
  return error;
}

export function decodeCheckpointValues(model, values) {
  const fields = checkpointSchema[model]?.fields;
  if (!fields || !values || typeof values !== "object") throw invalid();
  const decoded = {};
  for (const [key, value] of Object.entries(values)) {
    const type = fields[key];
    if (!type) throw invalid(`未知字段：${model}.${key}`);
    if (value == null) {
      if (!type.endsWith("?")) throw invalid();
      decoded[key] = null;
    } else if (type === "Date" || type === "Date?") {
      if (typeof value !== "number" || !Number.isFinite(value)) throw invalid();
      decoded[key] = value * 1000 + appleEpochMilliseconds;
    } else if (type === "UUID" || type === "UUID?") {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw invalid();
      decoded[key] = normalizeID(value);
    } else {
      decoded[key] = value;
    }
  }
  for (const [key, type] of Object.entries(fields)) {
    if (!type.endsWith("?") && !Object.hasOwn(decoded, key)) throw invalid(`缺少字段：${model}.${key}`);
  }
  return decoded;
}

export function createV2Projection(records, manifest) {
  const models = new Map([...webCheckpointModels].map((name) => [name, new Map()]));
  const farmID = normalizeID(manifest.farmID);
  for (const record of records) {
    if (!webCheckpointModels.has(record.model)) continue;
    const value = decodeCheckpointValues(record.model, record.values);
    if ((record.model === "FarmRecord" ? value.id : value.farmID) !== farmID) throw invalid("牧场标识不匹配。");
    const table = models.get(record.model);
    if (table.has(value.id)) throw invalid("发现重复记录。");
    table.set(value.id, value);
  }
  for (const [model, rows] of models) {
    if (rows.size !== (manifest.modelCounts[model] ?? 0)) throw invalid(`记录数量不匹配：${model}`);
  }
  if (models.get("FarmRecord").size !== 1) throw invalid();
  return { models, farmID, manifest, seenCommands: new Map(), tailOperations: [], changedSheep: new Set() };
}

function table(projection, model) { return projection.models.get(model); }
function rows(projection, model, includeDeleted = false) {
  return [...(table(projection, model)?.values() ?? [])].filter((row) => includeDeleted || row.deletedAt == null);
}
function get(projection, model, id, allowDeleted = false) {
  const row = table(projection, model)?.get(normalizeID(id));
  if (!row || (!allowDeleted && row.deletedAt != null)) throw invalid(`未找到关联记录：${model}`);
  return row;
}
function insert(projection, model, row) {
  const target = table(projection, model);
  row.id = normalizeID(row.id);
  if (!target || !row.id || target.has(row.id)) throw invalid("发现重复业务记录。");
  target.set(row.id, row);
  return row;
}
function releaseHistory(projection, sheepID) {
  const sheep = get(projection, "SheepRecord", sheepID);
  sheep.legacyStatusSnapshotIsAuthoritative = false;
  sheep.legacyPenSnapshotIsAuthoritative = false;
  projection.changedSheep.add(sheep.id);
  return sheep;
}

function commandArguments(body, expected) {
  const container = body.command_payload?.body;
  if (!container || !Object.hasOwn(container, expected)) throw invalid();
  return container[expected]?._0 && typeof container[expected]._0 === "object"
    ? container[expected]._0 : container[expected];
}
function primaryID(body, type) {
  const streams = body.affected_streams?.filter((stream) => stream.type === type);
  if (streams?.length !== 1 || !streams[0].id) throw invalid("业务记录标识不完整。");
  return normalizeID(streams[0].id);
}
function normalizeCommandValues(values) {
  return Object.fromEntries(Object.entries(values).map(([key, value]) => [key,
    /ID$/.test(key) && typeof value === "string" ? normalizeID(value) : value,
  ]));
}
function valueFromPatch(value) {
  if (!value || !["null", "string", "integer", "decimal", "boolean", "date", "identifier"].includes(value.type)) throw invalid();
  if (value.type === "null") return null;
  if (value.type === "identifier") return normalizeID(value.value);
  return value.value;
}

const patchFields = {
  farm: {
    name: "name", displayName: "locationDisplayName", latitude: "latitude", longitude: "longitude",
    addressSnapshot: "addressSnapshot", timeZoneIdentifier: "timeZoneIdentifier",
    locationSource: "locationSourceRawValue", horizontalAccuracyMeters: "horizontalAccuracyMeters",
  },
  pen: { name: "name", note: "note", isActive: "isActive" },
  sheepProfile: {
    earTag: "earTag", breed: "breed", sex: "sexRawValue", birthAt: "birthAt", note: "note",
    purpose: "purpose", isBreedingRam: "isBreedingRam", isHistoricalArchive: "isHistoricalArchive",
  },
};

function applyFieldPatch(projection, event, changes) {
  if (!Array.isArray(changes) || changes.length === 0) throw invalid();
  if (event.stream_type === "sheepAvatar") {
    // The Web has no photo/selection projection. A verified avatar-only
    // change does not affect any of its business read models.
    if (changes.some((change) => change.field !== "avatar")) throw unsupported("sheepAvatar");
    return;
  }
  const model = { farm: "FarmRecord", pen: "PenRecord", sheepProfile: "SheepRecord" }[event.stream_type];
  if (!model) throw unsupported(event.stream_type);
  const row = get(projection, model, event.stream_id);
  const stateTable=projection.models.get("ESheepCloudStreamState");
  let state=[...stateTable.values()].find(s=>s.streamType===event.stream_type&&s.streamID===event.stream_id.toLowerCase());
  if(!state){state={id:event.event_id,farmID:projection.farmID,streamType:event.stream_type,streamID:event.stream_id.toLowerCase(),fieldVersionsData:btoa("[]")};stateTable.set(state.id,state);}
  const versions=JSON.parse(atob(state.fieldVersionsData??btoa("[]")));
  for(const change of changes){const entry={field:change.field,version:change.field_version,valueDigest:change.value_digest,value:change.value};const i=versions.findIndex(v=>v.field===change.field);if(i<0)versions.push(entry);else versions[i]=entry;}
  state.fieldVersionsData=btoa(unescape(encodeURIComponent(JSON.stringify(versions))));

  for (const change of changes) {
    const field = patchFields[event.stream_type][change.field];
    if (!field) throw unsupported(`${event.stream_type}.${change.field}`);
    row[field] = valueFromPatch(change.value);
  }
  row.updatedAt = event.received_at_millis;
  if (model === "SheepRecord") {
    if (row.sexRawValue !== "ram") row.isBreedingRam = false;
    projection.changedSheep.add(row.id);
  }
}

function compareFacts(a, b) {
  return a.occurredAt - b.occurredAt || (a.recordedAt ?? a.createdAt) - (b.recordedAt ?? b.createdAt) || a.id.localeCompare(b.id);
}

function penAt(projection, sheep, instant) {
  if (sheep.enteredAt > instant) return null;
  const transfers = rows(projection, "TransferRecord").filter((row) => row.sheepID === sheep.id && row.occurredAt <= instant).sort(compareFacts);
  // Mirrors FarmHistoryTimeline.pen, including its initial-pen fallback.
  return transfers.at(-1)?.toPenID ?? sheep.initialPenID ?? null;
}

const factRoutes = {
  "weight.record": ["WeightRecord", "recordWeight"], "weight.correct": ["WeightRecord", "correctWeight"],
  "weaning.record": ["WeaningRecord", "recordWeaning"],
  "transfer.record": ["TransferRecord", "transferSheep"], "transfer.correct": ["TransferRecord", "correctTransfer"],
  "removal.record": ["RemovalRecord", "removeSheep"], "removal.correct": ["RemovalRecord", "correctRemoval"],
  "note.add": ["NoteRecord", "addNote"],
};

function addOperation(projection, event, entityType, entityID, payload) {
  projection.tailOperations.push({
    operation_id: event.command_id, entity_type: entityType, entity_id: entityID,
    revision: event.event_sequence, occurred_at: new Date(event.occurred_at_millis).toISOString(),
    modified_at: new Date(event.received_at_millis).toISOString(),
    modified_by_account_id: event.actor_account_id, payload_json: payload,
  });
}

export function applyV2Event(projection, event, body) {
  const kind = body.command_kind;
  if (event.event_kind === "fields_patched") {
    applyFieldPatch(projection, event, body.changes);
    return;
  }
  if (event.event_kind === "attention_resolved") {
    if (body.choice === "use_this_device") {
      applyFieldPatch(projection, event, [{ field: body.field, value: body.chosen_value }]);
    } else if (!["keep_cloud", "abandon_operation", "resubmit"].includes(body.choice)) throw unsupported(event.event_kind);
    return;
  }
  if (!["append_fact", "state_machine", "or_set", "lifecycle", "ledger"].includes(event.event_kind) ||
      kind !== body.command_payload?.kind) throw unsupported(kind ?? event.event_kind);
  const commandID = normalizeID(event.command_id);
  const priorDigest = projection.seenCommands.get(commandID);
  if (priorDigest) {
    if (priorDigest !== event.source_command_digest) throw invalid("命令内容不一致。");
    return;
  }
  projection.seenCommands.set(commandID, event.source_command_digest);
  const metadata = {
    farmID: projection.farmID, createdAt: event.received_at_millis, updatedAt: event.received_at_millis,
    recordedAt: event.received_at_millis, deletedAt: null, revision: 1,
  };

  if (factRoutes[kind]) {
    const [model, command] = factRoutes[kind];
    const args = normalizeCommandValues(commandArguments(body, command));
    const entityType = modelEntities[model];
    const id = primaryID(body, entityType);
    let original;
    if (kind.endsWith(".correct")) {
      original = get(projection, model, args.originalID);
      original.deletedAt = event.received_at_millis;
      args.sheepID = original.sheepID;
    }
    const row = { ...metadata, ...args, id };
    if(model==="WeightRecord")row.kilogramsText=decimalRound(row.kilogramsText,2);
    if (!Number.isFinite(row.occurredAt)) throw invalid();
    if (row.sheepID) get(projection, "SheepRecord", row.sheepID);
    if (model === "RemovalRecord") {
      row.kindRawValue = args.kind;
      releaseHistory(projection, row.sheepID);
    }
    if (model === "TransferRecord") {
      const sheep = releaseHistory(projection, row.sheepID);
      row.fromPenID = penAt(projection, sheep, row.occurredAt);
      if (row.toPenID) get(projection, "PenRecord", row.toPenID);
    }
    if (model === "WeaningRecord") projection.changedSheep.add(row.sheepID);
    const existing = table(projection, model).get(id);
    if (model === "RemovalRecord" && existing?.deletedAt != null) Object.assign(existing, row);
    else insert(projection, model, row);
    addOperation(projection, event, entityType, id, { ...recordPayload(model, row), kind: command });
    return;
  }
  if (kind === "removal.restore") {
    const { removalID } = commandArguments(body, "restoreSheep");
    const removal = get(projection, "RemovalRecord", removalID);
    removal.deletedAt = event.received_at_millis;
    releaseHistory(projection, removal.sheepID);
    addOperation(projection, event, "removal", removal.id, { kind: "restoreSheep", identifiers: { removalID: removal.id, sheepID: removal.sheepID } });
    return;
  }
  if (kind === "record.revoke" || kind === "record.restore") {
    let target, entityType, entityID;
    if (kind === "record.revoke") {
      const args = commandArguments(body, "tombstone");
      entityType = args.entityType; entityID = normalizeID(args.entityID);
      const model = entityModels[entityType];
      if (!model) throw unsupported(`record.revoke:${entityType}`);
      target = get(projection, model, entityID);
      // Sheep/pen deletion has cascades; it must not masquerade as a scalar
      // tombstone in this read adapter.
      if (["sheep", "pen", "farm", "productionBatch"].includes(entityType)) throw unsupported(`record.revoke:${entityType}`);
      target.deletedAt = event.received_at_millis;
      // Native tombstones use the original operation ID for restoration;
      // checkpoint tombstones keep their own IDs and are also indexed below.
      insert(projection, "TombstoneRecord", {
        ...metadata, id: commandID, entityType, entityID, operationID: commandID,
        deletedAt: event.received_at_millis, restoredAt: null, reason: args.reason,
      });
    } else {
      const args = commandArguments(body, "restore");
      const tombstone = get(projection, "TombstoneRecord", args.tombstoneID, true);
      entityType = tombstone.entityType; entityID = tombstone.entityID;
      const model = entityModels[entityType];
      if (!model || ["sheep", "pen", "farm", "productionBatch"].includes(entityType)) throw unsupported(`record.restore:${entityType}`);
      target = get(projection, model, entityID, true);
      target.deletedAt = null;
      tombstone.restoredAt = event.received_at_millis;
    }
    if (["transfer", "removal"].includes(entityType)) releaseHistory(projection, target.sheepID);
    if (entityType === "weaning") projection.changedSheep.add(target.sheepID);
    addOperation(projection, event, entityType, entityID, {
      kind: kind === "record.revoke" ? "tombstone" : "restore",
      identifiers: { entityID, sheepID: target.sheepID }, strings: { entityType },
    });
    return;
  }
  if (kind === "pen.create") {
    const args = commandArguments(body, "create");
    const row = insert(projection, "PenRecord", { ...metadata, ...args, id: primaryID(body, "pen"), isActive: true });
    addOperation(projection, event, "pen", row.id, { ...recordPayload("PenRecord", row), kind: "createPen" });
    return;
  }
  if (kind === "sheep.add") {
    const args = normalizeCommandValues(commandArguments(body, "add"));
    const row = insert(projection, "SheepRecord", {
      ...metadata, ...args, id: primaryID(body, "sheep"), sexRawValue: args.sex,
      statusRawValue: "active", initialPenID: args.penID ?? null, currentPenID: args.penID ?? null,
      enteredAt: args.occurredAt, purpose: "未分类", isBreedingRam: false, isHistoricalArchive: false,
      legacyStatusSnapshotIsAuthoritative: false, legacyPenSnapshotIsAuthoritative: false,
    });
    if (row.initialPenID) get(projection, "PenRecord", row.initialPenID);
    projection.changedSheep.add(row.id);
    addOperation(projection, event, "sheep", row.id, { ...recordPayload("SheepRecord", row), kind: "addSheep" });
    return;
  }
  if (kind === "care.sheep.setPurpose") {
    const args = commandArguments(body, "setSheepPurpose");
    const sheepID = normalizeID(args.sheepID ?? args._0);
    const sheep = get(projection, "SheepRecord", sheepID);
    const purpose = args.purpose ?? args._1;
    const changedAt = args.occurredAt ?? event.occurred_at_millis;
    const payload = {
      kind: "care", careCommand: { setSheepPurpose: args },
      optionalStrings: { previousSheepPurpose: sheep.purpose },
      dates: { sheepPurposeChangedAt: new Date(changedAt).toISOString() },
    };
    insert(projection, "DomainOperation", { ...metadata, id: commandID, entityType: "sheep", entityID: sheepID,
      kindRawValue: "care", accountID: event.actor_account_id, occurredAt: changedAt,
      payload: { json: payload }, resultingRevision: event.event_sequence });
    sheep.purpose = purpose;
    projection.changedSheep.add(sheepID);
    return;
  }
  // These operations only affect the photo surface, which the current Web
  // does not expose. All other unknown business commands block activation.
  if (["photoAsset.register", "photoAsset.recycle", "photoAsset.restore"].includes(kind)) return;
  throw unsupported(kind);
}

function decodeData(value) {
  if (value && typeof value === "object" && Object.hasOwn(value, "json")) return value.json;
  const base64 = typeof value === "string" ? value : value?.base64;
  if (!base64) throw invalid();
  const bytes = Uint8Array.from(atob(base64.replace(/\s/g, "")), (character) => character.charCodeAt(0));
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

function classifyPurpose(value) {
  const text = String(value ?? "").trim();
  if (text.includes("哺乳")) return "哺乳羔羊";
  if (text.includes("断奶") && text.includes("羔")) return "断奶羔羊";
  return text;
}

export function rebuildCurrentState(projection, now) {
  const bySheep = (model, key = "sheepID", includeDeleted = false) => {
    const groups = new Map();
    for (const row of rows(projection, model, includeDeleted)) {
      const group = groups.get(row[key]) ?? [];
      group.push(row); groups.set(row[key], group);
    }
    return groups;
  };
  const transfers = bySheep("TransferRecord"), removals = bySheep("RemovalRecord"), weanings = bySheep("WeaningRecord", "sheepID", true);
  const purposes = new Map();
  for (const operation of rows(projection, "DomainOperation")) {
    if (operation.kindRawValue !== "care") continue;
    const payload = decodeData(operation.payload);
    const args = payload.careCommand?.setSheepPurpose;
    if (!args) continue;
    const sheepID = normalizeID(args.sheepID ?? args._0);
    if (sheepID !== operation.entityID) continue;
    const group = purposes.get(sheepID) ?? [];
    group.push({ id: operation.id, occurredAt: Date.parse(payload.dates?.sheepPurposeChangedAt) || operation.occurredAt,
      recordedAt: operation.createdAt, purpose: args.purpose ?? args._1, previous: payload.optionalStrings?.previousSheepPurpose,
      explicit: true });
    purposes.set(sheepID, group);
  }
  for (const sheep of rows(projection, "SheepRecord")) {
    const removal = (removals.get(sheep.id) ?? []).filter((row) => row.occurredAt <= now).sort(compareFacts)[0];
    const transfer = (transfers.get(sheep.id) ?? []).filter((row) => row.occurredAt <= now).sort(compareFacts).at(-1);
    if (sheep.isHistoricalArchive) sheep.statusRawValue = "removed";
    else if (sheep.legacyStatusSnapshotIsAuthoritative !== true) {
      sheep.statusRawValue = removal ? (removal.kindRawValue === "deceased" ? "deceased" : "removed") : "active";
      sheep.removedAt = removal?.occurredAt ?? null;
    }
    if (sheep.statusRawValue !== "active" || sheep.isHistoricalArchive) sheep.currentPenID = null;
    else if (sheep.legacyPenSnapshotIsAuthoritative !== true) {
      sheep.currentPenID = sheep.enteredAt <= now ? transfer?.toPenID ?? sheep.initialPenID ?? null : null;
    }
    const records = weanings.get(sheep.id) ?? [];
    const explicit = (purposes.get(sheep.id) ?? []).sort(compareFacts);
    const managed = !sheep.isBreedingRam && ["哺乳羔羊", "断奶羔羊", "未分类"].includes(classifyPurpose(sheep.purpose));
    if (!explicit.length && !managed) continue;
    const bornHere = sheep.damProvenanceRawValue === "lambing";
    if (!bornHere && !records.length && !explicit.length) continue;
    let purpose = bornHere ? "哺乳羔羊" : explicit[0]?.previous ?? (records.length ? "哺乳羔羊" : sheep.purpose);
    const changes = [
      ...records.filter((row) => row.deletedAt == null).map((row) => ({ ...row, purpose: "断奶羔羊", explicit: false })),
      ...explicit,
    ].sort((a, b) => a.occurredAt - b.occurredAt || Number(a.explicit) - Number(b.explicit) || compareFacts(a, b));
    for (const change of changes) {
      if (change.occurredAt > now) break;
      if (change.explicit || ["哺乳羔羊", "断奶羔羊", "未分类"].includes(classifyPurpose(purpose))) purpose = change.purpose;
    }
    sheep.purpose = purpose;
    sheep.isBreedingRam = sheep.sexRawValue === "ram" && purpose === "种公羊";
  }
}

function recordPayload(model, record) {
  const payload = { strings: {}, optionalStrings: {}, identifiers: {}, optionalIdentifiers: {}, dates: {}, optionalDates: {}, integers: {} };
  for (const [name, type] of Object.entries(checkpointSchema[model].fields)) {
    const value = record[name];
    if (value === undefined) continue;
    const field = name.endsWith("RawValue") ? name.slice(0, -8) : name;
    if (type.startsWith("Date")) payload[type.endsWith("?") ? "optionalDates" : "dates"][field] = value == null ? null : new Date(value).toISOString();
    else if (type.startsWith("UUID")) payload[type.endsWith("?") ? "optionalIdentifiers" : "identifiers"][field] = value;
    else if (type.startsWith("String")) payload[type.endsWith("?") ? "optionalStrings" : "strings"][field] = value;
    else if (type.startsWith("Bool")) payload.integers[field] = value == null ? null : Number(value);
    else if (type.startsWith("Int")) payload.integers[field] = value;
  }
  if (model === "SheepRecord") {
    payload.dates.occurredAt = new Date(record.enteredAt).toISOString();
    payload.optionalIdentifiers.penID = record.initialPenID;
    payload.optionalIdentifiers.legacyCurrentPenID = record.currentPenID;
    payload.strings.legacyStatusRawValue = record.statusRawValue;
    payload.optionalDates.legacyRemovedAt = record.removedAt == null ? null : new Date(record.removedAt).toISOString();
  }
  if (model === "ProductionBatchRecord") payload.strings.source = record.sourceRawValue;
  return payload;
}

const historyKinds = {
  weight: "recordWeight", weaning: "recordWeaning", transfer: "transferSheep", removal: "removeSheep",
  reproduction: "recordReproduction", feed: "recordFeed", note: "addNote", productionBatch: "createBatch", batchMembership: "assignBatchMembership",
};

export function finishV2Projection(projection, { now = Date.now() } = {}) {
  rebuildCurrentState(projection, now);
  const rowsByType = new Map();
  const operationRows = [];
  const indexChildren = (model, key) => {
    const index = new Map();
    for (const row of rows(projection, model)) {
      const group = index.get(row[key]) ?? [];
      group.push(row); index.set(row[key], group);
    }
    return index;
  };
  const feedLines = indexChildren("FeedRecordLine", "feedRecordID");
  const offspring = indexChildren("LambingOffspringRecord", "lambingRecordID");
  const tailEntityIDs = new Set(projection.tailOperations.filter((row) => !["tombstone", "restore"].includes(row.payload_json?.kind))
    .map((row) => `${row.entity_type}:${row.entity_id}`));
  for (const [entity, model] of Object.entries(entityModels)) {
    const projected = rows(projection, model).map((record) => {
      const payload = recordPayload(model, record);
      if (entity === "feed") payload.feedLines = feedLines.get(record.id) ?? [];
      if (entity === "reproduction") payload.lambingOffspring = offspring.get(record.id) ?? [];
      const row = {
        entity_id: record.id, entity_type: entity, revision: record.revision ?? 0,
        modified_at: new Date(record.updatedAt ?? record.recordedAt ?? record.createdAt).toISOString(),
        operation_id: null, payload_json: payload,
        v2State: entity === "sheep" ? {
          status: record.statusRawValue, penID: record.currentPenID ?? null,
          removedAt: record.removedAt == null ? null : new Date(record.removedAt).toISOString(),
          isHistoricalArchive: record.isHistoricalArchive === true,
        } : null,
      };
      if (historyKinds[entity] && !tailEntityIDs.has(`${entity}:${record.id}`)) operationRows.push({
        ...row, operation_id: `checkpoint:${entity}:${record.id}`,
        occurred_at: new Date(record.occurredAt ?? record.startedAt ?? record.joinedAt ?? record.createdAt).toISOString(),
        payload_json: { ...payload, kind: historyKinds[entity] },
      });
      return row;
    });
    rowsByType.set(entity, projected);
  }
  for (const record of rows(projection, "DomainOperation")) {
    operationRows.push({ operation_id: record.id, entity_type: record.entityType, entity_id: record.entityID,
      revision: record.resultingRevision, occurred_at: new Date(record.occurredAt).toISOString(),
      modified_at: new Date(record.createdAt).toISOString(), modified_by_account_id: record.accountID,
      payload_json: decodeData(record.payload) });
  }
  operationRows.push(...projection.tailOperations);
  const components = indexChildren("FeedRecipeComponentRecord", "recipeID");
  const profiles = new Map(rows(projection, "TMRFormulaProfileRecord").map((row) => [row.recipeID, row]));
  rowsByType.set("tmrFormula", rows(projection, "FeedRecipeRecord").map((recipe) => ({
    entity_id: recipe.id, entity_type: "tmrFormula", modified_at: new Date(recipe.updatedAt).toISOString(),
    payload_json: { tmrCommand: { saveFormula: { _0: {
      ...recipe, stage: recipe.stageRawValue, ...profiles.get(recipe.id), id: recipe.id,
      components: (components.get(recipe.id) ?? []).map((row) => ({ ...row, quantityText: row.kilogramsText })),
    } } } },
  })));
  const planPens = indexChildren("TMRFeedingPlanPenRecord", "planID");
  rowsByType.set("tmrFeedingPlan", rows(projection, "TMRFeedingPlanRecord").map((plan) => ({
    entity_id: plan.id, entity_type: "tmrFeedingPlan", modified_at: new Date(plan.updatedAt).toISOString(),
    payload_json: { tmrCommand: { saveFeedingPlan: { _0: {
      ...plan, scheduleKind: plan.scheduleKindRawValue, granularity: plan.granularityRawValue,
      allocationMode: plan.allocationModeRawValue, effectiveStartDate: new Date(plan.effectiveStartDate).toISOString(),
      pens: planPens.get(plan.id) ?? [],
    } } } },
  })));
  return { rowsByType, operationRows, models: Object.fromEntries([...projection.models].map(([model, records]) => [model, [...records.values()]])) };
}
