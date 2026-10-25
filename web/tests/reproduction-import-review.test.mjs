import test from 'node:test';import assert from 'node:assert/strict';
import {reviewReproductionImports} from '../src/lib/reproductionImportReview.js';
const farmID='00000000-0000-4000-8000-000000000001',eweID='00000000-0000-4000-8000-000000000002';
const workspace={farm:{id:farmID,timeZoneIdentifier:'Asia/Shanghai'},models:{SheepRecord:[{id:eweID,earTag:'E1',sexRawValue:'ewe'}],ReproductionRecord:[{id:'baseline',eweID,kindRawValue:'parityBaseline',parity:0,occurredAt:Date.UTC(2026,0,1)}]}};
const row=(n,type,extras={})=>({sheet:'繁殖记录',rowNumber:n,importKey:`r${n}`,values:{导入键:`r${n}`,类型:type,母羊耳号列表:'E1',发生日期:`2026-01-${String(n).padStart(2,'0')}`,结果:type==='孕检'?'已孕':'',...extras}});
test('old imports keep ambiguous historical breeding as review rows without inventing correction',async()=>{
 const result=await reviewReproductionImports([row(2,'配种'),row(3,'配种'),row(4,'孕检')],workspace);
 assert.equal(result.reviewRowCount,2);assert.equal(result.errorRowCount,0);assert.equal(result.acceptableRowCount,1);assert.equal(workspace.models.ReproductionRecord.length,1);
});
test('explicit supplement import key resolves independently per ewe',async()=>{
 const result=await reviewReproductionImports([row(2,'配种',{配种轮次:'新一轮配种'}),row(3,'配种',{配种轮次:'本轮补配',关联配种导入键:'r2'}),row(4,'孕检',{关联配种导入键:'r3'})],workspace);
 assert.equal(result.reviewRowCount,0);assert.equal(result.errorRowCount,0);assert.equal(result.acceptableRowCount,3);
});
