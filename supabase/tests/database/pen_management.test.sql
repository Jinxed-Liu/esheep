begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
create function pg_temp.uid(n int) returns uuid language sql immutable as $$ select ('fc000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
insert into auth.users(id) values(pg_temp.uid(1)),(pg_temp.uid(2));
insert into public.entitlements(owner_user_id,product_id,state,valid_until) values(pg_temp.uid(1),'com.sheepfarm.ios.pro.monthly','active',now()+interval '30 days');
insert into public.farm_registry(farm_id,owner_user_id,provider,authority_generation) values(pg_temp.uid(10),pg_temp.uid(1),'esheep_cloud',2);
insert into public.farm_members(farm_id,user_id,app_account_id,role,status) values(pg_temp.uid(10),pg_temp.uid(1),pg_temp.uid(1),'owner','active'),(pg_temp.uid(10),pg_temp.uid(2),pg_temp.uid(2),'worker','active');
insert into public.devices(device_id,user_id,public_key_jwk,display_name,status) values(pg_temp.uid(11),pg_temp.uid(1),'{"kty":"EC","crv":"P-256"}','Pen owner test','active'),(pg_temp.uid(12),pg_temp.uid(2),'{"kty":"EC","crv":"P-256"}','Pen worker test','active');
insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready,projection_digest,last_integrity_check_at) values(pg_temp.uid(10),2,'active',true,repeat('0',64),now());
create temp sequence pen_sequence;
-- Enters the database transaction at the verified-signature boundary, as
-- esheep_cloud_v2.test.sql does. The Edge cryptographic verifier is separate.
create function pg_temp.item(k text,body jsonb,st text,sid uuid,changes jsonb default '[]',who int default 1) returns jsonb language plpgsql as $$
declare u jsonb; b bytea; obs jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('stream',jsonb_build_object('type',st,'id',sid),'field',c->>'field','observedVersion',coalesce((s.field_versions->(c->>'field')->>'version')::bigint,0),'baseValueDigest',coalesce(s.field_versions->(c->>'field')->>'value_digest',esheep_cloud.value_digest('{"type":"null"}')))),'[]') into obs
 from jsonb_array_elements(changes) c left join esheep_cloud.streams s on s.farm_id=pg_temp.uid(10) and s.farm_generation=2 and s.stream_type=st and s.stream_id=sid;
 u:=jsonb_build_object('protocolVersion',2,'schemaVersion',1,'commandID',gen_random_uuid(),'sourceRequestID',gen_random_uuid(),'farmID',pg_temp.uid(10),'farmGeneration',2,'accountID',pg_temp.uid(who),'deviceID',pg_temp.uid(who+10),'deviceSequence',nextval('pen_sequence'),'createdAt',1800000000000,'occurredAt',1800000000000,'commandKind',k,'payload',jsonb_build_object('kind',k,'body',body),'affectedStreams',jsonb_build_array(jsonb_build_object('type',st,'id',sid)),'affectedFields',obs,'fieldChanges',changes,'prerequisiteCommandIDs','[]'::jsonb,'requiredAssetIDs','[]'::jsonb);
 b:=convert_to(u::text,'utf8'); return jsonb_build_object('unsigned_command_base64',encode(b,'base64'),'content_digest',encode(digest(b,'sha256'),'hex'),'device_signature_base64',encode(repeat('x',64)::bytea,'base64'));
end $$;
create function pg_temp.submit(i jsonb,who int default 1) returns jsonb language sql as $$ select esheep_cloud.process_command_v2(pg_temp.uid(10),2,pg_temp.uid(who),i) $$;

create function pg_temp.create_pen(n int,name text,who int default 1) returns jsonb language sql as $$
 select pg_temp.submit(pg_temp.item('pen.create',jsonb_build_object('create',jsonb_build_object('name',name,'note','')),'pen',pg_temp.uid(n),'[]',who),who)
$$;
create function pg_temp.rename_pen(n int,name text,note text default '') returns jsonb language sql as $$
 select pg_temp.submit(pg_temp.item('pen.update',jsonb_build_object('update',jsonb_build_object('penID',pg_temp.uid(n),'name',name,'note',note)),'pen',pg_temp.uid(n),jsonb_build_array(
 jsonb_build_object('field','name','mutation',jsonb_build_object('action','set','value',jsonb_build_object('type','string','value',name))),
 jsonb_build_object('field','note','mutation',jsonb_build_object('action','set','value',jsonb_build_object('type','string','value',note))))))
$$;
create function pg_temp.activate(n int,active boolean,who int default 1) returns jsonb language sql as $$
 select pg_temp.submit(pg_temp.item('pen.setActive',jsonb_build_object('setActive',jsonb_build_object('penID',pg_temp.uid(n),'isActive',active)),'pen',pg_temp.uid(n),jsonb_build_array(
 jsonb_build_object('field','isActive','mutation',jsonb_build_object('action','set','value',jsonb_build_object('type','boolean','value',active)))),who),who)
