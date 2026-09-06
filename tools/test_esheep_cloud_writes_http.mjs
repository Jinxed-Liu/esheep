// Real HTTP verification against an explicitly disposable local stack only.
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, randomUUID, randomBytes, createHash, sign } from 'node:crypto';
import assert from 'node:assert/strict';
const [configurationPath, outputPath] = process.argv.slice(2);
assert(configurationPath && outputPath, 'Supply local status JSON and result path');
const configuration = JSON.parse(readFileSync(configurationPath, 'utf8'));
const base = new URL(configuration.API_URL);
assert(['127.0.0.1', 'localhost'].includes(base.hostname) && base.protocol === 'http:', 'Local stack only');
assert(process.env.DOCKER_HOST?.includes('/esheep-checkpoint/'), 'Dedicated disposable Docker profile required');
const sql = (text) => execFileSync('docker', ['exec', '-i', 'supabase_db_esheep-checkpoint-isolated', 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], { input: text, encoding: 'utf8' }).trim();
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
const nullDigest = sql(`select esheep_cloud.value_digest('{"type":"null"}'::jsonb);`);
const commandID = randomUUID();
const stream = { type: 'sheepProfile', id: sheepID };
const mutation = { action: 'set', value: { type: 'string', value: 'HTTP-001' } };
const unsigned = { protocolVersion: 2, schemaVersion: 1, commandID, sourceRequestID: randomUUID(), bundleID: null,
  farmID, farmGeneration: 3, accountID, deviceID, deviceSequence: 1, createdAt: Date.now(), occurredAt: Date.now(),
  commandKind: 'sheep.patchProfile', payload: { kind: 'sheep.patchProfile', body: { patchProfile: { sheepID, fields: [{ field: 'earTag', mutation }] } } },
  affectedStreams: [stream], affectedFields: [{ stream, field: 'earTag', observedVersion: 0, baseValueDigest: nullDigest }],
  fieldChanges: [{ field: 'earTag', mutation }], prerequisiteCommandIDs: [], requiredAssetIDs: [] };
