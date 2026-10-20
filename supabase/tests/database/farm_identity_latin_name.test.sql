begin;
create extension if not exists pgtap with schema extensions;
select plan(16);
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
select set_config('request.jwt.claim.sub',current_setting('rename.owner'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select ok(not has_function_privilege('anon','public.esheep_cloud_update_farm_identity_v2(uuid,integer,text,text,bigint,uuid)','EXECUTE'),'anonymous update denied');
set local role authenticated;
select is(public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',' Jihao Farm ',0,current_setting('rename.request')::uuid)->>'latinName','Jihao Farm','actual owner role saves global name');
select is(public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',' Jihao Farm ',0,current_setting('rename.request')::uuid)->>'revision','1','retry idempotent');
select throws_ok($$select public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场','Other',0,current_setting('rename.request')::uuid)$$,'22023','esheep_cloud_request_reused','request cannot change Latin value');
select throws_ok($$select public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场','Other',0,gen_random_uuid())$$,'40001','esheep_cloud_farm_name_conflict','stale edit rejected');
select throws_ok($$select public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',repeat('A',81),1,gen_random_uuid())$$,'22023','esheep_cloud_farm_name_invalid','overlong Latin name rejected');
select throws_ok($$select public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',E'Bad\nName',1,gen_random_uuid())$$,'22023','esheep_cloud_farm_name_invalid','control characters rejected');
select is(public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'新中文名',1,gen_random_uuid())->>'latinName','Jihao Farm','old client preserves Latin name');
select throws_ok($$select public.esheep_cloud_rename_farm_v2(current_setting('rename.farm')::uuid,3,'吉昊羊场',0,current_setting('rename.request')::uuid)$$,'22023','esheep_cloud_request_reused','legacy endpoint cannot reuse new command id');
select set_config('request.jwt.claim.sub',current_setting('rename.worker'),true);
select is(public.esheep_cloud_pull_events_v2(current_setting('rename.farm')::uuid,3,7,500)#>>'{farm_identity,latinName}','Jihao Farm','member receives Latin name in regular sync');
select throws_ok($$select public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'新中文名','Other',2,gen_random_uuid())$$,'42501','esheep_cloud_owner_required','worker cannot edit global name');
select set_config('request.jwt.claim.sub',current_setting('rename.owner'),true);
select is(public.esheep_cloud_update_farm_identity_v2(current_setting('rename.farm')::uuid,3,'新中文名',' ',2,gen_random_uuid())->>'latinName',null,'clearing value syncs null');
reset role;
select is((select name_revision from esheep_cloud.farm_profiles where farm_id=current_setting('rename.farm')::uuid),3::bigint,'both name fields share revision');
select is((select requested_latin_name from esheep_cloud.farm_name_commands where request_id=current_setting('rename.request')::uuid),'Jihao Farm','audit records submitted value');
select is((select event_head from esheep_cloud.farm_state where farm_id=current_setting('rename.farm')::uuid),7::bigint,'business history unchanged');
select is((select latin_name from esheep_cloud.farm_profiles where farm_id=current_setting('rename.copy')::uuid),null,'other farm untouched');
select * from finish();
rollback;
