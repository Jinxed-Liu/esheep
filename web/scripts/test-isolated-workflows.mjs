// Run only against the dedicated disposable local stack. No production fixtures.
import {readFileSync,writeFileSync} from 'node:fs';import {execFileSync} from 'node:child_process';import assert from 'node:assert/strict';
import {workflowFixture} from '../tests/helpers/workflowFixture.mjs';
import {buildBusinessCommands} from '../src/lib/businessCommands.js';
import {commandEnvelope,signCommand,interpretResults} from '../src/lib/cloudV2Writes.js';
import {applyV2Event,finishV2Projection} from '../src/lib/cloudV2Projection.js';
import {applyExtendedV2Event} from '../src/lib/cloudV2BusinessReplay.js';
import {validateV2Event} from '../src/lib/cloudV2Checkpoint.js';
import {nativeEventSnapshots} from '../src/lib/nativeEventSnapshots.js';
import {managementProjection} from '../src/lib/managementProjection.js';
import contract from '../public/downloads/eSheepPlus_全功能录入模板_v7.json' with {type:'json'};
const [configPath,outPath]=process.argv.slice(2),config=JSON.parse(readFileSync(configPath));
assert(new URL(config.API_URL).hostname==='127.0.0.1'&&new URL(config.WRITE_URL).hostname==='127.0.0.1','Local only');
const sql=s=>execFileSync('docker',['--context','colima-esheep-checkpoint','exec','-i','supabase_db_esheep-checkpoint-isolated','psql','-U','postgres','-d','postgres','-XAt','-v','ON_ERROR_STOP=1'],{input:s,encoding:'utf8'}).trim();
async function request(path,body,token=config.SERVICE_ROLE_KEY,base=config.API_URL){const r=await fetch(base+path,{method:'POST',headers:{apikey:config.ANON_KEY,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)});const data=await r.json();assert.equal(r.status,200,JSON.stringify(data));return data;}
const user=await request('/auth/v1/admin/users',{email:`web-${crypto.randomUUID()}@example.invalid`,password:crypto.randomUUID(),email_confirm:true});
// Mint a local user session using a locally generated password recovery token.
const link=await request('/auth/v1/admin/generate_link',{type:'magiclink',email:user.email});
const session=await request('/auth/v1/verify',{type:'magiclink',token_hash:link.hashed_token},config.ANON_KEY);const token=session.access_token;
const accountID=crypto.randomUUID(),deviceID=crypto.randomUUID(),fixture=workflowFixture(),{farm,projection}=fixture;
sql(`update public.profiles set app_account_id='${accountID}' where user_id='${user.id}';
insert into public.entitlements(owner_user_id,product_id,state,valid_until) values('${user.id}','com.sheepfarm.ios.pro.monthly','active',now()+interval '30 days');
insert into public.farm_registry(farm_id,owner_user_id,provider,status,authority_generation,current_revision) values('${farm.id}','${user.id}','esheep_cloud','active',3,0);
insert into public.farm_members(farm_id,user_id,app_account_id,role,status) values('${farm.id}','${user.id}','${accountID}','owner','active');
insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready,projection_digest,last_integrity_check_at) values('${farm.id}',3,'active',true,repeat('0',64),now());`);
const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);const identity={id:deviceID,privateKey:keys.privateKey,publicKeyJWK:await crypto.subtle.exportKey('jwk',keys.publicKey)};
await request('/rest/v1/rpc/register_device',{p_device_id:deviceID,p_public_key_jwk:identity.publicKeyJWK,p_display_name:'Web isolated verifier',p_tmr_data_protocol_version:1},token);
let sequence=0,cursor=0;const results=[];
const schemas=[...contract.schemas.filter(s=>s.name!=='离场'),contract.schemas.find(s=>s.name==='离场'),{name:'原料批次入库',columns:['原料名称','批次名称','购入日期','单价元每kg','库存kg'],example:['豆粕','豆粕验证批次','2026-09-08','3.5','1000']},{name:'TMR制作',columns:['配方名称','批次号','发生日期','用料明细'],example:['隔离TMR','TMR验证批次','2026-09-08 07:00:00','豆粕|豆粕验证批次|100|98']},{name:'TMR投喂',columns:['TMR批次号','发生日期','顿次','投喂分配明细'],example:['TMR验证批次','2026-09-08 08:00:00','早','育肥二圈|20|50']}];
for(const schema of schemas){
 const record={sheet:schema.name,importKey:`verify-${schema.name}`,values:Object.fromEntries(schema.columns.map((k,i)=>[k,schema.example[i]??'']))};
 if(record.sheet==='转群')record.values['转入圈舍']='育肥一圈';
 if(record.sheet==='生产批次')record.values['开始日期']='2026-07-20';
 if(record.sheet==='断奶')record.values['出生日期']='2026-02-01';
 const specs=await buildBusinessCommands(record,fixture.workspace());
 const bundleID=specs.length>1?crypto.randomUUID():null,sourceRequestID=crypto.randomUUID();
 const commands=specs.map(spec=>commandEnvelope(spec,{accountID,farm,deviceID,sequence:++sequence,bundleID,sourceRequestID:crypto.randomUUID()}));
 const signed=await Promise.all(commands.map(c=>signCommand(c,identity)));
 const response=await request('/functions/v1/esheep-cloud-v2-writes',{action:'submit_commands',farm_id:farm.id,farm_generation:3,commands:signed},token,config.WRITE_URL);
 const status=interpretResults(commands,response);
 results.push({sheet:record.sheet,status:status.status,bodies:commands.map(c=>c.payload.body),receipts:response.results});
 writeFileSync(outPath,JSON.stringify({farmID:farm.id,results},null,2));
 assert.equal(status.status,'accepted',`${record.sheet}: ${JSON.stringify(response)}`);
 const duplicate=await request('/functions/v1/esheep-cloud-v2-writes',{action:'submit_commands',farm_id:farm.id,farm_generation:3,commands:signed},token,config.WRITE_URL);
 assert.equal(interpretResults(commands,duplicate).status,'accepted');
 const page=await request('/rest/v1/rpc/esheep_cloud_pull_events_v2',{p_farm_id:farm.id,p_farm_generation:3,p_after_event_sequence:cursor,p_limit:1000},token);
 for(const event of page.events){const body=await validateV2Event(event,farm,cursor+1);if(!await applyExtendedV2Event(projection,event,body))applyV2Event(projection,event,body);cursor=event.event_sequence;}
 console.log(`${record.sheet}: accepted, replayed, duplicate stable`);
}
const final=finishV2Projection(projection),events=await nativeEventSnapshots(final.models),management=await managementProjection(final.models,farm);
assert.equal(management.careItems[0].stock,'94');assert.equal(management.semenInventory[0].balance,'19');
assert.equal(management.ingredientBatches[0].balance,'902');assert.equal(management.tmrBatches[0].balance,'48');
assert.equal(final.models.LambingOffspringRecord.length,2);assert.equal(final.models.SheepRecord.filter(s=>s.earTag==='L001').length,1);
writeFileSync(outPath,JSON.stringify({farmID:farm.id,results,eventCount:events.length,head:cursor,medicineBalance:management.careItems[0].stock,semenBalance:management.semenInventory[0].balance},null,2));
console.log(`PASS ${results.length} template categories; head ${cursor}; medicine 94; semen 19.`);
