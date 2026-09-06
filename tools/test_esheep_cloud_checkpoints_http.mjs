// Real HTTP verification against an explicitly disposable local stack only.
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, randomUUID, randomBytes, createHash, sign } from 'node:crypto';
import assert from 'node:assert/strict';
import { gzipSync, gunzipSync } from 'node:zlib';
const [configurationPath, outputPath] = process.argv.slice(2);
assert(configurationPath && outputPath, 'Supply local status JSON and result path');
const configuration = JSON.parse(readFileSync(configurationPath, 'utf8'));
const base = new URL(configuration.API_URL);
assert(['127.0.0.1', 'localhost'].includes(base.hostname) && base.protocol === 'http:', 'Local stack only');
assert(process.env.DOCKER_HOST?.includes('/esheep-checkpoint/'), 'Dedicated disposable Docker profile required');
const sql = (text) => execFileSync('docker', ['exec', '-i', 'supabase_db_esheep-checkpoint-isolated', 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: text, encoding: 'utf8', stdio: ['pipe','pipe','pipe'] }).trim();
const quote = (text) => `'${String(text).replaceAll("'", "''")}'`;
const hash = (data) => createHash('sha256').update(data).digest('hex');
async function request(path, body, bearer = configuration.SERVICE_ROLE_KEY) {
  const response = await fetch(new URL(path, base), { method: 'POST', headers: { apikey: configuration.ANON_KEY, authorization: `Bearer ${bearer}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: response.status, body: await response.json(), version: response.headers.get('x-esheep-service-version') };
}
const email = `checkpoint-${randomUUID()}@example.invalid`, password = randomBytes(24).toString('hex');
const user = await request('/auth/v1/admin/users', { email, password, email_confirm: true });
assert.equal(user.status, 200);
const login = await request('/auth/v1/token?grant_type=password', { email, password });
assert.equal(login.status, 200);
const token = login.body.access_token, userID = user.body.id;
const farmID = randomUUID(), accountID = randomUUID(), deviceID = randomUUID(), sheepID = randomUUID();
const keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const jwk = keys.publicKey.export({ format: 'jwk' });
sql(`update public.profiles set app_account_id='${accountID}' where user_id='${userID}';
insert into public.entitlements(owner_user_id,product_id,state,valid_until) values('${userID}','com.sheepfarm.ios.pro.monthly','active',now()+interval '30 days');
insert into public.farm_registry(farm_id,owner_user_id,provider,status,authority_generation,current_revision) values('${farmID}','${userID}','esheep_cloud','active',3,0);
insert into public.farm_members(farm_id,user_id,app_account_id,role,status) values('${farmID}','${userID}','${accountID}','owner','active');
insert into public.devices(device_id,user_id,public_key_jwk,display_name,status) values('${deviceID}','${userID}',${quote(JSON.stringify(jwk))}::jsonb,'Isolated HTTP verifier','active');
insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready,projection_digest,last_integrity_check_at) values('${farmID}',3,'active',true,repeat('0',64),now());`);

// This fixture verifies HTTP/storage authorization and immutable publication.
// Full Swift business import is independently covered by the source replay tests.
const endpoint = '/functions/v1/esheep-cloud-checkpoints';
const query = {farm_id:farmID,farm_generation:3};
const admissionProbe = await request('/rest/v1/rpc/esheep_cloud_checkpoint_manifest_v1', {p_farm_id:farmID,p_farm_generation:3,p_checkpoint_id:null}, token);
assert.equal(admissionProbe.status,200,JSON.stringify(admissionProbe.body));
const empty = await request(endpoint,query,token);
assert.equal(empty.status,200,JSON.stringify(empty.body));
assert.equal(empty.version,'checkpoint-v1-integrated-v1');
assert.equal(empty.body.manifest,null);
const checkpointID=randomUUID(), raw=Buffer.from(JSON.stringify([{model:'transport-fixture',values:{farmID}}]));
const compressed=gzipSync(raw), objectKey=`${farmID}/${checkpointID}/00000.json.gz`;
const storagePath='/storage/v1/object/esheep-cloud-checkpoints/'+objectKey;
const manifest={formatVersion:1,minimumClientCapability:1,checkpointID,farmID,farmGeneration:3,
 boundaryEventSequence:0,boundaryEventDigest:'0'.repeat(64),receiptChainDigest:'0'.repeat(64),businessDigest:hash(raw),
 modelCounts:{'transport-fixture':1},chunks:[{index:0,objectKey,compressedBytes:compressed.length,
 uncompressedBytes:raw.length,compressedSHA256:hash(compressed),contentSHA256:hash(raw),recordCount:1}]};
const payload={p_manifest:manifest,p_manifest_sha256:hash(Buffer.from(JSON.stringify(manifest))),p_reconciliation_sha256:hash(Buffer.from('transport-fixture'))};
const missing=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',payload);
assert.notEqual(missing.status,200,'Cannot publish before private content exists');
const upload=await fetch(new URL(storagePath,base),{method:'POST',headers:{authorization:`Bearer ${configuration.SERVICE_ROLE_KEY}`,apikey:configuration.SERVICE_ROLE_KEY,'content-type':'application/gzip','x-upsert':'false'},body:compressed});
assert.equal(upload.status,200,await upload.text());
const published=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',payload);
assert.equal(published.status,200,JSON.stringify(published.body));
const repeated=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',payload);
assert.equal(repeated.status,200);
const mutated=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',{...payload,p_manifest:{...manifest,businessDigest:'a'.repeat(64)}});
assert.notEqual(mutated.status,200,'Checkpoint identifiers are immutable');
const ticket=await request(endpoint,{...query,checkpoint_id:checkpointID},token);
assert.equal(ticket.status,200,JSON.stringify(ticket.body));
assert.deepEqual(ticket.body.manifest,manifest);
assert.equal(ticket.body.downloads.length,1);
// Local Kong signs an internal URL; only translate its known local origin.
const signedURL=new URL(ticket.body.downloads[0].url);
assert(['kong','127.0.0.1','localhost'].includes(signedURL.hostname));
const download=await fetch(new URL(signedURL.pathname+signedURL.search,base));
assert.equal(download.status,200);
const bytes=Buffer.from(await download.arrayBuffer());
assert.equal(hash(bytes),hash(compressed));assert.deepEqual(gunzipSync(bytes),raw);
const privateRead=await fetch(new URL(storagePath,base),{headers:{apikey:configuration.ANON_KEY,authorization:`Bearer ${token}`}});
assert.notEqual(privateRead.status,200,'Membership does not grant raw private bucket access');
const anonymous=await request(endpoint,query,configuration.ANON_KEY);assert.equal(anonymous.status,401);
const foreign=await request(endpoint,{...query,farm_id:randomUUID()},token);assert.equal(foreign.status,403);
const absent=await request(endpoint,{...query,checkpoint_id:randomUUID()},token);assert.equal(absent.status,410);
// Rollback affects new discovery/publication, never a pinned resumable receive.
sql(`insert into esheep_cloud.checkpoint_rollout_controls(farm_id,farm_generation,new_receives_enabled,publication_enabled,reason) values('${farmID}',3,false,false,'isolated rollback verification');`);
const paused=await request(endpoint,query,token);
assert.equal(paused.status,200);assert.equal(paused.body.manifest,null);
assert.equal(paused.body.legacy_reason,'new_checkpoint_receives_paused');
const resumed=await request(endpoint,{...query,checkpoint_id:checkpointID},token);
assert.equal(resumed.status,200);assert.deepEqual(resumed.body.manifest,manifest);
const publishPaused=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',payload);
assert.notEqual(publishPaused.status,200);
assert.equal(sql("select has_function_privilege('service_role','public.esheep_cloud_publish_checkpoint_content_v1(jsonb,text,text)','EXECUTE')"),'f','No publisher bypass');
assert.equal(sql("select has_table_privilege('authenticated','esheep_cloud.checkpoint_rollout_controls','UPDATE')"),'f','Clients cannot change rollout flags');
sql(`update esheep_cloud.checkpoint_rollout_controls set new_receives_enabled=true,publication_enabled=true where farm_id='${farmID}';`);
const restored=await request(endpoint,query,token);assert.deepEqual(restored.body.manifest,manifest);
assert.equal((await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',payload)).status,200);
// New-checkpoint retention keeps the latest two plus investigation pins.
sql(`update esheep_cloud.business_checkpoints set pinned=true where checkpoint_id='${checkpointID}';`);
const laterIDs=[];
for(let i=0;i<3;i++) {
 const nextID=randomUUID(), nextKey=`${farmID}/${nextID}/00000.json.gz`;
 const nextManifest={...manifest,checkpointID:nextID,chunks:[{...manifest.chunks[0],objectKey:nextKey}]};
 const put=await fetch(new URL('/storage/v1/object/esheep-cloud-checkpoints/'+nextKey,base),{method:'POST',headers:{authorization:`Bearer ${configuration.SERVICE_ROLE_KEY}`,apikey:configuration.SERVICE_ROLE_KEY,'content-type':'application/gzip','x-upsert':'false'},body:compressed});
 assert.equal(put.status,200,await put.text());
 const nextPublish=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',{...payload,p_manifest:nextManifest,p_manifest_sha256:hash(Buffer.from(JSON.stringify(nextManifest)))});
 assert.equal(nextPublish.status,200,JSON.stringify(nextPublish.body));laterIDs.push(nextID);
}
const retentionIdentity={p_farm_id:farmID,p_farm_generation:3};
const auditRetention=await request('/rest/v1/rpc/esheep_cloud_checkpoint_retention_v1',{...retentionIdentity,p_apply:false});
assert.equal(auditRetention.status,200);assert.deepEqual(auditRetention.body.eligible_to_retire,[laterIDs[0]]);
assert.equal(sql(`select count(*) from esheep_cloud.business_checkpoints where farm_id='${farmID}' and status='verified'`),'4','Audit does not retire anything');
const clientRetention=await request('/rest/v1/rpc/esheep_cloud_checkpoint_retention_v1',{...retentionIdentity,p_apply:true},token);assert.notEqual(clientRetention.status,200);
assert.equal((await request('/rest/v1/rpc/esheep_cloud_checkpoint_retention_v1',{...retentionIdentity,p_apply:true})).status,200);
const claimArgs={...retentionIdentity,p_checkpoint_id:laterIDs[0]};
const tooSoon=await request('/rest/v1/rpc/esheep_cloud_claim_checkpoint_purge_v1',claimArgs);assert.equal(tooSoon.body.manifest,null,'Old signed tickets get a grace period');
sql(`update esheep_cloud.business_checkpoints set retired_at=now()-interval '11 minutes' where checkpoint_id='${laterIDs[0]}';`);
const claim=await request('/rest/v1/rpc/esheep_cloud_claim_checkpoint_purge_v1',claimArgs);assert.equal(claim.status,200);assert.equal(claim.body.manifest.checkpointID,laterIDs[0]);
const claimAgain=await request('/rest/v1/rpc/esheep_cloud_claim_checkpoint_purge_v1',claimArgs);assert.deepEqual(claimAgain.body,claim.body,'Interrupted cleanup can resume the same immutable claim');
const deleteKey=claim.body.manifest.chunks[0].objectKey;
assert.throws(()=>sql(`update esheep_cloud.business_checkpoints set pinned=true where checkpoint_id='${laterIDs[0]}';`),/checkpoint_pin_before_purge/,'Cannot silently promise a pin after purge has been claimed');
execFileSync('python3',['tools/maintain_esheep_cloud_checkpoints.py','--project','abcdefghijklmnopqrst','--farm',farmID,'--generation','3','--local-test-config',configurationPath,'--execute','--output',outputPath+'.maintenance.json'],{encoding:'utf8',env:process.env});
const missingAfterDelete=await fetch(new URL('/storage/v1/object/esheep-cloud-checkpoints/'+deleteKey,base),{headers:{authorization:`Bearer ${configuration.SERVICE_ROLE_KEY}`,apikey:configuration.SERVICE_ROLE_KEY}});
const missingBody=await missingAfterDelete.json();
assert(missingAfterDelete.status===404 || (missingAfterDelete.status===400 && String(missingBody.statusCode)==='404'),'Require explicit object-not-found evidence');
const finalized=await request('/rest/v1/rpc/esheep_cloud_finish_checkpoint_purge_v1',{p_checkpoint_id:laterIDs[0],p_manifest_sha256:claim.body.manifest_sha256});assert.equal(finalized.body,true);
assert.equal(sql(`select count(*) from esheep_cloud.business_checkpoints where farm_id='${farmID}' and status='verified'`),'3','Latest two plus pinned original remain');
const retiredPublish=await request('/rest/v1/rpc/esheep_cloud_publish_checkpoint_v1',{...payload,p_manifest:claim.body.manifest,p_manifest_sha256:claim.body.manifest_sha256});assert.notEqual(retiredPublish.status,200);assert.equal(retiredPublish.body.message,'checkpoint_retired');
assert.equal((await request(endpoint,{...query,checkpoint_id:checkpointID},token)).status,200,'Pinned investigation content remains downloadable');
sql(`update public.farm_members set status='revoked' where farm_id='${farmID}' and user_id='${userID}';`);
const revoked=await request(endpoint,query,token);assert.equal(revoked.status,403);
writeFileSync(outputPath,JSON.stringify({passed:true,scope:'isolated HTTP transport and publication',
 checkpointRetention:true,retentionGracePeriod:true,resumablePurge:true,latestTwoAndPinnedRetained:true,functionalRollback:true,pinnedResumeDuringRollback:true,publicationPause:true,noPublicationBypass:true,emptyManifest:true,missingObjectRejected:true,immutablePublication:true,pinnedTicket:true,binaryGzipVerified:true,
 privateBucketDenied:true,anonymousDenied:true,crossFarmDenied:true,revokedMemberDenied:true,missingPinnedCheckpointGone:true,
 measuredTransferBytes:bytes.length},null,2));
console.log('PASS: checkpoint private transport, publication and membership HTTP gates');
