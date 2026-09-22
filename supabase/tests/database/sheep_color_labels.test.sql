begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(27);
insert into auth.users(id) values('fc000000-0000-0000-0000-000000000001');
insert into public.entitlements(owner_user_id,product_id,state,valid_until) values('fc000000-0000-0000-0000-000000000001','com.sheepfarm.ios.pro.monthly','active',now()+interval '30 days');
insert into public.farm_registry(farm_id,owner_user_id,provider,authority_generation) values('fc000000-0000-0000-0000-000000000002','fc000000-0000-0000-0000-000000000001','esheep_cloud',1);
insert into esheep_cloud.streams(farm_id,farm_generation,stream_type,stream_id,canonical_state)
 select 'fc000000-0000-0000-0000-000000000002',1,'sheepProfile',('fc000000-0000-0000-0000-00000000000'||n)::uuid,jsonb_build_object('sex',jsonb_build_object('type','string','value',sex)) from (values(3,'ram'),(4,'ewe'),(5,'unknown')) s(n,sex);
-- Exercise the production trigger in a rollback-only transaction. Its NEW
-- shape is the production event contract; sex/labels use actual private tables.
create temp table label_test_events(farm_id uuid default 'fc000000-0000-0000-0000-000000000002',farm_generation integer default 1,stream_type text,stream_id uuid,event_kind text default 'business_command',event_body jsonb);
create trigger label_test_projection after insert on label_test_events for each row execute function esheep_cloud.project_sheep_labels_event();
create trigger label_test_delete_projection after insert on label_test_events for each row execute function esheep_cloud.project_sheep_label_delete_event();
create function pg_temp.save_label(p_id integer,p_name text,p_color text,p_active boolean default true,p_revision integer default 0) returns void language sql as $$
 insert into label_test_events(stream_type,stream_id,event_body) values('sheepLabel',('fc000000-0000-0000-0000-'||lpad(p_id::text,12,'0'))::uuid,
 jsonb_build_object('command_kind','care.sheepLabel.save','command_payload',jsonb_build_object('body',jsonb_build_object('sheepLabels',jsonb_build_object('_0',jsonb_build_object('saveLabel',jsonb_build_object('_0',jsonb_build_object('id',('fc000000-0000-0000-0000-'||lpad(p_id::text,12,'0')),'name',p_name,'color',p_color,'note','','sortOrder',p_id,'isActive',p_active,'expectedRevision',p_revision))))))));
$$;
create function pg_temp.edit_labels(p_sheep integer,p_add integer[] default '{}',p_remove integer[] default '{}') returns void language sql as $$
 insert into label_test_events(stream_type,stream_id,event_body) values('sheepLabels',('fc000000-0000-0000-0000-'||lpad(p_sheep::text,12,'0'))::uuid,
 jsonb_build_object('command_kind','care.sheepLabels.edit','command_payload',jsonb_build_object('body',jsonb_build_object('sheepLabels',jsonb_build_object('_0',jsonb_build_object('editLabels',jsonb_build_object('_0',jsonb_build_object('id',gen_random_uuid(),'sheepID',('fc000000-0000-0000-0000-'||lpad(p_sheep::text,12,'0')),'addIDs',coalesce((select jsonb_agg('fc000000-0000-0000-0000-'||lpad(n::text,12,'0')) from unnest(p_add) n),'[]'),'removeIDs',coalesce((select jsonb_agg('fc000000-0000-0000-0000-'||lpad(n::text,12,'0')) from unnest(p_remove) n),'[]'),'setsPrimary',false))))))));
$$;
create function pg_temp.delete_label(p_id integer,p_revision integer) returns void language sql as $$
 insert into label_test_events(stream_type,stream_id,event_body) values('sheepLabel',('fc000000-0000-0000-0000-'||lpad(p_id::text,12,'0'))::uuid,
 jsonb_build_object('command_kind','care.sheepLabel.delete','command_payload',jsonb_build_object('body',jsonb_build_object('sheepLabels',jsonb_build_object('_0',jsonb_build_object('deleteLabel',jsonb_build_object('_0',jsonb_build_object('id',('fc000000-0000-0000-0000-'||lpad(p_id::text,12,'0'))::uuid,'changeID',gen_random_uuid(),'expectedRevision',p_revision))))))));
