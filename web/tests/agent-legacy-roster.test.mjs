import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { replayLegacyRoster, verifyLegacyWitness } from "../server/agent-legacy-roster.mjs";

const source = {farm:"farm",sourceGeneration:1,finalRevision:2,cutoff:"2026-09-01T00:00:00+08:00"};
function pack(body) {
  const bytes=Buffer.from(JSON.stringify(body));
  return {payload:bytes.toString("base64"),payloadDigest:createHash("sha256").update(bytes).digest("hex")};
}
const add = {kind:"addSheep",strings:{sex:"ewe"},integers:{}};
const archive = {manifest:{farmID:"farm",authorityGeneration:1,projectionCount:1},
  projections:[{entityType:"sheep",entityID:"original",...pack(add)}]};
function op(revision,id,type,body) {
  const data=pack(body);
  return {revision,entity_id:id,entity_type:type,payload_base64:data.payload,payload_digest:data.payloadDigest,
    server_received_at:"2026-08-31T22:00:00Z"};
}
const journal = [
  op(1,"late","sheep",{...add,dates:{occurredAt:"2026-08-20T00:00:00Z"}}),
  op(2,"exit","removal",{kind:"removeSheep",identifiers:{sheepID:"original"}}),
];
test("use the original registration cutoff and cross-check individual identities at handover",()=>{
  const {opening,final}=replayLegacyRoster(archive,journal,source);
  assert.deepEqual(opening.records.map(s=>s.id),["original"]); assert.equal(opening.revision,0);
  const projection = id => ({models:{SheepRecord:[{id,statusRawValue:"active"}]}});
  verifyLegacyWitness(final,projection("late"));
  assert.throws(()=>verifyLegacyWitness(final,projection("wrong")));
});
test("an incomplete or altered journal cannot supply an opening book",()=>{
  assert.throws(()=>replayLegacyRoster(archive,journal.slice(1),source));
  assert.throws(()=>replayLegacyRoster(archive,[{...journal[0],revision:2},journal[1]],source));
  assert.throws(()=>replayLegacyRoster(archive,[{...journal[0],payload_digest:"changed"},journal[1]],source));
  assert.throws(()=>replayLegacyRoster(archive,journal,{...source,farm:"another"}));
});
