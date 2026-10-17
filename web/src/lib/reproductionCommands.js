import { stableUUID, liveRows } from "./nativeEventSnapshots.js";
import { entryAssociation } from "./reproductionCycles.js";

export async function reproductionCommand(record, workspace) {
  if (!["owner", "administrator"].includes(workspace.farm.role)) throw new Error("只有牧场主或管理员可以核实关联和修改规则。");
  const draft = record.reproductionDraft, models = workspace.models;
  const records = liveRows(models, "ReproductionRecord"), id = draft.id;
  if (record.reproductionAction === "settings") {
    const rule = liveRows(models,"FarmCareRuleRecord")[0];
    if ((rule?.reproductionSettingsJSON ?? null) !== (draft.expectedSettingsJSON ?? null)) throw new Error("繁殖设置已被更新，请刷新后重新核对。");
    const settings = draft.settings;
    if (!Number.isInteger(settings.minimumAgeMonths) || settings.minimumAgeMonths < 1 || settings.minimumAgeMonths > 120) throw new Error("参配月龄须为 1–120。");
    if (settings.weighingReminderDays != null && (!Number.isInteger(settings.weighingReminderDays) || settings.weighingReminderDays < 1 || settings.weighingReminderDays > 3650)) throw new Error("称重周期须为 1–3650 天或留空。");
    const pens=new Set(liveRows(models,"PenRecord").map(r=>r.id.toLowerCase()));
    if(settings.selectedPenIDs.some(value=>!pens.has(value.toLowerCase())))throw new Error("参与圈舍已变更，请重新核对。");
    const args={id:rule?.id??id,pregnancyCheckDays:rule?.pregnancyCheckDays??45,gestationDays:rule?.gestationDays??150,
      weaningAgeDays:rule?.weaningAgeDays??60,warningLeadDays:rule?.warningLeadDays??0,digestEnabled:rule?.alertDigestEnabled??false,
      digestMinuteOfDay:rule?.alertDigestMinuteOfDay??480,reproductionSettings:settings,updatesReproductionOnly:true};
    return [{kind:"care.operationalAlertRules.update",body:{updateOperationalAlertRules:{_0:args}},streams:[{type:"careRules",id:args.id}],fields:["reproductionSettings"],occurredAt:Date.now()}];
  }
  if(record.reproductionAction!=="associate")throw new Error("繁殖操作无效。");
  const original=records.find(r=>r.id===draft.recordID);
  if(!original||!["breeding","pregnancyCheck","abortion"].includes(original.kindRawValue))throw new Error("原始记录不存在或不支持关联修正。");
  if(original.revision!==draft.expectedRevision)throw new Error("原始记录已被修改，请刷新后再核实。");
  if(!draft.reason?.trim())throw new Error("请填写核实原因。");
  const subjectID=await stableUUID(id,original.eweID);
  const intent=original.kindRawValue==="breeding"?draft.intent:null;
  const value=entryAssociation({eweID:original.eweID,recordID:original.id,kind:original.kindRawValue,occurredAt:original.occurredAt,
    records,relatedID:draft.relatedID??null,intent,expectedRoundID:intent==="newRound"?(original.breedingRoundID??original.id):null,excludingID:original.id});
  const subjects=[{id:subjectID,eweID:original.eweID,result:original.result,relatedBreedingRecordID:draft.relatedID??null,...value,breedingIntent:intent}];
  const transaction=liveRows(models,"SemenTransactionRecord").find(r=>r.sourceRecordID===original.id&&r.kindRawValue==="consumption");
  const reminder=liveRows(models,"CareReminderRecord").find(r=>r.sourceEntityID===original.id);
  const replacement={id,kind:original.kindRawValue,subjects,occurredAt:original.occurredAt,sireID:original.sireID,semenID:original.semenID,
    semenUnitsPerEweText:transaction?.quantityText??null,note:original.note,reminderAt:reminder?.dueAt??null};
  return [{kind:"care.reproduction.correct",body:{correctReproduction:{originalID:original.id,replacement,reason:draft.reason.trim()}},
    streams:[{type:"reproduction",id:original.id},{type:"careBatch",id}],occurredAt:original.occurredAt}];
}
