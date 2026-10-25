import test from 'node:test';
import assert from 'node:assert/strict';
import {buildSheepGrowth} from '../src/lib/sheepGrowth.js';
const sheepID='00000000-0000-4000-8000-000000000001';
const point=(id,at,kilograms)=>({id,sheepID,at,kilograms});
const source={weights:[point('a','2026-01-01T01:00:00Z',20),point('a2','2026-01-01T10:00:00Z',21),point('b','2026-01-11T01:00:00Z',21),point('c','2026-01-31T01:00:00Z',19)],weanings:[],reproduction:[]};
test('growth keeps last daily measurement, zero, negative and unequal interval weighting',()=>{
 const growth=buildSheepGrowth(source,sheepID,{asOf:Date.UTC(2026,1,1)});
 assert.equal(growth.points.length,3);assert.equal(growth.points[0].id,'a2');
 assert.deepEqual(growth.intervals.map(r=>r.gramsPerDay),[0,-100]);
 assert.equal(growth.observationDays,30);assert.equal(growth.meanGramsPerDay,-2000/30);
});
test('bounded range uses only full real adjacent intervals and latest metrics remain global',()=>{
 const growth=buildSheepGrowth(source,sheepID,{asOf:Date.UTC(2026,1,1),dateFrom:'2026-01-12',dateTo:'2026-01-31'});
 assert.equal(growth.points.length,1);assert.equal(growth.intervals.length,0);assert.equal(growth.meanGramsPerDay,null);
 assert.equal(growth.latest.kilograms,19);assert.equal(growth.latestInterval.gramsPerDay,-100);
});
test('farm day boundary controls canonical point selection without bridging an excluded point',()=>{
 const growth=buildSheepGrowth({weights:[point('a','2026-01-01T15:59:00Z',10),point('b','2026-01-01T16:01:00Z',11),point('c','2026-01-03T02:00:00Z',13)]},sheepID,{asOf:Date.UTC(2026,1,1),dateFrom:'2026-01-02',dateTo:'2026-01-03'});
 assert.deepEqual(growth.points.map(p=>p.day),['2026-01-02','2026-01-03']);assert.equal(growth.intervals.length,1);assert.equal(growth.intervals[0].intervalDays,1);
});
