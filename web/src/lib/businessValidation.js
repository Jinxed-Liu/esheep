import { decimalSum,decimalMultiply,negate } from './decimal.js';
const live=(models,name)=>(models[name]??[]).filter(r=>r.deletedAt==null);
const requireValue=(condition,message)=>{if(!condition)throw new Error(message);};
const order=(a,b)=>a.occurredAt-b.occurredAt||(a.recordedAt??a.createdAt)-(b.recordedAt??b.createdAt)||a.id.localeCompare(b.id);
export function penAtTime(s,at,models){const transfers=live(models,'TransferRecord').filter(t=>t.sheepID===s.id).sort(order);return transfers.filter(t=>t.occurredAt<=at).at(-1)?.toPenID??transfers.find(t=>t.occurredAt>at)?.fromPenID??s.initialPenID??null;}
export function presentAtTime(s,at,models){if(s.isHistoricalArchive||s.enteredAt>at)return false;const events=[...live(models,'TransferRecord').filter(r=>r.sheepID===s.id).map(r=>({...r,type:'transfer'})),...live(models,'RemovalRecord').filter(r=>r.sheepID===s.id).map(r=>({...r,type:'removal'}))].filter(r=>r.occurredAt<=at).sort(order);return events.at(-1)?.type!=='removal'&&(s.removedAt==null||s.removedAt>at||events.at(-1)?.type==='transfer');}
export function validateBusinessSpecifications(specs,{models}) {
 const rows=name=>live(models,name),get=(name,id)=>rows(name).find(r=>r.id===id),balance=(model,key,id,initial='0')=>decimalSum([initial,...rows(model).filter(r=>r[key]===id).map(r=>r.kindRawValue==='consumption'?negate(r.quantityText):r.quantityText)]);
 for(const spec of specs){const value=Object.values(spec.body)[0],a=value._0??value;switch(spec.kind){
 case 'sheep.add':if(a.penID)requireValue(get('PenRecord',a.penID)?.isActive,'初始圈舍已停用。');break;
 case 'transfer.record':{const s=get('SheepRecord',a.sheepID);requireValue(penAtTime(s,a.occurredAt,models)!==a.toPenID,'羊只在发生时间已经位于目标圈舍，无需重复转群。');break;}
 case 'productionBatch.create':for(const id of a.sheepIDs){const s=get('SheepRecord',id);requireValue(s?.statusRawValue==='active'&&!s.isHistoricalArchive,`羊只 ${s?.earTag??id} 当前不在场。`);requireValue(s.enteredAt<=a.startedAt,`批次开始日期早于 ${s.earTag} 的入场日期。`);requireValue(!rows('BatchMembershipRecord').some(m=>m.sheepID===id&&m.leftAt==null),`${s.earTag} 已在其他生产批次中，请先脱离原批次。`);}break;
 case 'batchMembership.leave':{const m=rows('BatchMembershipRecord').find(m=>m.sheepID===a.sheepID&&m.batchID===a.batchID&&m.leftAt==null);requireValue(m,'没有可脱离的批次成员关系。');requireValue(a.leftAt>=m.joinedAt,'脱离日期不能早于加入日期。');break;}
 case 'feed.recordLegacy':requireValue(get('PenRecord',a.penID)?.isActive,'投喂圈舍已停用。');requireValue(new Set(a.lines.map(l=>l.ingredientID)).size===a.lines.length,'同一种原料请合并到一条明细。');break;
 case 'care.healthCatalog.upsert':requireValue(a.reminderIntervalDays==null||a.reminderIntervalDays<=3650,'复免间隔不能超过 3650 天。');break;
 case 'care.inventory.adjust':requireValue(Number(decimalSum([balance('InventoryTransactionRecord','inventoryLotID',a.lotID),a.quantityDeltaText]))>=0,'调整后药品库存不能为负数。');break;
 case 'care.semen.adjust':requireValue(Number(decimalSum([balance('SemenTransactionRecord','semenID',a.semenID,get('SemenRecord',a.semenID)?.quantityText||'0'),a.quantityDeltaText]))>=0,'调整后冻精库存不能为负数。');break;
 case 'care.health.recordBatch':if(a.inventoryLotID){const lot=get('InventoryLotRecord',a.inventoryLotID);requireValue(lot?.isActive,'所选药品库存批次已停用。');requireValue(Number(decimalSum([balance('InventoryTransactionRecord','inventoryLotID',a.inventoryLotID),negate(decimalMultiply(a.dosePerSubjectText,a.subjectIDs.length))]))>=0,'药品库存不足以覆盖本次全部羊只的用量。');}break;
 case 'care.reproduction.recordBatch':if(a.semenID){const semen=get('SemenRecord',a.semenID);requireValue(!semen.donorID||get('SemenDonorRecord',semen.donorID)?.statusRawValue==='active','冻精供体已停用。');requireValue(Number(decimalSum([balance('SemenTransactionRecord','semenID',a.semenID,semen.quantityText||'0'),negate(decimalMultiply(a.semenUnitsPerEweText??'1',a.subjects.length))]))>=0,'冻精库存不足以覆盖全部母羊。');}break;
 case 'care.lambing.record':{
 requireValue(a.occurredAt<=Date.now(),'产羔时间不能在未来。');
 const next=rows('ReproductionRecord').filter(r=>r.eweID===a.eweID&&['lambing','parityBaseline'].includes(r.kindRawValue)&&r.occurredAt>a.occurredAt).sort(order)[0];requireValue(next?.kindRawValue!=='lambing'||next.parity===a.parity+1,'本次产羔胎次与后续产羔记录冲突。');
 for(const l of a.offspring){if(!l.birthWeightText){requireValue(l.weightOccurredAt==null,'填写称重日期时必须填写羔羊体重。');continue;}const at=l.weightOccurredAt??a.occurredAt;requireValue(at>=a.occurredAt&&at<=Date.now(),'羔羊称重日期必须在出生之后且不能在未来。');if(at-a.occurredAt>86400000)requireValue(!l.isStillborn&&l.createSheepRecord,'出生 24 小时后的称重需要关联已建档的活羔羊。');}break;
 }
 case 'care.sheepPedigree.update':{const child=get('SheepRecord',a.sheepID),dam=a.damID&&get('SheepRecord',a.damID),donor=a.semenDonorID&&get('SemenDonorRecord',a.semenDonorID),sire=(donor?.linkedRamID??a.sireID)&&get('SheepRecord',donor?.linkedRamID??a.sireID);requireValue(!dam||dam.sexRawValue==='ewe','母本必须是母羊。');for(const p of [dam,sire].filter(Boolean)){requireValue(p.id!==child.id,'不能把羊只本身设为父母。');requireValue(child.birthAt==null||p.birthAt==null||p.birthAt<child.birthAt,'父母的出生日期必须早于子代。');const queue=[p.id],seen=new Set();while(queue.length){const id=queue.pop();requireValue(id!==child.id,'系谱关系会形成循环。');if(seen.has(id))continue;seen.add(id);const r=get('SheepRecord',id);queue.push(...[r?.damID,r?.sireID].filter(Boolean));}}break;}
 case 'care.careRules.update':case 'care.operationalAlertRules.update':requireValue(a.pregnancyCheckDays>=1&&a.pregnancyCheckDays<=365&&a.gestationDays>=100&&a.gestationDays<=220,'孕检间隔应为 1–365 天，妊娠周期应为 100–220 天。');if(a.weaningAgeDays!=null)requireValue(a.weaningAgeDays>=1&&a.weaningAgeDays<=365&&a.warningLeadDays>=0&&a.warningLeadDays<=30,'断奶日龄应为 1–365 天，提前预警应为 0–30 天。');break;
 }
 }
}
