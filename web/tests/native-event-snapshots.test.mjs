import test from 'node:test';
import assert from 'node:assert/strict';
import {nativeEventSnapshots} from '../src/lib/nativeEventSnapshots.js';

test('birth history retains stable IDs, order and source facts across concurrent projection', async () => {
  const base = {createdAt:Date.UTC(2026,0,2), enteredAt:Date.UTC(2026,0,2),
    birthAt:Date.UTC(2026,0,1), sexRawValue:'ewe', breed:'湖羊', revision:1};
  const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const models = {SheepRecord:[
    {...base,id:id(1),earTag:'001'}, {...base,id:id(2),earTag:'002'},
    {...base,id:id(3),earTag:'已归档',isHistoricalArchive:true},
    {...base,id:id(4),earTag:'已删除',deletedAt:Date.UTC(2026,0,3)},
    {...base,id:id(5),earTag:'未知出生日期',birthAt:null},
    ...Array.from({length:12},(_,n)=>({...base,id:id(n+6),earTag:`T${n}`})),
  ]};
  const before = structuredClone(models);
  const events = await nativeEventSnapshots(models);
  const births = events.filter(event=>event.scope==='birth');
  assert.equal(events.length,29);
  assert.equal(births.length,14);
  assert.equal(births.find(event=>event.object==='001').id,'cd0164f7-0c45-537b-b7e7-f834db93417c');
  assert.equal(births.find(event=>event.object==='002').id,'d3e5fb51-938a-5166-9ad4-686cdcf130c1');
  assert.deepEqual(births.map(event=>event.id), births.map(event=>event.id).toSorted((a,b)=>b.localeCompare(a)));
  assert.deepEqual(births.find(event=>event.object==='001').relatedSheepIDs,[id(1)]);
  assert.equal(births.find(event=>event.object==='001').at,'2026-01-01T00:00:00.000Z');
  assert(!events.some(event=>['已归档','已删除'].includes(event.object)));
  assert(!births.some(event=>event.object==='未知出生日期'));
  assert.deepEqual(await nativeEventSnapshots(models),events);
  assert.deepEqual(models,before);
});
