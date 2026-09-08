import { liveRows, stableUUID } from './nativeEventSnapshots.js';
import { feedStockBalance } from './feedStock.js';
import { decimalSum } from './decimal.js';
import { farmDateText } from './eventExport.js';
export async function additionalBusinessCommands(sheet,v,workspace,{id,date,decimal,listValues}) {
 const rows=m=>liveRows(workspace.models,m),need=(ok,msg)=>{if(!ok)throw new Error(msg);};
 const find=(m,key,value)=>{const found=rows(m).filter(r=>String(r[key]).trim().toLowerCase()===String(value).trim().toLowerCase());need(found.length===1,`${value} 不存在或不唯一。`);return found[0];};
 const spec=(kind,name,args,type,streamID=id,occurredAt=Date.now())=>[{kind,body:{[name]:{_0:args}},streams:[{type,id:streamID}],occurredAt}];
 const note=v['备注']||'';
 if(sheet==='原料批次入库') {
  const ingredient=find('FeedIngredientRecord','name',v['原料名称']);need(ingredient.isActive,'原料已停用。');
  need(!rows('FeedIngredientBatchRecord').some(b=>b.ingredientID===ingredient.id&&b.batchName===v['批次名称']),'该原料已有同名库存批次。');
  const quantity=decimal(v['库存kg'],'库存'),price=v['单价元每kg']==='0'?'0':decimal(v['单价元每kg'],'单价');
  return spec('feedBatch.save','saveBatch',{id:null,ingredientID:ingredient.id,batchName:v['批次名称'],purchaseDate:date('购入日期'),supplier:v['供应商']||'',storageLocation:v['存放位置']||'',pricePerKilogramText:price,purchasedKilogramsText:quantity,packagingKind:'bulk',packageCountText:null,nominalPackageKilogramsText:null,stockWeightConfirmed:true,initialKilogramsText:quantity,remainingKilogramsText:quantity,note,isActive:true},'feedIngredientBatch');
 }
 if(sheet==='TMR制作') {
  const recipe=find('FeedRecipeRecord','name',v['配方名称']),profile=rows('TMRFormulaProfileRecord').find(p=>p.recipeID===recipe.id);
  need(recipe.isActive&&profile,'此配方尚未在 App 中完成 TMR 配方配置。');
  need(!rows('TMRBatchRecord').some(b=>b.batchCode.toLowerCase()===v['批次号'].toLowerCase()),'TMR 批次号已存在。');
  const ingredients=[],requested=new Map();
  for(const [i,text] of listValues(v['用料明细']).entries()) {
   const [name,batchName,planned,actual,...extra]=text.split('|').map(t=>t.trim());need(!extra.length&&actual,'用料明细格式不完整。');
   const ingredient=find('FeedIngredientRecord','name',name),batches=rows('FeedIngredientBatchRecord').filter(b=>b.ingredientID===ingredient.id&&b.batchName===batchName&&b.isActive);
   need(ingredient.isActive&&batches.length===1,`${name} / ${batchName} 库存批次无效。`);const batch=batches[0];
   const quantity=decimal(actual,'实际公斤'),plan=decimal(planned,'计划公斤');
   let item=ingredients.find(d=>d.ingredientID===ingredient.id);if(!item){item={id:await stableUUID(id,`ingredient-${ingredients.length}`),ingredientID:ingredient.id,plannedKilogramsText:'0',loadLines:[]};ingredients.push(item);}
   item.plannedKilogramsText=decimalSum([item.plannedKilogramsText,plan]);item.loadLines.push({id:await stableUUID(id,`load-${i}`),ingredientBatchID:batch.id,actualKilogramsText:quantity});requested.set(batch.id,decimalSum([requested.get(batch.id)||'0',quantity]));
  }
  const components=rows('FeedRecipeComponentRecord').filter(c=>c.recipeID===recipe.id),ids=new Set(components.map(c=>c.ingredientID));
  need(ingredients.length&&ingredients.length===ids.size&&ingredients.every(i=>ids.has(i.ingredientID)),'用料必须完整覆盖配方的全部原料。');
  need(components.every(c=>Number(c.kilogramsText)>0),'配方包含无效用量。');
  for(const [batchID,quantity] of requested){const batch=rows('FeedIngredientBatchRecord').find(b=>b.id===batchID),balance=feedStockBalance(batch,rows('FeedStockTransactionRecord'));need(balance!=null&&Number(balance)>=Number(quantity),`${batch.batchName} 库存不足或期初重量未确认；可用 ${balance??'未知'} kg。`);}
  return spec('tmr.produceTMRBatch','produceBatch',{id,formulaID:recipe.id,expectedFormulaRevision:profile.formulaRevision,sourcePlanID:null,sourcePlanRevision:null,sourcePlanDate:null,sourceMeals:null,batchCode:v['批次号'],producedAt:date('发生日期'),ingredients,note},'tmrBatch',id,date('发生日期'));
 }
 if(sheet==='TMR投喂') {
  const batch=find('TMRBatchRecord','batchCode',v['TMR批次号']);need(batch.statusRawValue!=='closed','此 TMR 批次已关闭。');
  const meal=({早:'morning',中:'noon',晚:'evening',全天汇总:'allDaySummary'})[v['顿次']];need(meal,'顿次请选择早、中、晚或全天汇总。');const at=date('发生日期'),day=t=>farmDateText(t,workspace.farm.timeZoneIdentifier||'Asia/Shanghai',false);
  need(at>=batch.producedAt,'投喂时间不能早于生产时间。');
  const allocations=[];
  for(const [i,text] of listValues(v['投喂分配明细']).entries()) {
   const [name,count,amount,...extra]=text.split('|').map(t=>t.trim());need(!extra.length&&amount,'投喂分配明细格式不完整。');const pen=find('PenRecord','name',name);
   need(pen.isActive&&/^\d+$/.test(count)&&Number.isSafeInteger(+count)&&+count>0,'圈舍必须有效，实际羊数必须为正整数。');need(!allocations.some(a=>a.penID===pen.id),'同一圈舍不能重复分配。');
   const runs=new Set(rows('TMRFeedingAllocationRecord').filter(a=>a.penID===pen.id).map(a=>a.runID));
   const meals=rows('TMRFeedingRunRecord').filter(r=>runs.has(r.id)&&r.formulaID===batch.formulaID&&day(r.occurredAt)===day(at)).map(r=>r.mealRawValue);
   need(!meals.some(m=>m===meal||m==='allDaySummary'||meal==='allDaySummary'),`${name} 同日同配方的顿次记录发生冲突，请核对已有投喂。`);
   allocations.push({id:await stableUUID(id,`allocation-${i}`),feedRecordID:await stableUUID(id,`feed-${i}`),penID:pen.id,planID:null,planRevision:null,actualHeadCountSnapshot:+count,actualKilogramsText:decimal(amount,'实际投喂量'),targetKilogramsTextSnapshot:null});
  }
  const balance=decimalSum(rows('TMRBatchMovementRecord').filter(m=>m.batchID===batch.id).map(m=>m.deltaKilogramsText));need(allocations.length&&Number(balance)>=Number(decimalSum(allocations.map(a=>a.actualKilogramsText))),`TMR 可用库存不足；当前 ${balance} kg。`);
  return spec('tmr.recordTMRFeeding','recordFeeding',{id,batchID:batch.id,expectedBatchRevision:batch.revision,occurredAt:at,meal,allocations,reopenCompletions:null,note},'tmrBatch',batch.id,at);
 }
 return null;
}
