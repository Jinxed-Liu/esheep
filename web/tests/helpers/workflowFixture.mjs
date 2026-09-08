import schema from '../../../tools/esheep_cloud_checkpoint_schema_v1.json' with {type:'json'};
import { createV2Projection,finishV2Projection } from '../../src/lib/cloudV2Projection.js';
export function workflowFixture(farmID=crypto.randomUUID()) {
 const at=Date.UTC(2026,0,1),records=[];
 function add(model,overrides){const fields=Object.fromEntries(Object.entries(schema[model].fields).map(([k,t])=>[k,t.endsWith('?')?null:t==='UUID'?farmID:t==='Date'?(at-978307200000)/1000:t==='Data'?{json:[]}:t==='Bool'?false:t==='String'?'':0]));const row={model,values:{...fields,id:crypto.randomUUID(),...(model!=="FarmRecord"?{farmID}:{}),...overrides}};records.push(row);return row.values.id;}
 add('FarmRecord',{id:farmID,name:'隔离验证牧场',timeZoneIdentifier:'Asia/Shanghai'});
 const penID=add('PenRecord',{name:'育肥二圈',isActive:true});add('PenRecord',{name:'产羔圈',isActive:true});
 for(const earTag of ['A002','E001','E002','R001'])add('SheepRecord',{earTag,breed:'湖羊',sexRawValue:earTag==='R001'?'ram':'ewe',statusRawValue:'active',purpose:'未分类',isBreedingRam:earTag==='R001',initialPenID:penID,currentPenID:penID});
 const soy=add('FeedIngredientRecord',{name:'豆粕',unit:'千克',isActive:true,nutrientSnapshotJSON:'{}'});
 const tmr=add('FeedRecipeRecord',{name:'隔离TMR',isActive:true});add('TMRFormulaProfileRecord',{recipeID:tmr,formulaRevision:1,quantityBasisRawValue:'wholeGroupDaily',referenceHeadCount:20});add('FeedRecipeComponentRecord',{recipeID:tmr,ingredientID:soy,kilogramsText:'100',nutrientSnapshotJSON:'{}'});
 const modelCounts={};for(const r of records)modelCounts[r.model]=(modelCounts[r.model]??0)+1;
 const manifest={farmID,farmGeneration:3,boundaryEventSequence:0,modelCounts};
 const projection=createV2Projection(records,manifest);const farm={id:farmID,generation:3,timeZoneIdentifier:'Asia/Shanghai'};
 return {farm,projection,workspace:()=>({farm,...finishV2Projection(projection)})};
}
