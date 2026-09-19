begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
create function pg_temp.uid(n int) returns uuid language sql immutable as $$ select ('fa000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
insert into auth.users(id) values(pg_temp.uid(1)),(pg_temp.uid(2));
insert into public.entitlements(owner_user_id,product_id,state,valid_until) values(pg_temp.uid(1),'com.sheepfarm.ios.pro.monthly','active',now()+interval '30 days');
insert into public.farm_registry(farm_id,owner_user_id,provider,authority_generation) values(pg_temp.uid(10),pg_temp.uid(1),'esheep_cloud',2);
insert into public.farm_members(farm_id,user_id,app_account_id,role,status) values(pg_temp.uid(10),pg_temp.uid(1),pg_temp.uid(1),'owner','active'),(pg_temp.uid(10),pg_temp.uid(2),pg_temp.uid(2),'worker','active');
insert into public.devices(device_id,user_id,public_key_jwk,display_name,status) values(pg_temp.uid(11),pg_temp.uid(1),'{"kty":"EC","crv":"P-256"}','Label owner test','active'),(pg_temp.uid(12),pg_temp.uid(2),'{"kty":"EC","crv":"P-256"}','Label worker test','active');
insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready,projection_digest,last_integrity_check_at) values(pg_temp.uid(10),2,'active',true,repeat('0',64),now());
create temp sequence label_sequence;
-- Enters the database transaction at the verified-signature boundary, as
-- esheep_cloud_v2.test.sql does. The Edge cryptographic verifier is separate.
create function pg_temp.item(k text,body jsonb,st text,sid uuid,changes jsonb default '[]',who int default 1) returns jsonb language plpgsql as $$
declare u jsonb; b bytea; obs jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('stream',jsonb_build_object('type',st,'id',sid),'field',c->>'field','observedVersion',coalesce((s.field_versions->(c->>'field')->>'version')::bigint,0),'baseValueDigest',coalesce(s.field_versions->(c->>'field')->>'value_digest',esheep_cloud.value_digest('{"type":"null"}')))),'[]') into obs
 from jsonb_array_elements(changes) c left join esheep_cloud.streams s on s.farm_id=pg_temp.uid(10) and s.farm_generation=2 and s.stream_type=st and s.stream_id=sid;
 u:=jsonb_build_object('protocolVersion',2,'schemaVersion',1,'commandID',gen_random_uuid(),'sourceRequestID',gen_random_uuid(),'farmID',pg_temp.uid(10),'farmGeneration',2,'accountID',pg_temp.uid(who),'deviceID',pg_temp.uid(who+10),'deviceSequence',nextval('label_sequence'),'createdAt',1800000000000,'occurredAt',1800000000000,'commandKind',k,'payload',jsonb_build_object('kind',k,'body',body),'affectedStreams',jsonb_build_array(jsonb_build_object('type',st,'id',sid)),'affectedFields',obs,'fieldChanges',changes,'prerequisiteCommandIDs','[]'::jsonb,'requiredAssetIDs','[]'::jsonb);
 b:=convert_to(u::text,'utf8'); return jsonb_build_object('unsigned_command_base64',encode(b,'base64'),'content_digest',encode(digest(b,'sha256'),'hex'),'device_signature_base64',encode(repeat('x',64)::bytea,'base64'));