const bytes = Buffer.from(JSON.stringify(unsigned)), digest = hash(bytes);
const signingBytes = Buffer.from(['esheep-cloud-command-v2', farmID, '3', accountID, deviceID, '1', commandID, digest].join('\n'));
const signature = sign('sha256', signingBytes, { key: keys.privateKey, dsaEncoding: 'ieee-p1363' });
const signed = { unsigned_command_base64: bytes.toString('base64'), content_digest: digest, device_signature_base64: signature.toString('base64') };
const body = { action: 'submit_commands', farm_id: farmID, farm_generation: 3, commands: [signed] };
const first = await request('/functions/v1/esheep-cloud-v2-writes', body, token);
assert.equal(first.status, 200, JSON.stringify(first.body));
assert.equal(first.version, 'integrated-v1');
const acceptedCount = sql(`select count(*) from esheep_cloud.commands where command_id='${commandID}' and status='accepted';`);
assert.equal(acceptedCount, '1', JSON.stringify(first.body));
const head = sql(`select event_head from esheep_cloud.farm_state where farm_id='${farmID}';`);
assert(Number(head) > 0);
const duplicate = await request('/functions/v1/esheep-cloud-v2-writes', body, token);
assert.equal(duplicate.status, 200);
assert.equal(sql(`select event_head from esheep_cloud.farm_state where farm_id='${farmID}';`), head);
const status = await request('/rest/v1/rpc/esheep_cloud_query_command_status_v2', { p_farm_id: farmID, p_command_ids: [commandID] }, token);
assert.equal(status.status, 200);
assert(JSON.stringify(status.body).includes(commandID));
const invalid = await request('/functions/v1/esheep-cloud-v2-writes', { ...body, commands: [{ ...signed, device_signature_base64: randomBytes(64).toString('base64') }] }, token);
assert.equal(invalid.status, 403);
const scope = await request('/functions/v1/esheep-cloud-v2-writes', { ...body, farm_id: randomUUID() }, token);
assert.equal(scope.status, 400);
const anonymous = await request('/functions/v1/esheep-cloud-v2-writes', body, configuration.ANON_KEY);
assert.equal(anonymous.status, 401);
// A different signed device, with an old field observation, must produce a
// concrete attention item and resolve through the same real HTTP verifier.
const secondDevice = randomUUID(), secondKeys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
sql(`insert into public.devices(device_id,user_id,public_key_jwk,display_name,status) values('${secondDevice}','${userID}',${quote(JSON.stringify(secondKeys.publicKey.export({format:'jwk'})))}::jsonb,'Second isolated verifier','active');`);
const conflicting = structuredClone(unsigned);
conflicting.commandID = randomUUID(); conflicting.sourceRequestID = randomUUID(); conflicting.deviceID = secondDevice;
conflicting.payload.body.patchProfile.fields[0].mutation.value.value = 'HTTP-002';
conflicting.fieldChanges[0].mutation.value.value = 'HTTP-002';
const conflictBytes = Buffer.from(JSON.stringify(conflicting)), conflictDigest = hash(conflictBytes);
const conflictSignature = sign('sha256',Buffer.from(['esheep-cloud-command-v2',farmID,'3',accountID,secondDevice,'1',conflicting.commandID,conflictDigest].join('\n')),{key:secondKeys.privateKey,dsaEncoding:'ieee-p1363'});
const conflict = await request('/functions/v1/esheep-cloud-v2-writes',{...body,commands:[{unsigned_command_base64:conflictBytes.toString('base64'),content_digest:conflictDigest,device_signature_base64:conflictSignature.toString('base64')}]},token);
assert.equal(conflict.status,200,JSON.stringify(conflict.body));
assert.equal(sql(`select status from esheep_cloud.commands where command_id='${conflicting.commandID}';`),'needs_confirmation');
const attention = JSON.parse(sql(`select jsonb_build_object('id',attention_id,'digest',esheep_cloud.value_digest(cloud_value)) from esheep_cloud.attention_items where command_id='${conflicting.commandID}';`));
const resolutionID=randomUUID();
const resolutionBytes=Buffer.from(['esheep-cloud-attention-resolution-v2',attention.id,resolutionID,'keep_cloud',attention.digest,'3',accountID,secondDevice,'2'].join('\n'));
const resolution=await request('/functions/v1/esheep-cloud-v2-writes',{action:'resolve_attention',farm_id:farmID,farm_generation:3,attention_id:attention.id,resolution_command_id:resolutionID,choice:'keep_cloud',expected_cloud_value_digest:attention.digest,account_id:accountID,device_id:secondDevice,device_sequence:2,device_signature_base64:sign('sha256',resolutionBytes,{key:secondKeys.privateKey,dsaEncoding:'ieee-p1363'}).toString('base64')},token);
assert.equal(resolution.status,200,JSON.stringify(resolution.body));
assert.equal(sql(`select status from esheep_cloud.attention_items where attention_id='${attention.id}';`),'resolved');
const weightID=randomUUID(), weightCommand=structuredClone(unsigned);
Object.assign(weightCommand,{commandID:randomUUID(),sourceRequestID:randomUUID(),deviceID:secondDevice,deviceSequence:3,
 commandKind:'weight.record',payload:{kind:'weight.record',body:{recordWeight:{sheepID,kilogramsText:'42.5',occurredAt:Date.now(),note:'isolated HTTP test'}}},
 affectedStreams:[{type:'weight',id:weightID}],affectedFields:[],fieldChanges:[],prerequisiteCommandIDs:[]});
const revokeCommand=structuredClone(weightCommand);
Object.assign(revokeCommand,{commandID:randomUUID(),sourceRequestID:randomUUID(),deviceSequence:4,commandKind:'record.revoke',
 payload:{kind:'record.revoke',body:{tombstone:{entityType:'weight',entityID:weightID,reason:'isolated dependency test'}}},prerequisiteCommandIDs:[weightCommand.commandID]});
