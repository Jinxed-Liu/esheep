import { decodeCheckpointData } from "./checkpointData.js";

export const labelColors = ["yellow", "green", "red", "white", "orange", "light-blue", "pink", "black", "purple", "dark-blue"];
export const labelColorNames = { yellow:"黄色",green:"绿色",red:"红色",white:"白色",orange:"橙色","light-blue":"浅蓝色",pink:"粉色",black:"黑色",purple:"紫色","dark-blue":"深蓝色" };
export const labelKinds = new Set(["care.sheepLabel.save", "care.sheepLabel.delete", "care.sheepLabels.edit", "care.sheepLabels.patchProfile"]);
export const labelRestriction = color => color === "yellow" ? "仅公羊" : color === "green" ? "仅母羊" : "所有性别";
export const labelAllows = (color, sex) => labelColors.includes(color) && (color === "yellow" ? sex === "ram" : color === "green" ? sex === "ewe" : true);
export const labelIDs = assignment => JSON.parse(assignment?.labelIDsJSON ?? "[]");
export const orderedLabels = (labels, primary) => [...labels].sort((a,b) => Number(b.id === primary)-Number(a.id === primary) || a.sortOrder-b.sortOrder || a.id.localeCompare(b.id));
export function nextPrimary(preferred, ids, labels) {
  const active = labels.filter(l=>l.isActive && ids.includes(l.id));
  return active.some(l=>l.id===preferred) ? preferred : orderedLabels(active)[0]?.id ?? null;
}
export function matchesLabels(ids, selected=[], mode="any") {
  if(mode==="none")return ids.length===0;
  return !selected.length || (mode==="all" ? selected.every(id=>ids.includes(id)) : selected.some(id=>ids.includes(id)));
}
const requireValue = (condition,message) => { if(!condition)throw new Error(message); };
export function labelState(models, farmID) {
  const rows = name => (models[name] ?? []).filter(r=>r.farmID===farmID);
  return {catalog:rows("SheepLabelRecord"),assignments:rows("SheepLabelAssignmentRecord"),sheep:rows("SheepRecord").filter(r=>r.deletedAt==null),changes:rows("SheepLabelChangeRecord")};
}
export function validateLabelAction(action, draft, state, enforceRevision=true) {
  const {catalog,assignments,sheep}=state;
  if(action==="deleteLabel") {
    const current=catalog.find(l=>l.id===draft.id);
    requireValue(current,"标签不存在，可能已经被其他成员删除。");
    if(enforceRevision)requireValue(current.revision===draft.expectedRevision,"标签已由其他成员修改，请刷新后重试。");
    return;
  }
  if(action==="saveLabel") {
    requireValue(draft.name?.trim().length>0 && [...draft.name.trim()].length<=40,"标签名称需为 1–40 字。");
    requireValue(labelColors.includes(draft.color),"标签颜色无效。");
    requireValue(typeof draft.isActive==="boolean" && Number.isSafeInteger(draft.sortOrder) && draft.sortOrder>=0 && (draft.note?.length??0)<=500,"标签设置无效。");
    requireValue(!catalog.some(l=>l.id!==draft.id && l.name.trim().toLowerCase()===draft.name.trim().toLowerCase()),"当前牧场已有同名标签。");
    if(enforceRevision)requireValue((catalog.find(l=>l.id===draft.id)?.revision??0)===draft.expectedRevision,"标签已由其他成员修改，请刷新后重试。");
    const assigned=new Set(assignments.filter(a=>labelIDs(a).includes(draft.id)).map(a=>a.sheepID));
    const invalid=sheep.filter(s=>assigned.has(s.id)&&!labelAllows(draft.color,s.sexRawValue));
    requireValue(!invalid.length,`该颜色与 ${invalid.length} 只羊冲突：${invalid.map(s=>s.earTag).join("、")}。请先移除关联标签。`);
    return;
  }
  const subject=sheep.find(s=>s.id===draft.sheepID);
  requireValue(subject,"羊只不存在或不属于当前牧场。");
  const assignment=assignments.find(a=>a.sheepID===subject.id);
  if(action==="patchProfile") {
    if(enforceRevision)requireValue(subject.revision===draft.expectedRevision,"羊只档案已发生变化，请刷新后重试。");
    requireValue(["ram","ewe","unknown"].includes(draft.sex)&&draft.earTag?.trim()&&draft.breed?.trim(),"请填写有效的耳号、品种与性别。");
    requireValue(!sheep.some(s=>s.id!==subject.id&&s.earTag.trim().toUpperCase()===draft.earTag.trim().toUpperCase()),"耳号已存在。");
    const remaining=labelIDs(assignment).filter(id=>!draft.removeLabelIDs.includes(id));
    requireValue(!catalog.some(l=>remaining.includes(l.id)&&!labelAllows(l.colorRawValue,draft.sex)),"必须明确移除所有与新性别冲突的标签。");
    return;
  }
  requireValue(action==="editLabels","未知标签操作。");
  requireValue(!draft.addIDs.some(id=>draft.removeIDs.includes(id)),"同一标签不能同时添加和移除。");
  for(const id of draft.addIDs) {
    const label=catalog.find(l=>l.id===id);
    requireValue(label,"标签不存在或不属于当前牧场。");
    requireValue(label.isActive&&labelAllows(label.colorRawValue,subject.sexRawValue),`${label.name}：${label.isActive?labelRestriction(label.colorRawValue):"已停用"}。`);
  }
  const ids=[...new Set([...labelIDs(assignment).filter(id=>!draft.removeIDs.includes(id)),...draft.addIDs])];
  if(draft.setsPrimary) {
    if(enforceRevision&&draft.expectedRevision!=null)requireValue((assignment?.revision??0)===draft.expectedRevision,"主标签已发生变化，请刷新后重试。");
    if(draft.primaryLabelID!=null) {
      const l=catalog.find(l=>l.id===draft.primaryLabelID);
      requireValue(ids.includes(draft.primaryLabelID)&&l?.isActive&&labelAllows(l.colorRawValue,subject.sexRawValue),"主标签必须是已关联且适用的启用标签。");
    }
  }
}
export async function labelSpec(action,draft,workspace) {
  const state=labelState(workspace.models,workspace.farm.id);
  const role=workspace.farm.role ?? workspace.farm.memberRole ?? workspace.profile.role;
  requireValue(["owner","administrator","worker"].includes(role),"当前账号没有牧场记录权限。");
  if(action==="saveLabel"||action==="deleteLabel")requireValue(["owner","administrator"].includes(role)||workspace.capabilities?.includes?.("manageCatalogs"),"需要标签目录管理权限。");
  validateLabelAction(action,draft,state);
  const kind=action==="saveLabel"?"care.sheepLabel.save":action==="deleteLabel"?"care.sheepLabel.delete":action==="editLabels"?"care.sheepLabels.edit":"care.sheepLabels.patchProfile";
  if(action==="patchProfile") {
    const stream={type:"sheepProfile",id:draft.sheepID};
    const raw=workspace.models.ESheepCloudStreamState?.find(s=>s.streamType===stream.type&&s.streamID===stream.id)?.fieldVersionsData;
    const entries=raw?decodeCheckpointData(raw):[];
    requireValue(Array.isArray(entries),"牧场字段版本记录格式不正确。");
    const nullDigest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode('null'))),b=>b.toString(16).padStart(2,"0")).join("");
    const values={earTag:{type:"string",value:draft.earTag},breed:{type:"string",value:draft.breed},sex:{type:"string",value:draft.sex},birthAt:draft.birthAt==null?null:{type:"date",value:draft.birthAt},note:{type:"string",value:draft.note}};
    values.currentParity=draft.currentParity==null?null:{type:"integer",value:draft.currentParity};
    values.parityRecordedAt=draft.parityRecordedAt==null?null:{type:"date",value:draft.parityRecordedAt};
    const fields=Object.keys(values).map(field=>({stream,field,observedVersion:entries.find(e=>e.field===field)?.version??0,baseValueDigest:entries.find(e=>e.field===field)?.valueDigest??nullDigest}));
    const changes=Object.entries(values).map(([field,value])=>({field,mutation:value?{action:"set",value}:{action:"clear"}}));
    return {kind,body:{sheepLabels:{_0:{[action]:{_0:draft}}}},streams:[stream],fields,changes,occurredAt:Date.now()};
  }
  return {kind,body:{sheepLabels:{_0:{[action]:{_0:draft}}}},streams:[{type:action==="saveLabel"||action==="deleteLabel"?"sheepLabel":"sheepLabels",id:action==="saveLabel"||action==="deleteLabel"?draft.id:draft.sheepID}],occurredAt:Date.now()};
}
export function applyLabelAction(action,draft,models,{farmID,accountID,at},enforceRevision=false) {
  for(const name of ["SheepLabelRecord","SheepLabelAssignmentRecord","SheepLabelChangeRecord"])models[name]??=[];
  const state=labelState(models,farmID), changeID=action==="saveLabel"||action==="deleteLabel"?draft.changeID:draft.id;
  if(state.changes.some(c=>c.id===changeID))return;
  validateLabelAction(action,draft,state,enforceRevision);
  const snapshots=state.catalog.map(l=>({id:l.id,name:l.name,color:l.colorRawValue,note:l.note,sortOrder:l.sortOrder,isActive:l.isActive,revision:l.revision}));
  let detail,subjectID=null;
  if(action==="deleteLabel") {
    const record=state.catalog.find(l=>l.id===draft.id);
    requireValue(record,"标签不存在，可能已经被其他成员删除。");
    const affected=state.assignments.filter(a=>labelIDs(a).includes(draft.id));
    const remainingCatalog=state.catalog.filter(l=>l.id!==draft.id);
    for(const a of affected) {
      const ids=labelIDs(a).filter(id=>id!==draft.id);
      a.labelIDsJSON=JSON.stringify(ids);
      a.primaryLabelID=nextPrimary(a.primaryLabelID,ids,remainingCatalog);
      a.revision=(a.revision??0)+1;a.updatedAt=at;
    }
    models.SheepLabelRecord=models.SheepLabelRecord.filter(l=>!(l.farmID===farmID&&l.id===draft.id));
    state.catalog=remainingCatalog;
    detail=`彻底删除 ${record.name}；清理 ${affected.length} 只羊的关联`;
  } else if(action==="saveLabel") {
    let record=state.catalog.find(l=>l.id===draft.id);
    const wasNew=!record;
    if(!record){record={id:draft.id,farmID,revision:0};models.SheepLabelRecord.push(record);state.catalog.push(record);}
    Object.assign(record,{name:draft.name.trim(),colorRawValue:draft.color,note:draft.note.trim(),sortOrder:draft.sortOrder,isActive:draft.isActive,revision:record.revision+1,updatedAt:at});
    for(const a of state.assignments) {
      const primary=nextPrimary(a.primaryLabelID,labelIDs(a),state.catalog);
      if(primary!==a.primaryLabelID)Object.assign(a,{primaryLabelID:primary,revision:a.revision+1,updatedAt:at});
    }
    detail=`${wasNew?"新建":"更新"} ${record.name} · ${labelColorNames[draft.color]} · ${draft.isActive?"启用":"停用"}`;
  } else {
    subjectID=draft.sheepID;
    const subject=state.sheep.find(s=>s.id===subjectID);
    let a=state.assignments.find(a=>a.sheepID===subjectID);
    if(!a){a={id:subjectID,farmID,sheepID:subjectID,labelIDsJSON:"[]",primaryLabelID:null,revision:0};models.SheepLabelAssignmentRecord.push(a);}
    const removed=action==="patchProfile"?draft.removeLabelIDs:draft.removeIDs;
    const ids=[...new Set([...labelIDs(a).filter(id=>!removed.includes(id)),...(draft.addIDs??[])])].sort();
    a.labelIDsJSON=JSON.stringify(ids);a.primaryLabelID=nextPrimary(draft.setsPrimary?draft.primaryLabelID:a.primaryLabelID,ids,state.catalog);a.revision++;a.updatedAt=at;
    const names=values=>state.catalog.filter(l=>values.includes(l.id)).map(l=>`${l.name}（${labelColorNames[l.colorRawValue]}）`).join("、");
    if(action==="patchProfile") {
      detail=`${draft.earTag} · ${subject.sexRawValue} → ${draft.sex}；移除：${names(removed)}`;
      Object.assign(subject,{earTag:draft.earTag.trim(),breed:draft.breed.trim(),sexRawValue:draft.sex,birthAt:draft.birthAt,note:draft.note.trim(),revision:subject.revision+1,updatedAt:at});
      if(draft.sex!=="ram")subject.isBreedingRam=false;
    } else detail=`${subject.earTag} · 添加：${names(draft.addIDs)}；移除：${names(removed)}${draft.setsPrimary?`; 主标签：${state.catalog.find(l=>l.id===a.primaryLabelID)?.name??"无"}`:""}`;
  }
  models.SheepLabelChangeRecord.push({id:changeID,farmID,sheepID:subjectID,accountID,title:action==="saveLabel"?`维护标签：${draft.name}`:action==="deleteLabel"?"彻底删除标签":action==="patchProfile"?"修改羊只档案与标签":"修改羊只标签",detail,snapshotsJSON:JSON.stringify({before:snapshots,after:state.catalog.map(l=>({id:l.id,name:l.name,color:l.colorRawValue,note:l.note,sortOrder:l.sortOrder,isActive:l.isActive,revision:l.revision}))}),occurredAt:at});
}
