-- Audited corrections for all event-history editors. Keep existing protocol gates.
insert into esheep_cloud.command_catalog(command_kind,merge_mode,allowed_roles,requires_online)
values ('event.correct','state_machine',array['owner','administrator'],false);

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
    'when ''productionBatch.update'' then ''updateBatch'''
    else 'when ''productionBatch.update'' then ''productionBatch.update''' end;
  after_text:=case when signature like '%expected_payload_case%' then
    'when ''event.correct'' then ''correctEvent'''
    else 'when ''event.correct'' then ''event.correct''' end;
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
    raise exception 'batch route definition changed: %',signature;
  end if;
  after_text:=before_text||E'\n    '||after_text;
  execute replace(d,before_text,after_text);
 end loop;
end
$migration$;

create function esheep_cloud.validate_event_correction_v2(p_payload jsonb,p_streams jsonb,p_mode text,p_fields jsonb,p_changes jsonb)
returns void language plpgsql immutable set search_path='' as $$
declare v jsonb := p_payload #> '{body,correctEvent,_0}'; target text;
begin
 target:=case v->>'kind'
  when 'weaning' then 'weaning' when 'feed' then 'feed' when 'note' then 'note'
  when 'inventory' then 'inventoryTransaction' when 'semen' then 'semenTransaction'
  when 'departure' then 'batchMembership' when 'purpose' then 'sheep' when 'parity' then 'reproduction'
  else null end;
 if p_mode is distinct from 'state_machine' or target is null
  or jsonb_typeof(v) is distinct from 'object'
  or not (v ?& array['kind','entityID','sourceEventID','occurredAt','text','value','withdraw'])
  or (select count(*) from jsonb_object_keys(v)) <> 7
  or coalesce(v->>'entityID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  or coalesce(v->>'sourceEventID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  or jsonb_typeof(v->'occurredAt') is distinct from 'number'
  or jsonb_typeof(v->'text') is distinct from 'string'
  or jsonb_typeof(v->'value') is distinct from 'string'
  or jsonb_typeof(v->'withdraw') is distinct from 'boolean'
  or (v->>'withdraw' = 'true' and v->>'kind' not in ('purpose','parity'))
  or (v->>'kind' <> 'purpose' and v->>'entityID' is distinct from v->>'sourceEventID')
  or jsonb_typeof(p_streams) is distinct from 'array' or jsonb_array_length(p_streams)<>1
  or p_streams#>>'{0,type}' is distinct from target
  or p_streams#>>'{0,id}' is distinct from v->>'entityID'
  or coalesce(jsonb_array_length(p_fields),-1)<>0 or coalesce(jsonb_array_length(p_changes),-1)<>0 then
  raise exception using errcode='22023',message='esheep_cloud_event_correction_invalid';
 end if;
end
$$;
revoke all on function esheep_cloud.validate_event_correction_v2(jsonb,jsonb,text,jsonb,jsonb) from public,anon,authenticated;

do $migration$
declare d text; marker text := '  if p_kind = ''farm.updateLocation'' then';
begin
 d:=pg_get_functiondef('esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure);
 if position(marker in d)=0 or position(marker in replace(d,marker,''))<>0 then raise exception 'event validator wrapper changed'; end if;
 execute replace(d,marker,$event_validation$
  if p_kind = 'event.correct' then
    perform esheep_cloud.validate_event_correction_v2(v_payload,v_streams,p_merge_mode,v_fields,p_field_changes);
  end if;
$event_validation$||marker);
end
$migration$;
