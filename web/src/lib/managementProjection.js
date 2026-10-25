import { resolveReproductionState } from "./reproductionCycles.js";
import { isReproductionCheckEligible, isPreBreedingLamb } from "./reproductionManagement.js";
import { feedStockBalance } from './feedStock.js';
import { liveRows,stableUUID } from "./nativeEventSnapshots.js";
import { decimalSum,negate } from "./decimal.js";
import { farmDateText } from "./eventExport.js";
import { parseBusinessDate } from "./businessCommands.js";
export async function managementProjection(models,farm,now=Date.now()) {
 const rows=m=>liveRows(models,m), all=m=>models[m]??[];
 const sheep=rows("SheepRecord"), present=sheep.filter(s=>s.statusRawValue==="active"&&!s.isHistoricalArchive&&s.enteredAt<=now), pens=rows("PenRecord"), tz=farm.timeZoneIdentifier||"Asia/Shanghai";
 const sumTransactions=(model,key,id)=>decimalSum(rows(model).filter(r=>r[key]===id).map(r=>r.kindRawValue==="consumption"?negate(r.quantityText):r.quantityText));
 const reproductionGroups=new Map();for(const r of all("ReproductionRecord")){const values=reproductionGroups.get(r.eweID)??[];values.push(r);reproductionGroups.set(r.eweID,values);}
 const reproductionStates=Object.fromEntries(sheep.filter(s=>s.sexRawValue==="ewe").map(s=>[s.id,resolveReproductionState(s.id,reproductionGroups.get(s.id)??[],now)]));
 let reproductionSettings=null;try{reproductionSettings=JSON.parse(rows("FarmCareRuleRecord")[0]?.reproductionSettingsJSON??"null");}catch{}
 const reproductionPreBreedingLambIDs=sheep.filter(s=>s.sexRawValue==="ewe"&&isPreBreedingLamb(s,reproductionGroups.get(s.id)??[],reproductionSettings,tz,now)).map(s=>s.id);
 const reproductionReview=sheep.filter(s=>reproductionStates[s.id]?.issues.length&&!reproductionPreBreedingLambIDs.includes(s.id)).map(s=>({sheepID:s.id,earTag:s.earTag,isCurrentlyPresent:s.statusRawValue==="active"&&!s.isHistoricalArchive&&s.enteredAt<=now,...reproductionStates[s.id]}));
 const selectedPens=new Set((reproductionSettings?.selectedPenIDs??[]).map(id=>id.toLowerCase()));
 const activePens=new Set(pens.filter(p=>p.isActive!==false).map(p=>p.id.toLowerCase()));
 const reproductionScope=present.filter(s=>s.sexRawValue==="ewe"&&reproductionSettings?.scopeConfigured&&selectedPens.has(s.currentPenID?.toLowerCase())&&activePens.has(s.currentPenID?.toLowerCase()));
 const reproductionMembers=reproductionScope.filter(s=>isReproductionCheckEligible(s,reproductionGroups.get(s.id)??[],reproductionStates[s.id],reproductionSettings,tz,now));
 const reproductionSummary=Object.fromEntries(["pregnant","open","recheck","unexamined","uncertain"].map(state=>[state,reproductionMembers.filter(s=>reproductionStates[s.id]?.pregnancy===state).length]));
 const careItems=rows("InventoryLotRecord").map(l=>({...l,name:l.catalogName,category:l.kindRawValue==="vaccination"?"疫苗":"药品",stock:sumTransactions("InventoryTransactionRecord","inventoryLotID",l.id),expired:l.expiresAt!=null&&l.expiresAt<now}));
 const ingredientBatches=rows("FeedIngredientBatchRecord").map(b=>({...b,balance:feedStockBalance(b,rows("FeedStockTransactionRecord"))}));
 const tmrBatches=rows("TMRBatchRecord").map(b=>({...b,balance:decimalSum(rows("TMRBatchMovementRecord").filter(m=>m.batchID===b.id).map(m=>m.deltaKilogramsText))}));
 const batches=rows("ProductionBatchRecord").map(b=>{const members=rows("BatchMembershipRecord").filter(m=>m.batchID===b.id&&m.leftAt==null);const ids=new Set(members.map(m=>m.sheepID));return {...b,stage:b.purpose,members:members.map(m=>({...m,earTag:sheep.find(s=>s.id===m.sheepID)?.earTag??m.sheepID})),sheepCount:members.length,penCount:new Set(present.filter(s=>ids.has(s.id)).map(s=>s.currentPenID).filter(Boolean)).size,startDate:farmDateText(b.startedAt,tz,false),status:b.statusRawValue==="completed"?"已完成":"进行中"};});
 const alerts=[];const day=d=>parseBusinessDate(farmDateText(d,tz,false),tz);const plus=(d,n)=>parseBusinessDate(new Date(Date.parse(farmDateText(d,tz,false)+"T00:00:00Z")+n*86400000).toISOString().slice(0,10),tz);const today=day(now);
 const sig=(facts,lamb=false)=>facts.length?facts.map(r=>lamb?`${r.id}:${r.lambingRecordID}:${r.revision}:${r.isStillborn}:${r.deletedAt!=null}`:`${r.id}:${r.revision}:${r.deletedAt!=null}`).sort().join(","):"none";
 async function alert(kind,s,source,fingerprint,title,description,dueAt,action){const id=await stableUUID(farm.id,["operational-alert",kind,s.id,source??"none",fingerprint].join(":"));if(rows("FarmAlertDeferralRecord").some(d=>d.alertID===id&&d.conditionFingerprint===fingerprint&&d.deferredUntil>now&&d.deferredUntil>d.updatedAt&&d.deferredUntil-d.updatedAt<=8*86400000))return;alerts.push({id,kind,subjectID:s.id,title,description,dueAt,action,conditionFingerprint:fingerprint,count:1,unit:"只",tone:dueAt<=today?"warning":"neutral"});}
 const rule=rows("FarmCareRuleRecord").sort((a,b)=>b.updatedAt-a.updatedAt)[0];
 if(rule?.operationalAlertsConfiguredAt!=null&&rule.weaningAgeDays>0){const lead=Math.min(30,Math.max(0,rule.warningLeadDays));
 for(const s of present){if(s.birthAt!=null&&!rows("WeaningRecord").some(w=>w.sheepID===s.id)){
 const due=plus(s.birthAt,rule.weaningAgeDays),born=day(s.birthAt),purpose=s.purpose?.trim()??"";
 const offspring=rows("LambingOffspringRecord").filter(o=>o.sheepID===s.id&&!o.isStillborn&&rows("ReproductionRecord").some(r=>r.id===o.lambingRecordID&&r.kindRawValue==="lambing"));
 const eligibility=["哺乳羔羊","哺乳羔"].includes(purpose)?`purpose:suckling:${s.revision}`:!purpose||purpose==="未分类"?offspring.length?`lambing:${sig(offspring,true)}:${s.revision}`:s.createdAt>=rule.operationalAlertsConfiguredAt||due>=day(rule.operationalAlertsConfiguredAt)?`unclassified-current:${s.revision}`:null:null;
 if(eligibility&&plus(due,-lead)<=today){const overdue=due<=today;await alert(overdue?"weaningOverdue":"weaningDueSoon",s,null,`${Math.floor(born/1000)}:${rule.weaningAgeDays}:${lead}:${overdue?"overdue":"due-soon"}:${eligibility}:${sig(all("WeaningRecord").filter(w=>w.sheepID===s.id))}`,`${s.earTag} · ${overdue?"超龄未断奶":"断奶即将到期"}`,`断奶日龄 ${rule.weaningAgeDays} 天；到期 ${farmDateText(due,tz,false)}`,due,"weaning");}}
 const pen=all("PenRecord").find(p=>p.id===s.currentPenID);if(!pen||!pen.isActive||pen.deletedAt!=null)await alert("invalidPen",s,s.currentPenID,`${s.currentPenID??"none"}:${pen?`${pen.revision}:${pen.isActive}:${pen.deletedAt!=null}`:"missing"}:${s.revision}`,`${s.earTag} · 未分有效圈舍`,s.currentPenID?"当前圈舍已停用、删除或引用失效。":"当前在场羊只尚未分圈。",today,"transfer");
 if(s.sexRawValue==="ewe"){
   const facts=reproductionGroups.get(s.id)??[],state=reproductionStates[s.id],breeding=state?.breeding;
   if(breeding&&!state.check&&state.breedingRoundID&&!facts.some(r=>r.kindRawValue==="pregnancyCheck"&&r.deletedAt==null&&r.occurredAt>=breeding.occurredAt&&r.occurredAt<=now)){
     const due=plus(breeding.occurredAt,rule.pregnancyCheckDays),overdue=due<=today;
     if(plus(due,-lead)<=today)await alert(overdue?"pregnancyCheckOverdue":"pregnancyCheckDueSoon",s,breeding.id,`${breeding.id}:${Math.floor(day(breeding.occurredAt)/1000)}:${rule.pregnancyCheckDays}:${lead}:${overdue?"overdue":"due-soon"}:${sig(facts.filter(r=>r.occurredAt>=breeding.occurredAt))}`,`${s.earTag} · ${overdue?"配种后逾期未孕检":"孕检即将到期"}`,`本轮配种后 ${rule.pregnancyCheckDays} 天；到期 ${farmDateText(due,tz,false)}`,due,"reproduction");
   }
 }

 }}
 for(const item of reproductionReview){const s=sheep.find(s=>s.id===item.sheepID);await alert("reproductionReview",s,item.check?.id??item.breeding?.id??null,`reproduction-review:${item.cycleID.toUpperCase()}:${item.breedingRoundID?.toUpperCase()??"none"}:${item.issues.join(";")}`,`${s.earTag} · 繁殖资料待核实`,item.issues.join("；"),today,"reproduction");}
 const relevantReminder=r=>{if(!["pregnancyCheck","expectedLambing"].includes(r.kindRawValue))return true;const state=reproductionStates[r.sheepID];if(!state)return false;return r.kindRawValue==="pregnancyCheck"?state.pregnancy==="unexamined"&&state.check==null&&state.breeding!=null&&state.associations.some(a=>a.recordID===r.sourceEntityID&&a.roundID===state.breedingRoundID):state.pregnancy==="pregnant"&&state.check?.id===r.sourceEntityID;};
 for(const r of rows("CareReminderRecord").filter(r=>r.statusRawValue==="pending"&&r.dueAt<=now&&relevantReminder(r)))alerts.push({id:r.id,title:r.title,description:`${r.note||"护理提醒"} · ${farmDateText(r.dueAt,tz)}`,dueAt:r.dueAt,count:1,unit:"项",tone:"warning",action:r.kindRawValue==="booster"?"health":"reproduction",reminder:r});
 alerts.sort((a,b)=>a.dueAt-b.dueAt||a.id.localeCompare(b.id));
 const tmrMeals=rows("TMRFeedingRunRecord").filter(r=>farmDateText(r.occurredAt,tz,false)===farmDateText(now,tz,false)).map(r=>{
  const allocations=rows("TMRFeedingAllocationRecord").filter(a=>a.runID===r.id),actualKg=Number(decimalSum(allocations.map(a=>a.actualKilogramsText))),planKg=allocations.length&&allocations.every(a=>a.targetKilogramsTextSnapshot!=null)?Number(decimalSum(allocations.map(a=>a.targetKilogramsTextSnapshot))):null;
  const completed=allocations.length&&allocations.every(a=>a.planID&&rows("TMRMealCompletionRecord").some(c=>c.planID===a.planID&&c.penID===a.penID&&c.mealRawValue===r.mealRawValue&&farmDateText(c.localDay,tz,false)===farmDateText(r.occurredAt,tz,false)));
  return {id:r.id,period:({morning:"早",noon:"中",evening:"晚",allDaySummary:"全天汇总"})[r.mealRawValue],time:farmDateText(r.occurredAt,tz).slice(11,16),actualKg,planKg,progress:planKg?Math.round(actualKg/planKg*100):0,status:completed?"completed":"in-progress"};
 });
 return {reproductionStates,reproductionPreBreedingLambIDs,reproductionReview,reproductionSummary,reproductionSettings,reproductionScopeCount:reproductionScope.length,reproductionEligibleCount:reproductionMembers.length,tmrMeals,careItems,ingredientBatches,tmrBatches,batches,alerts,alertRulesConfigured:Boolean(rule?.operationalAlertsConfiguredAt),semenInventory:rows("SemenRecord").map(s=>({...s,balance:decimalSum([s.quantityText||"0",sumTransactions("SemenTransactionRecord","semenID",s.id)])}))};
}