$$;
create function pg_temp.revoke_pen(n int,who int default 1) returns jsonb language sql as $$
 select pg_temp.submit(pg_temp.item('record.revoke',jsonb_build_object('tombstone',jsonb_build_object('entityType','pen','entityID',pg_temp.uid(n),'reason','误建')),'pen',pg_temp.uid(n),'[]',who),who)
$$;
select is(esheep_cloud.pen_name_key(E' \nA舍　'),'a舍','same edge whitespace and case normalization as iOS');
select is(esheep_cloud.pen_name_key('V舍V'),'v舍v','letter v is never trimmed as whitespace');
select is(pg_temp.create_pen(30,'A舍')->>'type','accepted','create pen through command transaction');
select is(pg_temp.create_pen(31,'B舍',2)->>'type','accepted','worker can create pen');
select throws_like($$select pg_temp.create_pen(32,E' a舍\n')$$,'%同名羊舍%','normalized duplicate create rejected');
select throws_like($$select pg_temp.create_pen(33,E' \n　')$$,'%填写羊舍名称%','blank name rejected');
select throws_like($$select pg_temp.rename_pen(31,'a舍')$$,'%同名羊舍%','rename collision rejected');
select is((select name_key from esheep_cloud.pen_management_catalog where farm_id=pg_temp.uid(10) and pen_id=pg_temp.uid(31)),'b舍','rejected rename rolls back catalog');
select is(pg_temp.activate(30,false)->>'type','accepted','owner deactivates unused pen');
select throws_like($$select pg_temp.create_pen(32,'A舍')$$,'%同名羊舍%','inactive pen still reserves name');
select throws_like($$select pg_temp.activate(31,false,2)$$,'%permission_denied%','worker cannot deactivate');
select throws_like($$select pg_temp.revoke_pen(31,2)$$,'%permission_denied%','worker cannot delete');
select is(pg_temp.activate(30,true)->>'type','accepted','owner reactivates');
select is(pg_temp.revoke_pen(31)->>'type','accepted','unused pen can be tombstoned');
select ok((select is_deleted from esheep_cloud.pen_management_catalog where farm_id=pg_temp.uid(10) and pen_id=pg_temp.uid(31)),'deleted catalog row retained');
select ok(exists(select 1 from esheep_cloud.events where farm_id=pg_temp.uid(10) and stream_id=pg_temp.uid(31) and event_body->>'command_kind'='pen.create'),'original create event retained');
select throws_like($$select pg_temp.rename_pen(31,'C舍')$$,'%已删除%','cannot edit deleted pen');
select is(pg_temp.create_pen(32,'B舍')->>'type','accepted','deleted unused pen releases name');
select throws_like($$select pg_temp.submit(pg_temp.item('record.restore',jsonb_build_object('restore',jsonb_build_object('tombstoneID',pg_temp.uid(90))),'pen',pg_temp.uid(31)))$$,'%同名羊舍%','restore cannot reclaim another pen name');
select is(pg_temp.submit(pg_temp.item('sheep.add',jsonb_build_object('add',jsonb_build_object('earTag','P-TEST','breed','湖羊','sex','ewe','penID',pg_temp.uid(30),'occurredAt',1800000000000,'note','')),'sheep',pg_temp.uid(40)))->>'type','accepted','business reference accepted');
select throws_like($$select pg_temp.revoke_pen(30)$$,'%历史记录引用%','pen with sheep history cannot be deleted');
select throws_like($$select pg_temp.submit(pg_temp.item('sheep.add',jsonb_build_object('add',jsonb_build_object('earTag','P-OLD','breed','湖羊','sex','ewe','penID',pg_temp.uid(31),'occurredAt',1800000000000,'note','')),'sheep',pg_temp.uid(41)))$$,'%羊舍已删除%','stale device cannot reference deleted pen');
select is((select count(*) from esheep_cloud.streams where farm_id=pg_temp.uid(10) and stream_type='sheep' and stream_id=pg_temp.uid(41)),0::bigint,'rejected business command leaves no sheep stream');
select is((select count(*) from esheep_cloud.pen_reference_ids(jsonb_build_object('plans',jsonb_build_array(jsonb_build_object('targetPenID',pg_temp.uid(30))), 'penIDs',jsonb_build_array(pg_temp.uid(32)), 'note',pg_temp.uid(99)::text))),2::bigint,'nested TMR and arrays are protected; free text is not a reference');
select is((select allowed_roles from esheep_cloud.command_catalog where command_kind='pen.setActive'),array['owner','administrator'],'server lifecycle roles match client');
select ok(not has_table_privilege('authenticated','esheep_cloud.pen_management_catalog','INSERT'),'client cannot bypass catalog guards');
select ok(not has_function_privilege('authenticated','esheep_cloud.guard_pen_management_event()','EXECUTE'),'trigger helper is private');
select is((select count(*) from esheep_cloud.pen_reference_ids(jsonb_build_object('field','initialPenID','chosen_value',jsonb_build_object('type','uuid','value',pg_temp.uid(30))))),1::bigint,'conflict field values retain historical pen references');

