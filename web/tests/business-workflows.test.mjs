import test from 'node:test';import assert from 'node:assert/strict';
import {workflowFixture} from './helpers/workflowFixture.mjs';
import {buildBusinessCommands,parseBusinessDate} from '../src/lib/businessCommands.js';
import {preflightImport} from '../src/lib/importPreflight.js';
import {decimalRound,decimalSum} from '../src/lib/decimal.js';
import {nativeEventSnapshots} from '../src/lib/nativeEventSnapshots.js';
import {exportEventsCSV,matchingEvents} from '../src/lib/eventExport.js';
import {commandEnvelope,signCommand,interpretResults} from '../src/lib/cloudV2Writes.js';

test('native weight precision rounds decimal ties and retains two displayed places',()=>{
 assert.equal(decimalRound('1.005',2,true),'1.01');assert.equal(decimalRound('35.6',2,true),'35.60');assert.equal(decimalSum(['0.1','0.2','-0.3']),'0');
});
test('farm timezone dates validate real days and use the chosen timezone',()=>{
 assert.equal(parseBusinessDate('2026-09-08','Asia/Shanghai'),Date.UTC(2026,8,7,16));
 assert.throws(()=>parseBusinessDate('2026-02-30'),/不存在/);
});
test('App CSV quotes every field, preserves leading zero tags, BOM, newlines and date bounds',()=>{
 const first={id:'0001',at:'2026-09-07T16:00:00Z',recordedAt:'2026-09-07T17:00:00Z',scope:'weight',category:'herd',label:'称重',object:'0012',detail:'35.60 千克',status:'synced',fields:[{label:'体重',value:'35.60 千克'}],note:'现场"记录"\n下一行'};
 const second={...first,id:'0002',at:'2026-09-08T16:00:00Z'};
 const unknown={...first,id:'3',status:'unknown'};
 const csv=exportEventsCSV([first,unknown]);assert(csv.startsWith('\ufeff"发生时间","录入时间","类别","记录类型","主对象","摘要","体重","备注","记录ID"\r\n'));assert(csv.includes('"0012"'));assert(csv.includes('"现场""记录""\n下一行"'));assert(csv.endsWith('\r\n'));
 assert.deepEqual(matchingEvents([first,second],{start:'2026-09-09'}).map(e=>e.id),['0002']);assert.deepEqual(matchingEvents([first,second],{end:'2026-09-08'}).map(e=>e.id),['0001']);
});
test('dependent Excel preflight works in order without changing the source workspace',async()=>{
 const fixture=workflowFixture(),workspace=fixture.workspace();const before=JSON.stringify(workspace.models);
 const rows=[{sheet:'圈舍',importKey:'pen',rowNumber:2,values:{圈舍名称:'测试新圈'}},{sheet:'新建羊只',importKey:'sheep',rowNumber:2,values:{耳号:'00001',品种:'湖羊',性别:'母羊',圈舍:'测试新圈',入场日期:'2026-08-01',当前胎次:'2'}},{sheet:'称重',importKey:'weight',rowNumber:2,values:{耳号:'00001',体重kg:'35.6',发生日期:'2026-08-02'}}];
 assert.equal((await preflightImport(rows,workspace)).length,3);assert.equal(JSON.stringify(workspace.models),before);
 await assert.rejects(()=>preflightImport(rows.toReversed(),workspace),/第 2 行.*不存在/);
});
test('invalid sales and pedigree cycles are blocked before a signed request can exist',async()=>{
 const w=workflowFixture().workspace();await assert.rejects(()=>buildBusinessCommands({sheet:'离场',values:{羊只耳号列表:'A002',类型:'出售',原因:'出售',发生日期:'2026-08-01'}},w),/总售卖金额/);
 await assert.rejects(()=>buildBusinessCommands({sheet:'系谱关系',values:{羊只耳号:'E001',母本耳号:'E001',父本来源:'未知',修改原因:'验证'}},w),/本身/);
});
test('native purpose history includes explicit original purpose and correct account fields',async()=>{
 const w=workflowFixture().workspace(),s=w.models.SheepRecord[0];w.models.DomainOperation.push({id:crypto.randomUUID(),entityID:s.id,kindRawValue:'care',occurredAt:Date.UTC(2026,7,1),createdAt:Date.UTC(2026,7,2),resultingRevision:2,accountID:crypto.randomUUID(),payload:{json:{careCommand:{setSheepPurpose:{sheepID:s.id,purpose:'育肥羊',reason:'转育肥',expectedRevision:1}},optionalStrings:{previousSheepPurpose:'未分类'},dates:{}}}});
 const event=(await nativeEventSnapshots(w.models)).find(e=>e.scope==='purpose');assert.equal(event.detail,'未分类 → 育肥羊');assert.equal(event.fields[0].label,'原用途');assert.equal(event.relatedSheepIDs[0],s.id);
});
test('native purpose history decodes Base64 checkpoint payload envelope',async()=>{
 const w=workflowFixture().workspace(),s=w.models.SheepRecord[0];
 const payload={careCommand:{setSheepPurpose:{sheepID:s.id,purpose:'育肥羊'}},optionalStrings:{previousSheepPurpose:'未分类'},dates:{}};
 w.models.DomainOperation.push({id:crypto.randomUUID(),entityID:s.id,kindRawValue:'care',occurredAt:Date.UTC(2026,7,1),createdAt:Date.UTC(2026,7,2),resultingRevision:2,accountID:crypto.randomUUID(),payload:{base64:Buffer.from(JSON.stringify(payload)).toString('base64')}});
 const event=(await nativeEventSnapshots(w.models)).find(e=>e.scope==='purpose');assert.equal(event.detail,'未分类 → 育肥羊');
});
test('WebCrypto command signature verifies exact bytes and duplicate rejection remains rejected',async()=>{
 const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);const w=workflowFixture().workspace();const spec=(await buildBusinessCommands({sheet:'称重',values:{耳号:'A002',体重kg:'40',发生日期:'2026-08-01'}},w))[0];
 const accountID=crypto.randomUUID(),deviceID=crypto.randomUUID();const command=commandEnvelope(spec,{accountID,farm:w.farm,deviceID,sequence:1,sourceRequestID:crypto.randomUUID()});const signed=await signCommand(command,{privateKey:keys.privateKey});const text=['esheep-cloud-command-v2',w.farm.id,'3',accountID,deviceID,'1',command.commandID,signed.content_digest].join('\n');
 assert(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},keys.publicKey,Buffer.from(signed.device_signature_base64,'base64'),new TextEncoder().encode(text)));
 assert.equal(interpretResults([command],{results:[{command_id:command.commandID,type:'duplicate',original:{type:'rejected'}}]}).status,'rejected');
 assert.throws(()=>interpretResults([command],{results:[]}),/缺少/);
});

