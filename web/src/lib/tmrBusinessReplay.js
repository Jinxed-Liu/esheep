import { stableUUID } from './nativeEventSnapshots.js';
import { decimalSum,decimalMultiply,decimalDivide,decimalRound,negate } from './decimal.js';
export const tmrReplayKinds=new Set(['feedBatch.save','tmr.produceTMRBatch','tmr.recordTMRFeeding']);
export async function replayTMR(kind,a,{rows,get,put,primary,at}) {
 const normalized=t=>decimalRound(t,3),mealName=m=>({morning:'早',noon:'中',evening:'晚',allDaySummary:'全天汇总'})[m];
 if(kind==='feedBatch.save') {put('FeedIngredientBatchRecord',{...a,id:a.id??primary('feedIngredientBatch'),packagingKindRawValue:a.packagingKind});return;}
 if(kind==='tmr.produceTMRBatch') {
  const recipe=get('FeedRecipeRecord',a.formulaID),profile=rows('TMRFormulaProfileRecord').find(p=>p.recipeID===recipe.id),plan=a.sourcePlanID?get('TMRFeedingPlanRecord',a.sourcePlanID):null;
  if(!profile&&!plan)throw new Error('TMR 配方档案缺失。');
  const snapshot=plan?JSON.parse(plan.componentSnapshotJSON):rows('FeedRecipeComponentRecord').filter(c=>c.recipeID===recipe.id).sort((a,b)=>a.id.localeCompare(b.id)).map(c=>{const ingredient=get('FeedIngredientRecord',c.ingredientID);return {id:c.id,ingredientID:ingredient.id,ingredientName:ingredient.name,quantityText:normalized(c.kilogramsText),unit:ingredient.unit,pricePerKilogramText:c.pricePerKilogramText,nutrientSnapshotJSON:c.nutrientSnapshotJSON||ingredient.nutrientSnapshotJSON,dryMatterText:ingredient.dryMatterText};});
  const total=normalized(decimalSum(a.ingredients.flatMap(i=>i.loadLines.map(l=>l.actualKilogramsText))));
  put('TMRBatchRecord',{id:a.id,batchCode:a.batchCode,formulaID:a.formulaID,formulaRevision:plan?.formulaRevision??profile.formulaRevision,formulaNameSnapshot:plan?.formulaNameSnapshot??recipe.name,quantityBasisRawValue:plan?.quantityBasisRawValue??profile.quantityBasisRawValue,referenceHeadCountSnapshot:plan?.referenceHeadCountSnapshot??profile.referenceHeadCount,componentSnapshotJSON:JSON.stringify(snapshot),sourcePlanID:a.sourcePlanID,sourcePlanRevision:a.sourcePlanRevision,sourcePlanDate:a.sourcePlanDate,sourcePlanMealsJSON:a.sourceMeals?JSON.stringify(a.sourceMeals):null,producedAt:a.producedAt,producedKilogramsText:total,statusRawValue:'available',note:a.note});
  for(const [index,i] of a.ingredients.entries()) {
   const component=snapshot.find(c=>c.ingredientID===i.ingredientID),actual=decimalSum(i.loadLines.map(l=>l.actualKilogramsText));if(!component)throw new Error('TMR 原料快照缺失。');
   const priced=i.loadLines.filter(l=>get('FeedIngredientBatchRecord',l.ingredientBatchID).pricePerKilogramText!=null),price=priced.length?decimalDivide(decimalSum(priced.map(l=>decimalMultiply(l.actualKilogramsText,get('FeedIngredientBatchRecord',l.ingredientBatchID).pricePerKilogramText))),decimalSum(priced.map(l=>l.actualKilogramsText)),4):null;
   put('TMRBatchIngredientRecord',{id:i.id,batchID:a.id,ingredientID:i.ingredientID,ingredientNameSnapshot:component.ingredientName,plannedKilogramsText:normalized(i.plannedKilogramsText),actualKilogramsText:normalized(actual),unitSnapshot:component.unit,pricePerKilogramTextSnapshot:price,nutrientSnapshotJSON:component.nutrientSnapshotJSON,dryMatterTextSnapshot:component.dryMatterText,sortOrder:index});
   for(const [order,l] of i.loadLines.entries()) {
    const stock=get('FeedIngredientBatchRecord',l.ingredientBatchID);
    put('TMRBatchLoadLineRecord',{...l,batchID:a.id,batchIngredientID:i.id,ingredientID:i.ingredientID,ingredientBatchNameSnapshot:stock.batchName,actualKilogramsText:normalized(l.actualKilogramsText),sortOrder:order});
    put('FeedStockTransactionRecord',{id:await stableUUID(l.id,'tmr-production-consumption'),ingredientBatchID:stock.id,kindRawValue:'consumption',quantityText:normalized(l.actualKilogramsText),occurredAt:a.producedAt,sourceRecordID:a.id,sourceLineID:l.id,note:`制作 TMR ${a.batchCode} 扣减`});
   }
  }
  put('TMRBatchMovementRecord',{id:await stableUUID(a.id,'tmr-production-movement'),batchID:a.id,kindRawValue:'production',deltaKilogramsText:total,occurredAt:a.producedAt,sourceRecordID:a.id,note:'制作入账'});return;
 }
 const batch=get('TMRBatchRecord',a.batchID),ingredients=rows('TMRBatchIngredientRecord').filter(i=>i.batchID===batch.id).sort((a,b)=>a.sortOrder-b.sortOrder);if(!ingredients.length)throw new Error('TMR 批次用料缺失。');
 put('TMRFeedingRunRecord',{id:a.id,batchID:batch.id,batchCodeSnapshot:batch.batchCode,formulaID:batch.formulaID,formulaRevision:batch.formulaRevision,formulaNameSnapshot:batch.formulaNameSnapshot,mealRawValue:a.meal,occurredAt:a.occurredAt,note:a.note,batchRevisionBefore:a.expectedBatchRevision,batchRevisionAfter:a.expectedBatchRevision+1});
 for(const allocation of a.allocations) {
  const pen=get('PenRecord',allocation.penID),feedID=allocation.feedRecordID;
  put('FeedRecord',{id:feedID,penID:pen.id,recipeID:batch.formulaID,modeRawValue:'limited',occurredAt:a.occurredAt,note:a.note,mealName:mealName(a.meal),feederName:'',recipeHeadCountSnapshot:batch.referenceHeadCountSnapshot,actualHeadCountSnapshot:allocation.actualHeadCountSnapshot});
  let assigned='0';const total=decimalSum(ingredients.map(i=>i.actualKilogramsText));
  for(const [index,i] of ingredients.entries()) {
   const amount=index===ingredients.length-1?normalized(decimalSum([allocation.actualKilogramsText,negate(assigned)])):decimalDivide(decimalMultiply(allocation.actualKilogramsText,i.actualKilogramsText),total,3);assigned=decimalSum([assigned,amount]);
   put('FeedRecordLine',{id:await stableUUID(feedID,`tmr-feed-line:${i.ingredientID}`),feedRecordID:feedID,ingredientID:i.ingredientID,kilogramsText:amount,ingredientNameSnapshot:i.ingredientNameSnapshot,pricePerKilogramTextSnapshot:i.pricePerKilogramTextSnapshot,nutrientSnapshotJSON:i.nutrientSnapshotJSON,unitSnapshot:i.unitSnapshot,dryMatterTextSnapshot:i.dryMatterTextSnapshot});
  }
  put('TMRFeedingAllocationRecord',{...allocation,runID:a.id,batchID:batch.id,penNameSnapshot:pen.name,actualKilogramsText:normalized(allocation.actualKilogramsText)});
 }
 const total=normalized(decimalSum(a.allocations.map(l=>l.actualKilogramsText)));
 put('TMRBatchMovementRecord',{id:await stableUUID(a.id,'tmr-feeding-movement'),batchID:batch.id,kindRawValue:'feeding',deltaKilogramsText:negate(total),occurredAt:a.occurredAt,sourceRecordID:a.id,note:`${mealName(a.meal)}投喂`});
 const balance=decimalSum(rows('TMRBatchMovementRecord').filter(m=>m.batchID===batch.id).map(m=>m.deltaKilogramsText));
 Object.assign(batch,{revision:batch.revision+1,updatedAt:at,statusRawValue:Number(balance)>0?'available':'exhausted'});
 for(const reopen of a.reopenCompletions??[])Object.assign(get('TMRMealCompletionRecord',reopen.completionID),{deletedAt:at,updatedAt:at});
}