$$;
select ok(esheep_cloud.sheep_label_color_allows('yellow','ram'),'ram accepts yellow');
select ok(not esheep_cloud.sheep_label_color_allows('green','ram'),'ram rejects green');
select ok(esheep_cloud.sheep_label_color_allows('green','ewe'),'ewe accepts green');
select ok(not esheep_cloud.sheep_label_color_allows('yellow','ewe'),'ewe rejects yellow');
select ok(not esheep_cloud.sheep_label_color_allows('yellow','unknown') and not esheep_cloud.sheep_label_color_allows('green','unknown'),'unknown rejects yellow and green');
select ok((select bool_and(esheep_cloud.sheep_label_color_allows(c,s)) from unnest(array['red','white','orange','light-blue','pink','black','purple','dark-blue']) c cross join unnest(array['ram','ewe','unknown']) s),'eight other colors allow all sexes');
select lives_ok($$select pg_temp.save_label(10,'观察','red')$$,'create red label');
select lives_ok($$select pg_temp.save_label(11,'公羊组','yellow')$$,'create yellow label');
select lives_ok($$select pg_temp.save_label(12,'母羊组','green')$$,'create green label');
select lives_ok($$select pg_temp.edit_labels(3,array[10,11])$$,'add yellow and red to ram');
select throws_like($$select pg_temp.edit_labels(3,array[12])$$,'%标签%','ram green rejected');
select lives_ok($$select pg_temp.edit_labels(4,array[10,12])$$,'add green and red to ewe');
select throws_like($$select pg_temp.edit_labels(4,array[11])$$,'%标签%','ewe yellow rejected');
select lives_ok($$select pg_temp.edit_labels(5,array[10])$$,'unknown can use red');
select throws_like($$select pg_temp.edit_labels(5,array[11])$$,'%标签%','unknown cannot use yellow');
select throws_like($$select pg_temp.save_label(10,'观察','yellow',false,1)$$,'%冲突%','inactive recolor checks all associations');
select throws_like($$select pg_temp.save_label(13,'观察','red')$$,'%sheep_label_unique_name%','farm label names unique');
select lives_ok($$select pg_temp.save_label(10,'观察','red',false,1)$$,'deactivate preserves associations');
select is((select cardinality(label_ids) from esheep_cloud.sheep_label_assignments where sheep_id='fc000000-0000-0000-0000-000000000003'),2,'deactivation retains associations');
select is((select primary_label_id from esheep_cloud.sheep_label_assignments where sheep_id='fc000000-0000-0000-0000-000000000003'),'fc000000-0000-0000-0000-000000000011'::uuid,'primary falls back to active label');
select throws_like($$select pg_temp.edit_labels(3,array[10])$$,'%标签%','inactive cannot be added');
select lives_ok($$select pg_temp.edit_labels(3,'{}',array[10])$$,'inactive can be removed');
select lives_ok($$select pg_temp.delete_label(10,2)$$,'permanent delete removes the catalogue row');
select ok(not exists(select 1 from esheep_cloud.sheep_label_catalog where label_id='fc000000-0000-0000-0000-000000000010'),'deleted label is absent from catalogue');
select ok(not exists(select 1 from esheep_cloud.sheep_label_assignments where 'fc000000-0000-0000-0000-000000000010'::uuid=any(label_ids)),'deleted label is absent from assignments');
select throws_like($$insert into label_test_events(stream_type,stream_id,event_kind,event_body) values('sheepProfile','fc000000-0000-0000-0000-000000000003','fields_patched','{"command_kind":"sheep.patchProfile","changes":[{"field":"sex","value":{"type":"string","value":"ewe"}}]}')$$,'%冲突%','old profile command cannot bypass sex constraint');
select ok(not has_table_privilege('authenticated','esheep_cloud.sheep_label_assignments','INSERT') and not has_table_privilege('authenticated','esheep_cloud.sheep_label_catalog','UPDATE'),'clients cannot bypass command channel through tables');
select * from finish();
rollback;
