import { compensateOffspring, setLambingRevoked } from "./reproductionLifecycle.js";
import { labelKinds, applyLabelAction } from "./sheepLabels.js";
import { replayTMR,tmrReplayKinds } from './tmrBusinessReplay.js';
import { presentAtTime,penAtTime } from './businessValidation.js';
import { applyV2Event } from "./cloudV2Projection.js";
import schema from "../../../tools/esheep_cloud_checkpoint_schema_v1.json" with { type: "json" };
import { stableUUID } from "./nativeEventSnapshots.js";
import { decimalMultiply, decimalSum, negate } from "./decimal.js";

const supported = new Set(["sheep.add", "productionBatch.create", "batchMembership.assign", "batchMembership.leave", "batchMembership.restore",
  "breedingProgram.create", "feedIngredient.add", "feedRecipe.create", "feedRecipe.member.add", "feed.recordLegacy", "inventory.receive", "semen.add",
  "care.healthCatalog.upsert", "care.inventory.receive", "care.inventory.adjust", "care.health.recordBatch", "care.semen.adjust", "care.semenDonor.upsert",
  "care.semen.setDonor", "care.reproduction.recordBatch", "care.reproduction.correct", "care.lambing.record", "care.lambing.correct", "care.lambing.revoke", "care.lambing.restore", "care.sheepPedigree.update", "care.sheep.setBreedingRam",
  "care.careRules.update", "care.operationalAlertRules.update", "care.operationalAlert.defer", "care.careReminder.setStatus", "care.inventoryLot.setActive"]);

// Match native JSONEncoder.sortedKeys and UUID encoding for the shared
// reproduction document. Legacy rule updates leave this field untouched.
function reproductionSettingsJSON(value) {
  const settings = {
    minimumAgeMonths: value.minimumAgeMonths,
    penUsages: Object.fromEntries(Object.entries(value.penUsages).map(([id, usage]) => [id.toLowerCase(), usage])),
    scopeConfigured: value.scopeConfigured,
    selectedPenIDs: value.selectedPenIDs.map((id) => id.toUpperCase()).sort(),
    youthBreedingConfirmedSheepIDs: value.youthBreedingConfirmedSheepIDs.map((id) => id.toUpperCase()).sort(),
  };
  for (const field of ["postpartumReminderDays", "postpartumWarningDays", "maidenReminderMonths", "maidenWarningMonths", "weighingReminderDays"]) {
    if (value[field] != null) settings[field] = value[field];
  }
  const sorted = (entry) => Array.isArray(entry) ? entry.map(sorted)
    : entry && typeof entry === "object" ? Object.fromEntries(Object.keys(entry).sort().map((key) => [key, sorted(entry[key])])) : entry;
  return JSON.stringify(sorted(settings));
}

