-- Edit production-batch metadata through an audited state-machine event.
-- Deleted batches remain deleted; the client reducer updates metadata only.


insert into esheep_cloud.command_catalog (command_kind, merge_mode, allowed_roles, requires_online)
values ('productionBatch.update', 'state_machine', array['owner', 'administrator'], false)
on conflict (command_kind) do update set merge_mode = excluded.merge_mode, allowed_roles = excluded.allowed_roles, requires_online = excluded.requires_online;


-- Extend installed routes in place so later label and migration routes survive.
do $migration$
declare d text; before_text text; after_text text; signature text;
begin
 foreach signature in array array[
  'esheep_cloud.expected_payload_case_v2(text)',
  'esheep_cloud.dispatch_command_v2(text,jsonb,text,jsonb)',
  'esheep_cloud.client_projection_route_v2(text)'
 ] loop
  d:=pg_get_functiondef(signature::regprocedure);
  before_text:=case when signature like '%expected_payload_case%' then
    'when ''productionBatch.create'' then ''createBatch'''
    else 'when ''productionBatch.create'' then ''productionBatch.create''' end;
  after_text:=case when signature like '%expected_payload_case%' then
    'when ''productionBatch.update'' then ''updateBatch'''
    else 'when ''productionBatch.update'' then ''productionBatch.update''' end;
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
    raise exception 'batch route definition changed: %',signature;
  end if;
  after_text:=before_text||E'\n    '||after_text;
  execute replace(d,before_text,after_text);
 end loop;
 foreach signature in array array[
  'esheep_cloud.primary_stream_v2(text,jsonb)',
  'esheep_cloud.validate_command_semantics_v2_legacy(text,jsonb,text,jsonb,jsonb,jsonb)'
 ] loop
  d:=pg_get_functiondef(signature::regprocedure);
  before_text:='when p_kind = ''productionBatch.create'' then ''productionBatch''';
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
    raise exception 'batch stream definition changed: %',signature;
  end if;
  execute replace(d,before_text,before_text||E'\n    when p_kind = ''productionBatch.update'' then ''productionBatch''');
 end loop;
end
$migration$;

-- Keep every existing semantic gate and add strict batch metadata validation.
do $migration$
declare d text; marker text := '  if p_kind = ''farm.updateLocation'' then';
begin
 d:=pg_get_functiondef('esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure);
 if position(marker in d)=0 or position(marker in replace(d,marker,''))<>0 then
   raise exception 'batch validator wrapper changed';
 end if;
 execute replace(d,marker,$batch_validation$
  if p_kind = 'productionBatch.update' then
    if p_merge_mode <> 'state_machine'
       or jsonb_typeof(v_payload #> '{body,updateBatch}') <> 'object'
       or (select count(*) from jsonb_object_keys(v_payload #> '{body,updateBatch}')) <> 4
       or not ((v_payload #> '{body,updateBatch}') ?& array['batchID','name','purpose','startedAt'])
       or coalesce(v_payload #>> '{body,updateBatch,batchID}', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       or nullif(btrim(v_payload #>> '{body,updateBatch,name}'), '') is null
       or nullif(btrim(v_payload #>> '{body,updateBatch,purpose}'), '') is null
       or jsonb_typeof(v_payload #> '{body,updateBatch,name}') is distinct from 'string'
       or jsonb_typeof(v_payload #> '{body,updateBatch,purpose}') is distinct from 'string'
       or jsonb_typeof(v_payload #> '{body,updateBatch,startedAt}') is distinct from 'number'
       or jsonb_typeof(v_streams) <> 'array'
       or jsonb_array_length(v_streams) <> 1
       or v_streams #>> '{0,type}' <> 'productionBatch'
       or (v_streams #>> '{0,id}') is distinct from (v_payload #>> '{body,updateBatch,batchID}')
       or coalesce(jsonb_array_length(v_fields), -1) <> 0
       or coalesce(jsonb_array_length(p_field_changes), -1) <> 0 then
      raise exception using errcode = '22023', message = 'esheep_cloud_batch_update_invalid';
    end if;
  end if;
$batch_validation$||marker);
end
$migration$;
