import {resolveReproductionState} from './reproductionCycles.js';
import {stableUUID} from './nativeEventSnapshots.js';
import {parseBusinessDate,listValues} from './businessCommands.js';

// Read-only preflight. Imported historical ambiguity stays visible and does
// not become a fabricated breeding or parity correction.
export async function reviewReproductionImports(records,workspace){
 const key=value=>String(value??'').normalize('NFC').trim().toUpperCase();
 const tz=workspace.farm.timeZoneIdentifier||'Asia/Shanghai';
 const identifiers=new Map((workspace.models?.SheepRecord??[]).filter(s=>s.deletedAt==null).map(s=>[key(s.earTag),s.id]));
 let facts=[...(workspace.models?.ReproductionRecord??[])];const reviews=[],errors=[];
 const stableID=r=>stableUUID(workspace.farm.id,`excel-v3:${r.sheet}:${String(r.importKey||r.values['导入键']||'').toLowerCase()}`);
 for(const r of records.filter(r=>r.sheet==='新建羊只'&&['母','母羊'].includes(r.values['性别']))){const id=await stableID(r);identifiers.set(key(r.values['耳号']),id);try{facts.push({id:await stableUUID(id,'parity-at-entry'),eweID:id,kindRawValue:'parityBaseline',occurredAt:parseBusinessDate(r.values['入场日期'],tz),parity:Number(r.values['当前胎次']||0)});}catch{}}
 const rows=records.filter(r=>['繁殖记录','产羔'].includes(r.sheet));
 const dated=[];for(const row of rows){try{dated.push({row,at:parseBusinessDate(row.values['发生日期'],tz)});}catch(error){errors.push({sheet:row.sheet,row:row.rowNumber,message:error.message});}}
 dated.sort((a,b)=>a.at-b.at);
 for(const {row:r,at} of dated){const v=r.values,batchID=await stableID(r),tags=r.sheet==='产羔'?[v['母羊耳号']]:listValues(v['母羊耳号列表']);
  for(const tag of tags){const eweID=identifiers.get(key(tag));if(!eweID)continue;
   const recordID=r.sheet==='产羔'?batchID:await stableUUID(batchID,await stableUUID(batchID,key(tag)));
   const kind=r.sheet==='产羔'?'lambing':({配种:'breeding',孕检:'pregnancyCheck',流产:'abortion'})[v['类型']];if(!kind)continue;
   const before=resolveReproductionState(eweID,facts,at);if(kind==='lambing'&&before.completedParity==null){errors.push({sheet:r.sheet,row:r.rowNumber,message:`${tag} 胎次待核实，请先确认后导入产羔。`});continue;}
   let relatedID=v['关联配种记录']||null;if(v['关联配种导入键']){const batch=await stableUUID(workspace.farm.id,`excel-v3:繁殖记录:${v['关联配种导入键'].toLowerCase()}`);relatedID=await stableUUID(batch,await stableUUID(batch,key(tag)));}
   const fact={id:recordID,eweID,kindRawValue:kind,occurredAt:at,result:v['结果']||'',relatedBreedingRecordID:relatedID,parity:kind==='lambing'?before.targetParity:null,breedingIntentRawValue:({新一轮配种:'newRound',本轮补配:'supplement'})[v['配种轮次']]??null};
   facts=facts.filter(f=>f.id!==recordID).concat(fact);const state=resolveReproductionState(eweID,facts,at);if(state.issues.length)reviews.push({sheet:r.sheet,row:r.rowNumber,earTag:tag,reasons:state.issues});
  }
 }
 const errorIDs=new Set(errors.map(r=>`${r.sheet}:${r.row}`)),reviewIDs=new Set(reviews.filter(r=>!errorIDs.has(`${r.sheet}:${r.row}`)).map(r=>`${r.sheet}:${r.row}`));
 return {reviews,errors,reviewRowCount:reviewIDs.size,errorRowCount:errorIDs.size,acceptableRowCount:Math.max(0,records.length-errorIDs.size-reviewIDs.size)};
}