test('feed ledger uses opening quantity and valid transactions including receipt-only baseline',async()=>{
 const {feedStockBalance}=await import('../src/lib/feedStock.js');const id=crypto.randomUUID();
 const batch={id,remainingKilogramsText:'1000',stockWeightConfirmed:false};
 assert.equal(feedStockBalance(batch,[{ingredientBatchID:id,kindRawValue:'consumption',quantityText:'98'}]),'902');
 assert.equal(feedStockBalance({id},[{ingredientBatchID:id,kindRawValue:'receipt',quantityText:'0.3'},{ingredientBatchID:id,kindRawValue:'consumption',quantityText:'0.1'}]),'0.2');
 assert.equal(feedStockBalance({id},[{ingredientBatchID:id,kindRawValue:'conflict',quantityText:'5'}]),null);
});
test('profile parity patch preserves native side fact without blocking Web replay',async()=>{
 const {applyExtendedV2Event}=await import('../src/lib/cloudV2BusinessReplay.js');const fixture=workflowFixture(),s=fixture.workspace().models.SheepRecord[0];
 const event={event_kind:'fields_patched',stream_type:'sheepProfile',stream_id:s.id,event_id:crypto.randomUUID(),occurred_at_millis:Date.UTC(2026,7,1),received_at_millis:Date.UTC(2026,7,2)};
 assert(await applyExtendedV2Event(fixture.projection,event,{changes:[{field:'currentParity',value:{type:'integer',value:3}},{field:'parityRecordedAt',value:{type:'date',value:Date.UTC(2026,7,1)}}]}));
 const r=fixture.workspace().models.ReproductionRecord[0];assert.equal(r.parity,3);assert.equal(r.eweID,s.id);assert.equal(r.occurredAt,event.occurred_at_millis);
});
