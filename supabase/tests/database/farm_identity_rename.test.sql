begin;
create extension if not exists pgtap with schema extensions;
select plan(31);
select set_config('rename.owner',gen_random_uuid()::text,true);
select set_config('rename.worker',gen_random_uuid()::text,true);
select set_config('rename.outsider',gen_random_uuid()::text,true);
select set_config('rename.farm',gen_random_uuid()::text,true);
select set_config('rename.copy',gen_random_uuid()::text,true);
select set_config('rename.request',gen_random_uuid()::text,true);
insert into auth.users(id,aud,role,email,email_confirmed_at)
select current_setting('rename.'||u)::uuid,'authenticated','authenticated',u||'-'||gen_random_uuid()||'@example.invalid',now()
from unnest(array['owner','worker','outsider']) u;
insert into public.entitlements(owner_user_id,product_id,state,valid_until)
values(current_setting('rename.owner')::uuid,'com.sheepfarm.ios.pro.monthly','active',now()+interval '1 day');
insert into public.farm_registry(farm_id,owner_user_id,provider,status,authority_generation,current_revision)
select current_setting('rename.'||f)::uuid,current_setting('rename.owner')::uuid,'esheep_cloud','active',3,0
from unnest(array['farm','copy']) f;
insert into public.farm_members(farm_id,user_id,app_account_id,role,status)
select r.farm_id,p.user_id,p.app_account_id,case when p.user_id=current_setting('rename.owner')::uuid then 'owner' else 'worker' end,'active'
from public.farm_registry r cross join public.profiles p
where r.farm_id in(current_setting('rename.farm')::uuid,current_setting('rename.copy')::uuid)
and p.user_id in(current_setting('rename.owner')::uuid,current_setting('rename.worker')::uuid);
insert into esheep_cloud.farm_state(farm_id,farm_generation,status,v2_ready,event_head)
select current_setting('rename.'||f)::uuid,3,'active',true,7 from unnest(array['farm','copy']) f;
insert into esheep_cloud.farm_profiles(farm_id,farm_generation,owner_account_id,name,created_at,updated_at)
select current_setting('rename.'||f)::uuid,3,p.app_account_id,
case when f='farm' then '星露谷牧场' else '星露谷牧场 · 外测审核副本' end,now(),now()
from unnest(array['farm','copy']) f cross join public.profiles p where p.user_id=current_setting('rename.owner')::uuid;
select ok(not has_function_privilege('anon','public.esheep_cloud_rename_farm_v2(uuid,integer,text,bigint,uuid)','EXECUTE'),'anonymous rename denied');
select ok(not has_table_privilege('authenticated','esheep_cloud.farm_name_commands','INSERT'),'clients cannot forge audit');
select ok((select relrowsecurity from pg_class where oid='esheep_cloud.farm_name_commands'::regclass),'audit RLS enabled');
select set_config('request.jwt.claim.sub',current_setting('rename.owner'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select is(public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,' 吉昊羊场 ',0,current_setting('rename.request')::uuid)->>'name','吉昊羊场','owner renames through audited command');
select is((select name_revision from esheep_cloud.farm_profiles where farm_id=current_setting('rename.farm')::uuid),1::bigint,'revision increments');
select is(public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',0,current_setting('rename.request')::uuid)->>'revision','1','same request idempotent');
select is((select count(*) from esheep_cloud.farm_name_commands where farm_id=current_setting('rename.farm')::uuid),1::bigint,'one audit row after retry');
select is((select previous_name from esheep_cloud.farm_name_commands where request_id=current_setting('rename.request')::uuid),'星露谷牧场','old name retained');
select is((select name from esheep_cloud.farm_profiles where farm_id=current_setting('rename.copy')::uuid),'星露谷牧场 · 外测审核副本','review copy untouched');
select is((select event_head from esheep_cloud.farm_state where farm_id=current_setting('rename.farm')::uuid),7::bigint,'business cursor untouched');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'另一个名称',0,gen_random_uuid())$$,'40001','esheep_cloud_farm_name_conflict','stale name rejected');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'不同内容',0,current_setting('rename.request')::uuid)$$,'22023','esheep_cloud_request_reused','request content immutable');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,4,'错代',1,gen_random_uuid())$$,'55000','esheep_cloud_generation_mismatch','wrong generation rejected');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,' ',1,gen_random_uuid())$$,'22023','esheep_cloud_farm_name_invalid','blank rejected');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,repeat('羊',81),1,gen_random_uuid())$$,'22023','esheep_cloud_farm_name_invalid','oversized name rejected');
select is(public.esheep_cloud_pull_events_v2(current_setting('rename.farm')::uuid,3,7,500)#>>'{farm_identity,name}','吉昊羊场','empty event page has latest name');
select is(public.esheep_cloud_fetch_status_v2(current_setting('rename.farm')::uuid)#>>'{farm_identity,name}','吉昊羊场','status has latest name');
select set_config('request.jwt.claim.sub',current_setting('rename.worker'),true);
select is(public.esheep_cloud_farm_identity_v2(current_setting('rename.farm')::uuid,3)->>'name','吉昊羊场','worker reads latest name');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'员工改名',1,gen_random_uuid())$$,'42501','esheep_cloud_owner_required','worker cannot rename');
select set_config('request.jwt.claim.sub',current_setting('rename.outsider'),true);
select throws_ok($$select public.esheep_cloud_farm_identity_v2(current_setting('rename.farm')::uuid,3)$$,'42501','esheep_cloud_farm_read_denied','outsider cannot read identity');
select set_config('request.jwt.claim.sub',current_setting('rename.owner'),true);
update esheep_cloud.farm_state set write_frozen=true where farm_id=current_setting('rename.farm')::uuid;
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'冻结期间改名',1,gen_random_uuid())$$,'55000','esheep_cloud_farm_not_writable','frozen farm cannot rename');
select is((select name from esheep_cloud.farm_profiles where farm_id=current_setting('rename.farm')::uuid),'吉昊羊场','rejected operations preserve name');
-- Auth claims alone do not impersonate the database role. Verify both ACLs
-- and actual execution as the client role to catch the DDL exposure guard.
select ok(has_function_privilege('authenticated','public.esheep_cloud_list_my_farms_v2()','EXECUTE'),'signed-in discovery grant retained');
select ok(has_function_privilege('authenticated','public.esheep_cloud_fetch_status_v2(uuid)','EXECUTE'),'signed-in status grant retained');
select ok(has_function_privilege('authenticated','public.esheep_cloud_pull_events_v2(uuid,integer,bigint,integer)','EXECUTE'),'signed-in event grant retained');
select ok(not has_function_privilege('anon','public.esheep_cloud_list_my_farms_v2()','EXECUTE'),'anonymous discovery denied');
select ok(not has_function_privilege('anon','public.esheep_cloud_fetch_status_v2(uuid)','EXECUTE'),'anonymous status denied');
select ok(not has_function_privilege('anon','public.esheep_cloud_pull_events_v2(uuid,integer,bigint,integer)','EXECUTE'),'anonymous event access denied');
set local role authenticated;
select lives_ok($$select public.esheep_cloud_list_my_farms_v2()$$,'actual client role can discover farms');
select lives_ok($$select public.esheep_cloud_fetch_status_v2(current_setting('rename.farm')::uuid)$$,'actual client role can read status');
select lives_ok($$select public.esheep_cloud_pull_events_v2(current_setting('rename.farm')::uuid,3,7,500)$$,'actual client role can read empty event page');
reset role;
select * from finish();
rollback;