end $$;
create function pg_temp.submit(i jsonb,who int default 1) returns jsonb language sql as $$ select esheep_cloud.process_command_v2(pg_temp.uid(10),2,pg_temp.uid(who),i) $$;
create function pg_temp.label_body(a text,d jsonb) returns jsonb language sql immutable as $$select jsonb_build_object('sheepLabels',jsonb_build_object('_0',jsonb_build_object(a,jsonb_build_object('_0',d))))$$;
create function pg_temp.save_label(n int,color text,rev int default 0,who int default 1) returns jsonb language sql as $$ select pg_temp.submit(pg_temp.item('care.sheepLabel.save',pg_temp.label_body('saveLabel',jsonb_build_object('id',pg_temp.uid(n),'changeID',gen_random_uuid(),'name','标签 '||n,'color',color,'note','','sortOrder',n,'isActive',true,'expectedRevision',rev)),'sheepLabel',pg_temp.uid(n),'[]',who),who) $$;
create function pg_temp.edit(sheep int,adds int[],removes int[] default '{}',who int default 1) returns jsonb language sql as $$select pg_temp.submit(pg_temp.item('care.sheepLabels.edit',pg_temp.label_body('editLabels',jsonb_build_object('id',gen_random_uuid(),'sheepID',pg_temp.uid(sheep),'addIDs',coalesce((select jsonb_agg(pg_temp.uid(n)) from unnest(adds)n),'[]'),'removeIDs',coalesce((select jsonb_agg(pg_temp.uid(n)) from unnest(removes)n),'[]'),'setsPrimary',false)),'sheepLabels',pg_temp.uid(sheep),'[]',who),who)$$;
select is(pg_temp.submit(pg_temp.item('sheep.add','{"add":{"earTag":"TEST-RAM","breed":"湖羊","sex":"ram","occurredAt":1800000000000,"note":""}}','sheep',pg_temp.uid(20)))->>'type','accepted','ordinary sheep add still works');
select is(pg_temp.submit(pg_temp.item('sheep.add','{"add":{"earTag":"TEST-EWE","breed":"湖羊","sex":"ewe","occurredAt":1800000000000,"note":""}}','sheep',pg_temp.uid(21)))->>'type','accepted','ordinary ewe add still works');
select is(pg_temp.save_label(30,'yellow')->>'type','accepted','catalog save receives accepted receipt');
select is(pg_temp.save_label(31,'green')->>'type','accepted','second color receives accepted receipt');
select is(pg_temp.edit(20,array[30])->>'type','accepted','ram yellow writes through full transaction');
select is(pg_temp.edit(21,array[31],'{}',2)->>'type','accepted','worker can label ewe green');
select throws_like($$select pg_temp.edit(20,array[31])$$,'%不适用%','ram green rejected');
select is((select cardinality(label_ids) from esheep_cloud.sheep_label_assignments where sheep_id=pg_temp.uid(20)),1,'failed addition leaves old labels intact');
select throws_like($$select pg_temp.save_label(32,'red',0,2)$$,'%command_permission_denied%','worker cannot maintain catalogs');
select throws_like($$select pg_temp.save_label(30,'green',1)$$,'%冲突%','recolor rejects assigned wrong sex');
select throws_like($$select pg_temp.save_label(30,'yellow',0)$$,'%其他成员%','stale catalog revision rejected');
select throws_like($$select pg_temp.edit(99,array[30])$$,'%羊只不存在%','missing or foreign sheep rejected');
create temp table repeated as select pg_temp.item('care.sheepLabels.edit',pg_temp.label_body('editLabels',jsonb_build_object('id',gen_random_uuid(),'sheepID',pg_temp.uid(20),'addIDs','[]'::jsonb,'removeIDs','[]'::jsonb,'setsPrimary',false)),'sheepLabels',pg_temp.uid(20)) as item;
select is(pg_temp.submit((select item from repeated))->>'type','accepted','retry fixture first command accepted');
select set_config('esheep.label.before_retry',(select event_head::text from esheep_cloud.farm_state where farm_id=pg_temp.uid(10)),true);
select is(pg_temp.submit((select item from repeated))->>'type','duplicate','same signed command retry is acknowledged as duplicate');
select is((select event_head::text from esheep_cloud.farm_state where farm_id=pg_temp.uid(10)),current_setting('esheep.label.before_retry'),'retry does not add an event');
create temp table profile as select jsonb_build_object('id',gen_random_uuid(),'sheepID',pg_temp.uid(20),'earTag','TEST-RAM','breed','湖羊','sex','ewe','birthAt',null,'note','','removeLabelIDs',jsonb_build_array(pg_temp.uid(30)),'expectedRevision',1) as d;
create temp table profile_changes as select jsonb_agg(jsonb_build_object('field',f,'mutation',case when f in ('birthAt','currentParity','parityRecordedAt') then jsonb_build_object('action','clear') else jsonb_build_object('action','set','value',jsonb_build_object('type','string','value',d->f))end)) as c from profile cross join unnest(array['earTag','breed','sex','birthAt','note','currentParity','parityRecordedAt'])f;
select is(pg_temp.submit(pg_temp.item('care.sheepLabels.patchProfile',pg_temp.label_body('patchProfile',(select d from profile)),'sheepProfile',pg_temp.uid(20),(select c from profile_changes)))->>'type','accepted','sex and explicit cleanup accepted atomically');
select is((select cardinality(label_ids) from esheep_cloud.sheep_label_assignments where sheep_id=pg_temp.uid(20)),0,'conflicting label removed');
select is(esheep_cloud.sheep_label_subject_sex(pg_temp.uid(10),2,pg_temp.uid(20)),'ewe','authoritative sex updated');
select is(pg_temp.edit(20,array[31])->>'type','accepted','new sex permits green');
select throws_like($$select pg_temp.edit(20,array[30])$$,'%不适用%','new sex rejects yellow');
select ok((select bool_and(esheep_cloud.server_handler_available_v2(command_kind)) from esheep_cloud.command_catalog where command_kind like 'care.sheepLabel%'),'all three new command routes ready');
select * from finish();
rollback;