-- A stale rename must also pass the guard when explicitly resolved later.
select is(pg_temp.rename_pen(32,'B舍')->>'type','accepted','seed the current name field version');
create function pg_temp.stale_name(n int,name text) returns jsonb language plpgsql as $$
declare i jsonb; u jsonb; b bytea;
begin
 i:=pg_temp.item('pen.update',jsonb_build_object('update',jsonb_build_object('penID',pg_temp.uid(n),'name',name,'note','')),'pen',pg_temp.uid(n),jsonb_build_array(jsonb_build_object('field','name','mutation',jsonb_build_object('action','set','value',jsonb_build_object('type','string','value',name)))),2);
 u:=convert_from(decode(i->>'unsigned_command_base64','base64'),'utf8')::jsonb;
 u:=jsonb_set(jsonb_set(u,'{affectedFields,0,observedVersion}','0'),'{affectedFields,0,baseValueDigest}',to_jsonb(esheep_cloud.value_digest('{"type":"null"}')));
 b:=convert_to(u::text,'utf8');
 return pg_temp.submit(i||jsonb_build_object('unsigned_command_base64',encode(b,'base64'),'content_digest',encode(digest(b,'sha256'),'hex')),2);
end $$;
select is(pg_temp.stale_name(32,'A舍')->>'type','needs_confirmation','stale conflicting name awaits an explicit decision');
create function pg_temp.resolve_name() returns jsonb language sql as $$
 select public.esheep_cloud_resolve_verified_attention_v2(pg_temp.uid(1),pg_temp.uid(10),2,a.attention_id,gen_random_uuid(),'use_this_device',esheep_cloud.value_digest(a.cloud_value),pg_temp.uid(1),pg_temp.uid(11),nextval('pen_sequence'),encode(repeat('x',64)::bytea,'base64'))
 from esheep_cloud.attention_items a where a.farm_id=pg_temp.uid(10) and a.status='open' and a.field_key='name' limit 1
$$;
select throws_like($$select pg_temp.resolve_name()$$,'%同名羊舍%','conflict resolution cannot bypass unique name protection');
select is((select name_key from esheep_cloud.pen_management_catalog where farm_id=pg_temp.uid(10) and pen_id=pg_temp.uid(32)),'b舍','failed resolution preserves current name');
select is((select status from esheep_cloud.attention_items where farm_id=pg_temp.uid(10) and field_key='name' limit 1),'open','failed resolution preserves the open decision');

select is(pg_temp.activate(32,true)->>'type','accepted','seed active state for lifecycle conflict');
create function pg_temp.stale_active() returns jsonb language plpgsql as $$
declare i jsonb; u jsonb; b bytea;
begin
 i:=pg_temp.item('pen.setActive',jsonb_build_object('setActive',jsonb_build_object('penID',pg_temp.uid(32),'isActive',false)),'pen',pg_temp.uid(32),jsonb_build_array(jsonb_build_object('field','isActive','mutation',jsonb_build_object('action','set','value',jsonb_build_object('type','boolean','value',false)))),2);
 u:=convert_from(decode(i->>'unsigned_command_base64','base64'),'utf8')::jsonb;
 u:=jsonb_set(jsonb_set(u,'{affectedFields,0,observedVersion}','0'),'{affectedFields,0,baseValueDigest}',to_jsonb(esheep_cloud.value_digest('{"type":"null"}')));
 b:=convert_to(u::text,'utf8');
 return pg_temp.submit(i||jsonb_build_object('unsigned_command_base64',encode(b,'base64'),'content_digest',encode(digest(b,'sha256'),'hex')),2);
end $$;
update public.farm_members set role='administrator' where farm_id=pg_temp.uid(10) and user_id=pg_temp.uid(2);
select is(pg_temp.stale_active()->>'type','needs_confirmation','administrator lifecycle conflict awaits choice');
update public.farm_members set role='worker' where farm_id=pg_temp.uid(10) and user_id=pg_temp.uid(2);
create function pg_temp.resolve_active(who int) returns jsonb language sql as $$
 select public.esheep_cloud_resolve_verified_attention_v2(pg_temp.uid(who),pg_temp.uid(10),2,a.attention_id,gen_random_uuid(),'use_this_device',esheep_cloud.value_digest(a.cloud_value),pg_temp.uid(who),pg_temp.uid(who+10),nextval('pen_sequence'),encode(repeat('x',64)::bytea,'base64'))
 from esheep_cloud.attention_items a where a.farm_id=pg_temp.uid(10) and a.status='open' and a.field_key='isActive' limit 1
$$;
select throws_like($$select pg_temp.resolve_active(2)$$,'%仅限牧场主或管理员%','worker cannot bypass lifecycle roles through a conflict');
select is((select canonical_state#>>'{isActive,value}' from esheep_cloud.streams where farm_id=pg_temp.uid(10) and stream_type='pen' and stream_id=pg_temp.uid(32)),'true','denied lifecycle resolution leaves pen active');
select is(pg_temp.resolve_active(1)->>'type','accepted','owner can resolve lifecycle conflict');
select * from finish();
rollback;