export async function applyExtendedV2Event(projection, event, body) {
  const kind = body.command_kind;
  if(kind==="care.sheepLabels.patchProfile" && event.event_kind==="fields_patched") {
    if(body.changes.some(c=>c.field==="sex")) {
      const d=body.command_payload.body.sheepLabels._0.patchProfile._0;
      const normalize=values=>values.map(id=>id.toLowerCase());
      const models=Object.fromEntries([...projection.models].map(([name,rows])=>[name,[...rows.values()]]));
      applyLabelAction("editLabels",{id:d.id.toLowerCase(),sheepID:d.sheepID.toLowerCase(),addIDs:[],removeIDs:normalize(d.removeLabelIDs),setsPrimary:false},models,{farmID:projection.farmID,accountID:event.actor_account_id,at:event.occurred_at_millis});
      for(const name of ["SheepLabelRecord","SheepLabelAssignmentRecord","SheepLabelChangeRecord"])projection.models.set(name,new Map((models[name]??[]).map(r=>[r.id,r])));
    }
  }
  if(event.event_kind==='fields_patched'&&event.stream_type==='sheepProfile'&&body.changes?.some(c=>['currentParity','parityRecordedAt'].includes(c.field))) {
    const normal=body.changes.filter(c=>!['currentParity','parityRecordedAt'].includes(c.field));
    if(normal.length)applyV2Event(projection,event,{...body,changes:normal});
    const parity=body.changes.find(c=>c.field==='currentParity')?.value;
    if(parity&&parity.type!=='null') {
      const sheep=projection.models.get('SheepRecord').get(event.stream_id.toLowerCase());
      if(parity.type!=='integer'||parity.value<0||sheep?.sexRawValue!=='ewe')throw new Error('档案胎次字段无效。');
      const id=await stableUUID(event.event_id,'esheep-cloud-profile-parity');
      if(!projection.models.get('ReproductionRecord').has(id))projection.models.get('ReproductionRecord').set(id,{id,farmID:projection.farmID,eweID:sheep.id,kindRawValue:'parityBaseline',occurredAt:event.occurred_at_millis,createdAt:event.received_at_millis,updatedAt:event.received_at_millis,deletedAt:null,parity:parity.value,revision:1,note:'档案确认当前胎次'});
    }
    return true;
  }
  if(kind==="care.sheepLabels.patchProfile" && event.event_kind==="fields_patched") { applyV2Event(projection,event,body); return true; }
  if (labelKinds.has(kind)) {
    const prior=projection.seenCommands.get(event.command_id);
    if(prior){if(prior!==event.source_command_digest)throw new Error("标签命令摘要不一致。");return true;}
    if(kind!==body.command_payload?.kind)throw new Error("标签命令类型不一致。");
    const normalize=value=>Array.isArray(value)?value.map(normalize):value&&typeof value==="object"?Object.fromEntries(Object.entries(value).map(([k,v])=>[k,normalize(v)])):typeof value==="string"&&/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value)?value.toLowerCase():value;
    const nested=body.command_payload.body?.sheepLabels?._0;
    const [action,encoded]=Object.entries(nested??{})[0]??[];
    const expected={"care.sheepLabel.save":"saveLabel","care.sheepLabel.delete":"deleteLabel","care.sheepLabels.edit":"editLabels","care.sheepLabels.patchProfile":"patchProfile"}[kind];
    if(action!==expected||Object.keys(nested??{}).length!==1)throw new Error("标签命令内容不匹配。");
    const models=Object.fromEntries([...projection.models].map(([name,rows])=>[name,[...rows.values()]]));
    applyLabelAction(action,normalize(encoded?._0),models,{farmID:projection.farmID,accountID:event.actor_account_id,at:event.occurred_at_millis});
    for(const name of ["SheepLabelRecord","SheepLabelAssignmentRecord","SheepLabelChangeRecord","SheepRecord"])projection.models.set(name,new Map((models[name]??[]).map(r=>[r.id,r])));
    projection.seenCommands.set(event.command_id,event.source_command_digest);
    return true;
  }

  if (!supported.has(kind)&&!tmrReplayKinds.has(kind)) return false;
  if (kind !== body.command_payload?.kind) throw new Error("业务事件种类不一致。");
  const prior = projection.seenCommands.get(event.command_id);
  if (prior) { if (prior !== event.source_command_digest) throw new Error("业务命令摘要不一致。"); return true; }
  const payload = body.command_payload.body;
  const [name, encoded] = Object.entries(payload)[0];
  const normalize = (value) => Array.isArray(value) ? value.map(normalize) : value && typeof value === "object"
    ? Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, normalize(entry)]))
    : typeof value === "string" && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value) ? value.toLowerCase() : value;
  const args = normalize(encoded._0 && typeof encoded._0 === "object" ? encoded._0 : encoded);
  const at = event.received_at_millis;
  const all = (model) => [...projection.models.get(model).values()];
  const rows = (model) => all(model).filter((r) => r.deletedAt == null);
  const get = (model, id) => { const row = projection.models.get(model)?.get(id?.toLowerCase()); if (!row) throw new Error(`业务记录缺少关联资料：${model} ${id}`); return row; };
  const primary = (type) => { const value = body.affected_streams.find((s) => s.type === type)?.id; if (!value) throw new Error(`业务事件缺少 ${type} 标识。`); return value.toLowerCase(); };
  function put(model, values) {
    const defaults = Object.fromEntries(Object.entries(schema[model].fields).map(([key, type]) => [key, type.endsWith("?") ? null : type === "Date" ? at : type === "Bool" ? false : ["Int", "Int64", "Double"].includes(type) ? 0 : type === "Data" ? "e30=" : ""]));
    const id = values.id.toLowerCase();
    const existing = projection.models.get(model).get(id);
    const row = { ...defaults, revision: 1, farmID: projection.farmID, ...existing, ...values, id };
    projection.models.get(model).set(id, row); return row;
  }
  async function reminder(source, sheepID, dueAt, kind, title) {
    if (dueAt == null) return;
    put("CareReminderRecord", { id: await stableUUID(source.id, `${kind}:${sheepID ?? ""}:`), sourceEntityType: source.type,
      sourceEntityID: source.id, sheepID, dueAt, kindRawValue: kind, title, statusRawValue: "pending" });
  }
  const bornSheep = [];
  switch (kind) {
    case "feedBatch.save": case "tmr.produceTMRBatch": case "tmr.recordTMRFeeding": await replayTMR(kind,args,{rows,get,put,primary,at});break;
    case "sheep.add": {
      applyV2Event(projection,event,body);
      if(args.sex==="ewe"&&args.currentParity!=null)put("ReproductionRecord",{id:await stableUUID(primary("sheep"),"parity-at-entry"),eweID:primary("sheep"),kindRawValue:"parityBaseline",occurredAt:args.occurredAt,parity:args.currentParity,note:"建档时当前胎次"});
      break;
    }
    case "productionBatch.create": {
      const id = primary("productionBatch");
      put("ProductionBatchRecord", { ...args, id, sourceRawValue: "manual", statusRawValue: "active" });
      for (const sheepID of args.sheepIDs) { get("SheepRecord", sheepID); put("BatchMembershipRecord", { id: await stableUUID(id, `batch-member-${sheepID.toLowerCase()}`), batchID: id, sheepID, joinedAt: args.startedAt }); }
      break;
    }
    case "batchMembership.assign": put("BatchMembershipRecord", { ...args, id: primary("batchMembership") }); break;
    case "batchMembership.leave": {
      const row = rows("BatchMembershipRecord").find((r) => r.batchID === args.batchID && r.sheepID === args.sheepID && r.leftAt == null);
      if (!row) throw new Error("找不到可脱离的生产批次成员。");
      Object.assign(row, { leftAt: args.leftAt, leaveReason: args.reason, updatedAt: at, revision: row.revision + 1 }); break;
    }
    case "batchMembership.restore": Object.assign(get("BatchMembershipRecord", args.membershipID), { leftAt: null, leaveReason: null, updatedAt: at }); break;
    case "breedingProgram.create": {
      const id = primary("breedingProgram"); put("BreedingProgramRecord", { ...args, id });
      for (const [i, step] of args.steps.entries()) put("BreedingProgramStepRecord", { ...step, id: step.id ?? await stableUUID(id, `step-${i}`), programID: id, order: i }); break;
    }
    case "feedIngredient.add": put("FeedIngredientRecord", { ...args, id: primary("feedIngredient"), isActive: true }); break;
    case "feedRecipe.create": put("FeedRecipeRecord", { ...args, id: primary("feedRecipe"), isActive: true }); break;
    case "feedRecipe.member.add": put("FeedRecipeComponentRecord", { ...args, id: primary("feedRecipeComponent") }); break;
    case "feed.recordLegacy": {
      const id = primary("feed"); get("PenRecord", args.penID);
      put("FeedRecord", { ...args, id, modeRawValue: args.mode, totalKilogramsText: decimalSum(args.lines.map((l) => l.kilogramsText)) });
      for (const [i, line] of args.lines.entries()) {
        const ingredient = get("FeedIngredientRecord", line.ingredientID);
        put("FeedRecordLine", { ...line, id: line.id, feedRecordID: id,
          ingredientNameSnapshot: ingredient.name, unitSnapshot: ingredient.unit, dryMatterTextSnapshot: ingredient.dryMatterText });
      }
      break;
    }
    case "inventory.receive": case "care.inventory.receive": {
      const id = args.id ?? primary("inventoryLot");
      put("InventoryLotRecord", { ...args, id, kindRawValue: args.kindRawValue ?? args.kind, startingQuantityText: args.quantityText, receivedAt: args.occurredAt, isActive: true });
      put("InventoryTransactionRecord", { id: await stableUUID(id, "inventory-receipt"), inventoryLotID: id, kindRawValue: "receipt", quantityText: args.quantityText, occurredAt: args.occurredAt, sourceRecordID: id, note: args.note }); break;
    }
    case "care.inventory.adjust": get("InventoryLotRecord", args.lotID); put("InventoryTransactionRecord", { ...args, inventoryLotID: args.lotID, kindRawValue: "adjustment", quantityText: args.quantityDeltaText }); break;
    case "semen.add": {
      const id = primary("semen"); put("SemenRecord", { ...args, id, quantityText: "0" });
      put("SemenTransactionRecord", { id: await stableUUID(id, "semen-receipt"), semenID: id, kindRawValue: "receipt", quantityText: args.quantityText, occurredAt: at, sourceRecordID: id, note: "冻精入库" }); break;
    }
    case "care.semen.adjust": get("SemenRecord", args.semenID); put("SemenTransactionRecord", { ...args, kindRawValue: "adjustment", quantityText: args.quantityDeltaText }); break;
    case "care.healthCatalog.upsert": put("HealthCatalogItemRecord", args); break;
    case "care.semenDonor.upsert": put("SemenDonorRecord", { ...args, statusRawValue: args.status, revision: args.expectedRevision + 1 }); break;
    case "care.semen.setDonor": Object.assign(get("SemenRecord", args.semenID), { donorID: args.donorID, revision: args.expectedRevision + 1, updatedAt: at }); break;
    case "care.inventoryLot.setActive": Object.assign(get("InventoryLotRecord", args.lotID), { isActive: args.isActive }); break;
    case "care.health.recordBatch": {
      const subjects = args.subjectIDs.length ? args.subjectIDs : rows("SheepRecord").filter((s) => presentAtTime(s,args.occurredAt,Object.fromEntries([...projection.models].map(([m,r])=>[m,[...r.values()]]))) && penAtTime(s,args.occurredAt,Object.fromEntries([...projection.models].map(([m,r])=>[m,[...r.values()]]))) === args.penID).map((s) => s.id);
      put("CareBatchRecord", { id: args.batchID, kindRawValue: "health", occurredAt: args.occurredAt, note: args.note });
      put("HealthRecord", { ...args, sheepID: subjects.length === 1 ? subjects[0] : null, kindRawValue: args.kind, itemNameSnapshot: args.itemName, quantityText: args.dosePerSubjectText });
      for (const sheepID of subjects) {
        const sheep = get("SheepRecord", sheepID);
        put("HealthSubjectLink", { id: await stableUUID(args.id, sheepID), healthRecordID: args.id, sheepID });
        await reminder({ id: args.id, type: "health" }, sheepID, args.reminderAt, "booster", `${sheep.earTag} · ${args.itemName}复免`);
      }
      if (args.inventoryLotID && args.dosePerSubjectText) put("InventoryTransactionRecord", { id: await stableUUID(args.id, "inventory-consumption"), inventoryLotID: args.inventoryLotID,
        kindRawValue: "consumption", quantityText: decimalMultiply(args.dosePerSubjectText, subjects.length), occurredAt: args.occurredAt, sourceRecordID: args.id, note: args.itemName });
      break;
    }
    case "care.reproduction.correct": {
      const original=get("ReproductionRecord",args.originalID??args._0),replacement=args.replacement??args._1;
      if(!replacement)throw new Error("繁殖修正缺少替换事实。");
      for(const transaction of rows("SemenTransactionRecord"))if(transaction.sourceRecordID===original.id)put("SemenTransactionRecord",{id:await stableUUID(transaction.id,"reverse-delete"),semenID:transaction.semenID,kindRawValue:"adjustment",quantityText:transaction.quantityText,occurredAt:at,sourceRecordID:original.id,note:"删除配种反向恢复冻精"});
      for(const reminder of rows("CareReminderRecord"))if(reminder.sourceEntityID===original.id)Object.assign(reminder,{deletedAt:at,revision:reminder.revision+1});
      original.deletedAt=at;original.revision++;
      const subjects=replacement.subjects.map(subject=>({...subject,
        relatedBreedingRecordID:subject.relatedBreedingRecordID??(subject.reproductionCycleID==null?original.relatedBreedingRecordID:null),
        reproductionCycleID:subject.reproductionCycleID??original.reproductionCycleID,
        breedingRoundID:subject.reproductionCycleID==null?(original.breedingRoundID??(original.kindRawValue==="breeding"?original.id:null)):subject.breedingRoundID,
        breedingIntent:subject.breedingIntent??original.breedingIntentRawValue}));
      await applyExtendedV2Event(projection,event,{...body,command_kind:"care.reproduction.recordBatch",command_payload:{kind:"care.reproduction.recordBatch",body:{recordReproductionBatch:{_0:{...replacement,subjects}}}}});
      break;
    }
    case "care.lambing.correct": {
      const original=get("ReproductionRecord",args.originalID??args._0),replacement=args.replacement??args._1,reason=args.reason??args._2;
      const oldRevision=original.revision,kept=new Set(replacement.offspring.map(r=>r.id));
      for(const detail of rows("LambingOffspringRecord"))if(detail.lambingRecordID===original.id&&!kept.has(detail.id)){
        await compensateOffspring(detail,original,{projection,put,at,accountID:event.actor_account_id,reason});
        Object.assign(detail,{deletedByLambingRevocation:false,deletedAt:at,updatedAt:at,revision:detail.revision+1});
      }
      await applyExtendedV2Event(projection,event,{...body,command_kind:"care.lambing.record",command_payload:{kind:"care.lambing.record",body:{recordLambing:{_0:{...replacement,relatedBreedingRecordID:replacement.relatedBreedingRecordID??(replacement.reproductionCycleID==null?original.relatedBreedingRecordID:null),reproductionCycleID:replacement.reproductionCycleID??original.reproductionCycleID,breedingRoundID:replacement.reproductionCycleID==null?original.breedingRoundID:replacement.breedingRoundID}}}}});
      const corrected=get("ReproductionRecord",replacement.id);corrected.revision=oldRevision+1;corrected.updatedAt=at;
      break;
    }
    case "care.lambing.revoke": case "care.lambing.restore": {
      const record=get("ReproductionRecord",args.recordID??args._0);
      await setLambingRevoked(kind==="care.lambing.revoke",record,{projection,put,at,accountID:event.actor_account_id,reason:args.reason??"恢复产羔记录"});
      break;
    }
    case "care.reproduction.recordBatch": {
      put("CareBatchRecord", { id: args.id, kindRawValue: args.kind, occurredAt: args.occurredAt, note: args.note });
      const sourceSemen = args.semenID ? get("SemenRecord", args.semenID) : null;
      const donor = sourceSemen?.donorID ? get("SemenDonorRecord", sourceSemen.donorID) : null;
      for (const subject of args.subjects) {
        const id = await stableUUID(args.id, subject.id);
        put("ReproductionRecord", { ...args, ...subject, id, kindRawValue: args.kind, batchID: args.id,
          breedingIntentRawValue: subject.breedingIntent ?? null, sireID: args.sireID ?? donor?.linkedRamID ?? null, semenNameSnapshot: sourceSemen?.code ?? null,
          semenDonorID: donor?.id ?? null, semenDonorNameSnapshot: donor?.name ?? null,
          semenDonorRegistrationNumberSnapshot: donor?.registrationNumber?.trim() || null,
          semenDonorBreedSnapshot: donor?.breed ?? null,
          paternalSourceRawValue: args.kind === "breeding" ? (args.sireID ? "ram" : donor ? "semenDonor" : "unknown") : "unknown" });
        if (args.kind !== "abortion") await reminder({ id, type: "reproduction" }, subject.eweID, args.reminderAt, args.kind === "breeding" ? "pregnancyCheck" : "expectedLambing", `${subject.result || "母羊"} · ${args.kind === "breeding" ? "孕检" : "预产期"}`);
        if (args.semenID) put("SemenTransactionRecord", { id: await stableUUID(id, "semen-consumption"), semenID: args.semenID, kindRawValue: "consumption", quantityText: args.semenUnitsPerEweText ?? "1", occurredAt: args.occurredAt, sourceRecordID: id, note: `配种批次 ${args.id}` });
      }
      break;
    }
    case "care.lambing.record": {
      const mother = get("SheepRecord", args.eweID);
      const linked = args.relatedBreedingRecordID ? get("ReproductionRecord",args.relatedBreedingRecordID) : null;
      const sourceSemen = (args.semenID??linked?.semenID) ? get("SemenRecord", args.semenID??linked.semenID) : null;
      const donor = sourceSemen?.donorID ? get("SemenDonorRecord", sourceSemen.donorID) : null;
      const sireID = args.sireID ?? linked?.sireID ?? donor?.linkedRamID ?? null;
      put("ReproductionRecord", { ...args, kindRawValue: "lambing", sireID, semenNameSnapshot: sourceSemen?.code ?? null, lambCount: args.offspring.length,
        semenDonorID: donor?.id ?? null, semenDonorNameSnapshot: donor?.name ?? null });
      for (const lamb of args.offspring) {
        const weightAt = lamb.weightOccurredAt ?? args.occurredAt;
        const isBirth = weightAt >= args.occurredAt && weightAt - args.occurredAt <= 86400000;
        const weightID = lamb.birthWeightText ? await stableUUID(isBirth ? lamb.sheepID : lamb.id, isBirth ? "birth-weight" : "lambing-recorded-weight") : null;
        if (lamb.createSheepRecord) {
          const fatherBreed = sireID ? get("SheepRecord", sireID).breed : donor?.breed;
          const breed = lamb.breed?.trim() || (fatherBreed && mother.breed ? `${fatherBreed}-${mother.breed}串` : fatherBreed || mother.breed || "未知");
          const existing=projection.models.get("SheepRecord").get(lamb.sheepID);
          if(existing?.damProvenanceRawValue==="manual"&&existing.damID!==args.eweID||existing?.sireProvenanceRawValue==="manual"&&(existing.sireID!==sireID||existing.semenDonorID!==(donor?.id??null)))throw new Error("羔羊系谱已被人工确认，不能覆盖。");
          put("SheepRecord", { id: lamb.sheepID, earTag: lamb.earTag, breed:lamb.breed?.trim()||existing?.breed||breed, sexRawValue: lamb.sex, statusRawValue: existing?.statusRawValue??"active", purpose: existing?.purpose??"哺乳羔羊",
            initialPenID: args.penID, currentPenID: existing?.currentPenID??args.penID, enteredAt: Math.min(existing?.enteredAt??args.occurredAt,args.occurredAt), birthAt: args.occurredAt, damID: args.eweID, sireID,
            damProvenanceRawValue: existing?.damProvenanceRawValue==="manual"?"manual":"lambing", sireProvenanceRawValue: existing?.sireProvenanceRawValue==="manual"?"manual":sireID || donor ? "lambing" : null, semenDonorID: donor?.id ?? null,semenDonorNameSnapshot:donor?.name??null,semenDonorRegistrationNumberSnapshot:donor?.registrationNumber??null,semenDonorBreedSnapshot:donor?.breed??null, note: "由产羔记录自动建档" });
          bornSheep.push(lamb.sheepID);
          const previousDetail=projection.models.get("LambingOffspringRecord").get(lamb.id);
          if(previousDetail?.autoBirthWeightRecordID&&previousDetail.autoBirthWeightRecordID!==weightID){const old=projection.models.get("WeightRecord").get(previousDetail.autoBirthWeightRecordID);if(old){old.deletedAt=at;old.revision++;}}
          if (weightID) put("WeightRecord", { id: weightID, sheepID: lamb.sheepID, kilogramsText: lamb.birthWeightText, occurredAt: weightAt, deletedAt:null, note: isBirth ? "初生重" : "产羔录入称重" });
        }
        put("LambingOffspringRecord", { id: lamb.id, lambingRecordID: args.id, sheepID: lamb.createSheepRecord ? lamb.sheepID : null,
          legacyEarTag: lamb.earTag, sexRawValue: lamb.sex, birthWeightText: isBirth ? lamb.birthWeightText : "", isStillborn: lamb.isStillborn,
          deletedAt:null,autoCreatedSheep: lamb.createSheepRecord, autoBirthWeightRecordID: lamb.createSheepRecord ? weightID : null });
      }
      for (const row of rows("CareReminderRecord")) if (row.sheepID === args.eweID && row.kindRawValue === "expectedLambing") Object.assign(row, { statusRawValue: "completed", completedAt: at });
      break;
    }
    case "care.sheepPedigree.update": {
      const child = get("SheepRecord", args.sheepID), donor = args.semenDonorID ? get("SemenDonorRecord", args.semenDonorID) : null;
      put("PedigreeChangeRecord", { id: args.id, sheepID: child.id, beforeDamID: child.damID, afterDamID: args.damID, beforeSireID: child.sireID,
        afterSireID: donor?.linkedRamID ?? args.sireID, beforeSemenDonorID: child.semenDonorID, afterSemenDonorID: args.semenDonorID,
        reason: args.reason, changedByAccountID: event.actor_account_id, sheepRevision: child.revision + 1, occurredAt: at });
      Object.assign(child, { damID: args.damID, sireID: donor?.linkedRamID ?? args.sireID, semenDonorID: args.semenDonorID,
        semenDonorNameSnapshot: donor?.name ?? null, revision: child.revision + 1, updatedAt: at }); break;
    }
    case "care.sheep.setBreedingRam": Object.assign(get("SheepRecord", args.sheepID), { isBreedingRam: args.isBreedingRam, revision: args.expectedRevision + 1, updatedAt: at }); break;
    case "care.careRules.update": put("FarmCareRuleRecord", { ...args, updatedAt: at }); break;
    case "care.operationalAlertRules.update": {
      const existing = projection.models.get("FarmCareRuleRecord").get(args.id);
      const patch = { id: args.id, updatedAt: at, revision: (existing?.revision ?? 0) + 1 };
      if (args.updatesReproductionOnly !== true || !existing) {
        Object.assign(patch, { pregnancyCheckDays: args.pregnancyCheckDays, gestationDays: args.gestationDays,
          warningLeadDays: args.warningLeadDays ?? 0, alertDigestEnabled: args.digestEnabled,
          alertDigestMinuteOfDay: args.digestMinuteOfDay });
      }
      if (args.updatesReproductionOnly !== true) {
        Object.assign(patch, { weaningAgeDays: args.weaningAgeDays,
          operationalAlertsConfiguredAt: existing?.operationalAlertsConfiguredAt ?? at });
      }
      if (args.reproductionSettings != null) patch.reproductionSettingsJSON = reproductionSettingsJSON(args.reproductionSettings);
      else if (args.updatesReproductionOnly === true) throw new Error("繁殖设置内容缺失。");
      put("FarmCareRuleRecord", patch);
      break;
    }
    case "care.operationalAlert.defer": put("FarmAlertDeferralRecord", args); break;
    case "care.careReminder.setStatus": Object.assign(get("CareReminderRecord", args.reminderID), { statusRawValue: args.status, completedAt: args.status === "completed" ? at : null }); break;
    default: throw new Error(`未实现的业务读取：${name}`);
  }
  for (const id of bornSheep) projection.changedSheep.add(id);
  projection.seenCommands.set(event.command_id, event.source_command_digest);
  return true;
}
