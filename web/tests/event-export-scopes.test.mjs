import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { nativeEventSnapshots } from '../src/lib/nativeEventSnapshots.js';
import { eventExportContract, matchingEvents, exportEventsCSV } from '../src/lib/eventExport.js';

const at = Date.parse('2026-11-09T16:00:00Z');
const record = (id, extra = {}) => ({ id, createdAt: at, occurredAt: at, recordedAt: at, ...extra });
export function exportScopeFixture() {
  return {
    SheepRecord: [record('ewe', {earTag: '0012', sexRawValue: 'ewe', enteredAt: at, breed: '湖羊'})],
    ReproductionRecord: ['lambing','breeding','pregnancyCheck','abortion','parityBaseline'].map(kindRawValue => record(kindRawValue, {kindRawValue, eweID:'ewe', lambCount:2, result:'待复检'})),
    RemovalRecord: ['sold','deceased','culled','transferredOut'].map(kindRawValue => record(kindRawValue, {kindRawValue,sheepID:'ewe',reason:'核对',note:'现场"记录"\n下一行'})),
    HealthRecord: ['treatment','vaccination'].map(kindRawValue => record(kindRawValue,{kindRawValue,sheepID:'ewe'})),
    FeedRecord: [record('directFeed'),record('tmrFeed')],
    TMRFeedingRunRecord: [record('run')],
    TMRFeedingAllocationRecord: [record('allocation',{feedRecordID:'tmrFeed',runID:'run'})],
    InventoryTransactionRecord: ['receipt','adjustment'].map(kindRawValue => record('inventory-'+kindRawValue,{kindRawValue,quantityText:'1'})),
    SemenTransactionRecord: ['receipt','adjustment'].map(kindRawValue => record('semen-'+kindRawValue,{kindRawValue,quantityText:'1'})),
    ProductionBatchRecord: [record('batch-live',{sourceRawValue:'manual',name:'测试批次',purpose:'育肥',startedAt:at}),record('batch-deleted',{sourceRawValue:'manual',name:'删除批次',purpose:'育肥',startedAt:at,deletedAt:at+1}),record('automatic',{sourceRawValue:'automatic'})],
    TombstoneRecord: [record('deletion',{entityType:'productionBatch',entityID:'batch-deleted',deletedAt:at+1,reason:'核对删除',deletedByAccountID:'ACCOUNT'})],
    BatchMembershipRecord: [record('departure',{batchID:'batch-live',sheepID:'ewe',joinedAt:at,leftAt:at+2,updatedAt:at+2})],
  };
}

test('every App detailed scope resolves projected business facts and keeps its aggregate category', async () => {
  const models=exportScopeFixture(), before=structuredClone(models), events=await nativeEventSnapshots(models);
  const groups={reproduction:['lambing','breeding','pregnancyCheck','abortion','parityBaseline'],removal:['sold','deceased','culled','transferredOut'],health:['treatment','vaccination'],feed:['directFeed','tmrFeed'],inventory:['inventoryReceipt','inventoryAdjustment','semenReceipt','semenAdjustment'],batch:['batchCreated','batchDeleted','batchDeparture']};
  for(const [scope, children] of Object.entries(groups)) {
    const aggregate=matchingEvents(events,{scope});
    for(const child of children) {
      assert(eventExportContract.scopes.some(x=>x.id===child),child);
      const selected=matchingEvents(events,{scope:child});
      assert.equal(selected.length,child==='batchCreated'?2:1,child);
      assert(selected.every(x=>aggregate.includes(x)),child+' aggregate');
    }
  }
  assert.deepEqual(models,before);
  const deletion=matchingEvents(events,{scope:'batchDeleted'})[0];
  assert.equal(deletion.object,'删除批次');
  assert.equal(deletion.note,'核对删除');
  assert.equal(deletion.at,new Date(at+1).toISOString());
  assert.equal(deletion.fields.find(x=>x.label==='删除账号ID').value,'account');
});

test('detail filter and CSV use the same dates, subjects, fields and full count beyond page size', async () => {
  const base=(await nativeEventSnapshots(exportScopeFixture())).find(x=>x.recordScope==='sold');
  const events=Array.from({length:105},(_,n)=>({...base,id:`sale-${n}`}));
  events.push({...base,id:'prior-day',at:new Date(at-1).toISOString()},{...base,id:'draft',status:'draft'},{...base,id:'other-tag',object:'0099'});
  const options={scope:'sold',start:'2026-11-10',end:'2026-11-10',query:'0012',timeZone:'Asia/Shanghai'};
  assert.equal(matchingEvents(events,options).length,105);
  const csv=exportEventsCSV(events,options);
  assert(csv.startsWith('\ufeff"发生时间","录入时间"'));
  assert.equal((csv.match(/"sale-\d+"\r\n/g)||[]).length,105);
  assert(csv.includes('"2026-11-10 00:00:00"'));
  assert(csv.includes('"0012"'));
  assert(csv.includes('"现场""记录""\n下一行"'));
  assert(!csv.includes('prior-day')&&!csv.includes('other-tag')&&!csv.includes('"draft"'));
});

test('generated scopes remain identical to App declarations', async () => {
  const swift=await readFile(new URL('../../eSheepNext/Services/FarmEventCSVExport.swift',import.meta.url),'utf8');
  const declared=[...swift.split('enum FarmEventExportScope:')[1].split('var id:')[0].matchAll(/\bcase (\w+)/g)].map(x=>x[1]);
  assert.deepEqual(eventExportContract.scopes.map(x=>x.id),declared);
});
