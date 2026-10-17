import test from 'node:test';
import assert from 'node:assert/strict';
import {workflowFixture} from './helpers/workflowFixture.mjs';
import {applyExtendedV2Event} from '../src/lib/cloudV2BusinessReplay.js';
import {resolveReproductionState} from '../src/lib/reproductionCycles.js';
import {stableUUID} from '../src/lib/nativeEventSnapshots.js';
const at=Date.UTC(2026,9,1);
async function replay(fixture,kind,name,args,commandID=crypto.randomUUID()){
 return applyExtendedV2Event(fixture.projection,{event_kind:'state_machine',command_id:commandID,event_id:crypto.randomUUID(),source_command_digest:'b'.repeat(64),actor_account_id:crypto.randomUUID(),received_at_millis:at,occurred_at_millis:at},{command_kind:kind,command_payload:{kind,body:{[name]:{_0:args}}},affected_streams:[]});
}
function setup(){const f=workflowFixture(),ewe=f.workspace().models.SheepRecord[0];f.projection.models.get('ReproductionRecord').set('baseline',{id:'baseline',eweID:ewe.id,kindRawValue:'parityBaseline',parity:0,occurredAt:at-1000});return {f,ewe};}
test('correction preserves old-format associations and stable round; invalid descendants are reviewable',async()=>{
 const {f,ewe}=setup(),batchID=crypto.randomUUID(),subjectID=crypto.randomUUID(),id=await stableUUID(batchID,subjectID);
 await replay(f,'care.reproduction.recordBatch','recordReproductionBatch',{id:batchID,kind:'breeding',occurredAt:at-900,subjects:[{id:subjectID,eweID:ewe.id,reproductionCycleID:ewe.id,breedingRoundID:id,breedingIntent:'newRound',result:''}]});
 const checkID=crypto.randomUUID();f.projection.models.get('ReproductionRecord').set(checkID,{id:checkID,eweID:ewe.id,kindRawValue:'pregnancyCheck',occurredAt:at-800,result:'已孕',relatedBreedingRecordID:id,reproductionCycleID:ewe.id,breedingRoundID:id});
 const replacement={id:crypto.randomUUID(),kind:'breeding',occurredAt:at-950,subjects:[{id:crypto.randomUUID(),eweID:ewe.id,result:''}]};
 await replay(f,'care.reproduction.correct','correctReproduction',{originalID:id,replacement,reason:'核对原始配种日期'});
 const records=[...f.projection.models.get('ReproductionRecord').values()],current=records.find(r=>r.batchID===replacement.id);
 assert.equal(current.breedingRoundID,id);assert.equal(current.reproductionCycleID,ewe.id);assert.equal(current.breedingIntentRawValue,'newRound');
 const state=resolveReproductionState(ewe.id,records,at);assert.equal(state.pregnancy,'pregnant');assert.equal(state.breedingRoundID,id);
 current.occurredAt=at-700;const changed=resolveReproductionState(ewe.id,records,at);assert.equal(changed.pregnancy,'uncertain');assert(changed.issues.some(s=>s.includes('关联配种')));
});
test('lambing revoke and restore preserve child downstream facts, compensate birth weight and are idempotent',async()=>{
 const {f,ewe}=setup(),id=crypto.randomUUID(),childID=crypto.randomUUID(),detailID=crypto.randomUUID();
 await replay(f,'care.lambing.record','recordLambing',{id,eweID:ewe.id,occurredAt:at-500,parity:1,offspring:[{id:detailID,sheepID:childID,earTag:'C001',sex:'ram',createSheepRecord:true,birthWeightText:'3.50',isStillborn:false}]});
 const child=f.projection.models.get('SheepRecord').get(childID),detail=f.projection.models.get('LambingOffspringRecord').get(detailID),birth=f.projection.models.get('WeightRecord').get(detail.autoBirthWeightRecordID);
 child.currentPenID=crypto.randomUUID();const penID=child.currentPenID;child.purpose='育肥羊';
 const laterID=crypto.randomUUID();f.projection.models.get('WeightRecord').set(laterID,{id:laterID,sheepID:childID,kilogramsText:'20',deletedAt:null});
 const commandID=crypto.randomUUID();await replay(f,'care.lambing.revoke','revokeLambing',{recordID:id,reason:'原始资料核对'},commandID);
 assert.equal(child.deletedAt,null);assert.equal(child.currentPenID,penID);assert.equal(child.purpose,'育肥羊');assert.equal(child.damID,null);assert.equal(birth.deletedAt,at);assert.equal(f.projection.models.get('WeightRecord').get(laterID).deletedAt,null);
 const revision=child.revision;await replay(f,'care.lambing.revoke','revokeLambing',{recordID:id,reason:'原始资料核对'},commandID);assert.equal(child.revision,revision);
 await replay(f,'care.lambing.restore','restoreLambing',{recordID:id});assert.equal(child.damID,ewe.id);assert.equal(birth.deletedAt,null);assert.equal(child.currentPenID,penID);assert.equal(detail.deletedAt,null);
 assert.equal(resolveReproductionState(ewe.id,[...f.projection.models.get('ReproductionRecord').values()],at).completedParity,1);
});
test('manual pedigree survives lambing revoke and restore',async()=>{
 const {f,ewe}=setup(),id=crypto.randomUUID(),childID=crypto.randomUUID();
 await replay(f,'care.lambing.record','recordLambing',{id,eweID:ewe.id,occurredAt:at-500,parity:1,offspring:[{id:crypto.randomUUID(),sheepID:childID,earTag:'C002',sex:'ewe',createSheepRecord:true,birthWeightText:'3',isStillborn:false}]});
 const child=f.projection.models.get('SheepRecord').get(childID),manual=crypto.randomUUID();child.damID=manual;child.damProvenanceRawValue='manual';
 await replay(f,'care.lambing.revoke','revokeLambing',{recordID:id,reason:'复核'});await replay(f,'care.lambing.restore','restoreLambing',{recordID:id});assert.equal(child.damID,manual);assert.equal(child.damProvenanceRawValue,'manual');
});

test('legacy lambing correction keeps explicit cycle, round and breeding reference',async()=>{
 const {f,ewe}=setup(),breedingID=crypto.randomUUID(),id=crypto.randomUUID();
 f.projection.models.get('ReproductionRecord').set(breedingID,{id:breedingID,eweID:ewe.id,kindRawValue:'breeding',occurredAt:at-800,reproductionCycleID:ewe.id,breedingRoundID:breedingID,breedingIntentRawValue:'newRound'});
 await replay(f,'care.lambing.record','recordLambing',{id,eweID:ewe.id,occurredAt:at-500,parity:1,relatedBreedingRecordID:breedingID,reproductionCycleID:ewe.id,breedingRoundID:breedingID,offspring:[]});
 await replay(f,'care.lambing.correct','correctLambing',{originalID:id,replacement:{id,eweID:ewe.id,occurredAt:at-400,parity:1,offspring:[]},reason:'核对日期'});
 const row=f.projection.models.get('ReproductionRecord').get(id);assert.equal(row.relatedBreedingRecordID,breedingID);assert.equal(row.reproductionCycleID,ewe.id);assert.equal(row.breedingRoundID,breedingID);assert.equal(row.occurredAt,at-400);
});