function signCommand(command,key){
 const bytes=Buffer.from(JSON.stringify(command)),digest=hash(bytes);
 const data=Buffer.from(['esheep-cloud-command-v2',farmID,'3',accountID,command.deviceID,String(command.deviceSequence),command.commandID,digest].join('\n'));
 return {unsigned_command_base64:bytes.toString('base64'),content_digest:digest,device_signature_base64:sign('sha256',data,{key,dsaEncoding:'ieee-p1363'}).toString('base64')};
}
const weightSigned=signCommand(weightCommand,secondKeys.privateKey),revokeSigned=signCommand(revokeCommand,secondKeys.privateKey);
const tooEarly=await request('/functions/v1/esheep-cloud-v2-writes',{...body,commands:[revokeSigned]},token);
assert.equal(tooEarly.status,200);
assert(tooEarly.body.results.every(r=>r.type==='rejected' && r.reason?.code==='prerequisite_not_ready'),JSON.stringify(tooEarly.body));
const savedWeight=await request('/functions/v1/esheep-cloud-v2-writes',{...body,commands:[weightSigned]},token);
assert.equal(savedWeight.status,200);
assert.equal(sql(`select status from esheep_cloud.commands where command_id='${weightCommand.commandID}';`),'accepted',JSON.stringify(savedWeight.body));
const savedRevoke=await request('/functions/v1/esheep-cloud-v2-writes',{...body,commands:[revokeSigned]},token);
assert.equal(savedRevoke.status,200);
assert.equal(sql(`select status from esheep_cloud.commands where command_id='${revokeCommand.commandID}';`),'accepted',JSON.stringify(savedRevoke.body));
const order=sql(`select string_agg(command_id::text,',' order by event_sequence) from esheep_cloud.events where command_id in ('${weightCommand.commandID}','${revokeCommand.commandID}');`);
assert.equal(order,weightCommand.commandID+','+revokeCommand.commandID);
const photoBytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jXioAAAAASUVORK5CYII=', 'base64');
const metadataDigest = sql(`select esheep_cloud.json_digest('{}'::jsonb);`);
for (const corrupt of [false,true]) {
  const originalBytes = corrupt ? Buffer.concat([photoBytes,randomBytes(8)]) : photoBytes;
  const assetID=randomUUID(), contentDigest=hash(originalBytes);
  const preparation=await request('/rest/v1/rpc/esheep_cloud_prepare_asset_transfer_v2',{
    p_farm_id:farmID,p_farm_generation:3,p_asset_id:assetID,p_sheep_id:sheepID,
    p_content_sha256:contentDigest,p_variant_sha256:contentDigest,p_metadata:{},p_metadata_digest:metadataDigest,
    p_variant:'original',p_direction:'upload',p_byte_count:originalBytes.length},token);
  assert.equal(preparation.status,200,JSON.stringify(preparation.body));
  const payload=Buffer.from(originalBytes); if(corrupt)payload[0]^=1;
  const uploaded=await fetch(new URL('/storage/v1/object/esheep-cloud-assets/'+preparation.body.object_key,base),{
    method:'POST',headers:{apikey:configuration.ANON_KEY,authorization:`Bearer ${token}`,'content-type':'image/png','x-metadata':Buffer.from(JSON.stringify({sha256:contentDigest})).toString('base64')},body:payload});
  assert.equal(uploaded.status,200,await uploaded.text());
  const confirmed=await request('/functions/v1/esheep-cloud-v2-writes',{action:'confirm_asset',farm_id:farmID,farm_generation:3,asset_id:assetID,variant:'original'},token);
  assert.equal(confirmed.status,corrupt?400:200,JSON.stringify(confirmed.body));
  if(!corrupt)assert.equal(confirmed.body.verified,true);
  else assert.equal(confirmed.body.error,'asset_content_verification_failed');
}
const finalHead=sql(`select event_head from esheep_cloud.farm_state where farm_id='${farmID}';`);
sql(`update public.farm_members set status='revoked' where farm_id='${farmID}' and user_id='${userID}';`);
const revoked=await request('/functions/v1/esheep-cloud-v2-writes',body,token);
assert.equal(revoked.status,200);
assert(revoked.body.results.every(result => result.type==='rejected' && result.reason?.code==='permission_denied'),JSON.stringify(revoked.body));
assert.equal(sql(`select event_head from esheep_cloud.farm_state where farm_id='${farmID}';`),finalHead);
const report = { passed: true, localOnly: true, realHTTP: true, verifiedSignature: true, acceptedCommandCount: 1,
 duplicateAddsEvents: false, resultQuery: true, invalidSignatureRejected: true, crossFarmEnvelopeRejected: true,
 anonymousRejected: true, edgeVersion: first.version, eventHead: Number(head), conflictResolution: true, revokedMemberRejected: true, assetConfirmation: true, corruptAssetRejected: true, dependencyRevokePreservesOriginalIDsAndOrder: true, otherScenariosStillRequired: [] };
writeFileSync(outputPath, JSON.stringify(report, null, 2), { mode: 0o600 });
console.log(JSON.stringify(report));
