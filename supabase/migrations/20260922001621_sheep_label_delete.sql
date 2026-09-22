-- Add an explicit, permissioned permanent-delete command for farm labels.
-- Scoped disable remains an assignment edit: removing a label from selected
-- sheep keeps the shared catalogue entry and affects no other sheep.

create function esheep_cloud.validate_sheep_label_delete_payload(
 p_kind text,
 p_payload jsonb,
 p_streams jsonb
)
returns void language plpgsql immutable set search_path='' as $$
declare
 d jsonb;
 v_id uuid;
begin
 if p_kind <> 'care.sheepLabel.delete' then return; end if;
 d:=p_payload#>array['body','sheepLabels','_0','deleteLabel','_0'];
 if jsonb_typeof(d) is distinct from 'object' then raise exception '标签删除命令内容无效。'; end if;
 v_id:=(d->>'id')::uuid;
 if v_id is null or (d->>'changeID')::uuid is null or (d->>'expectedRevision') is null or (d->>'expectedRevision')::integer<0 then
  raise exception '标签删除命令缺少稳定标识或修订信息。';
 end if;
 if jsonb_array_length(p_streams)<>1 or p_streams->0->>'type'<>'sheepLabel' or (p_streams->0->>'id')::uuid<>v_id then
  raise exception '标签删除对象不匹配。';
 end if;
end
$$;
revoke all on function esheep_cloud.validate_sheep_label_delete_payload(text,jsonb,jsonb) from public,anon,authenticated;

-- Extend the installed semantic validator without changing signed payloads.
do $migration$
declare d text; marker text:='  perform esheep_cloud.validate_sheep_label_payload(p_kind,v_payload,v_streams,v_field_changes);';
begin
 d:=pg_get_functiondef('esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure);
 if position(marker in d)=0 or position(marker in replace(d,marker,''))<>0 then raise exception 'label validator wrapper changed'; end if;
 execute replace(d,marker,marker||E'\n  perform esheep_cloud.validate_sheep_label_delete_payload(p_kind,v_payload,v_streams);');
end
$migration$;

-- Keep all closed protocol gates in sync with the new command kind.
do $migration$
declare d text; before_text text; after_text text; signature text;
begin
 foreach signature in array array[
  'esheep_cloud.expected_payload_case_v2(text)',
  'esheep_cloud.dispatch_command_v2(text,jsonb,text,jsonb)',
  'esheep_cloud.client_projection_route_v2(text)'
 ] loop
  d:=pg_get_functiondef(signature::regprocedure);
  before_text:=case
   when signature like '%expected_payload_case%' then 'when ''care.sheepLabel.save'' then ''sheepLabels'''
   else 'when ''care.sheepLabel.save'' then ''care.sheepLabel.save'''
  end;
  after_text:=before_text||E'\n    '||case
   when signature like '%expected_payload_case%' then 'when ''care.sheepLabel.delete'' then ''sheepLabels'''
   else 'when ''care.sheepLabel.delete'' then ''care.sheepLabel.delete'''
  end;
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then raise exception 'label route definition changed: %',signature; end if;
  execute replace(d,before_text,after_text);
 end loop;
 foreach signature in array array[
  'esheep_cloud.primary_stream_v2(text,jsonb)',
  'esheep_cloud.validate_command_semantics_v2_legacy(text,jsonb,text,jsonb,jsonb,jsonb)'
 ] loop
  d:=pg_get_functiondef(signature::regprocedure);
  before_text:='when p_kind = ''care.sheepLabel.save'' then ''sheepLabel''';
  after_text:=before_text||E'\n    when p_kind = ''care.sheepLabel.delete'' then ''sheepLabel''';
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then raise exception 'label stream definition changed: %',signature; end if;
  execute replace(d,before_text,after_text);
 end loop;
end
$migration$;

create function esheep_cloud.project_sheep_label_delete_event()
returns trigger language plpgsql security invoker set search_path='' as $$
declare
 v_d jsonb;
 v_id uuid;
 v_label esheep_cloud.sheep_label_catalog%rowtype;
 v_expected integer;
begin
 if new.event_body->>'command_kind' <> 'care.sheepLabel.delete' then return new; end if;
 v_d:=new.event_body#>array['command_payload','body','sheepLabels','_0','deleteLabel','_0'];
 if jsonb_typeof(v_d) is distinct from 'object' then raise exception '标签删除命令内容无效。'; end if;
 v_id:=(v_d->>'id')::uuid;
 v_expected:=(v_d->>'expectedRevision')::integer;
 if new.stream_type<>'sheepLabel' or new.stream_id<>v_id then raise exception '标签删除对象不匹配。'; end if;
 select * into v_label from esheep_cloud.sheep_label_catalog
  where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_id;
 if not found then raise exception '标签不存在，可能已经被其他成员删除。'; end if;
 if v_label.revision is distinct from v_expected then raise exception '标签已由其他成员修改，请刷新后重试。'; end if;
 delete from esheep_cloud.sheep_label_catalog
  where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_id;
 update esheep_cloud.sheep_label_assignments a
  set label_ids=array_remove(a.label_ids,v_id),
      primary_label_id=esheep_cloud.sheep_label_primary(
       a.farm_id,a.farm_generation,array_remove(a.label_ids,v_id),a.primary_label_id),
      revision=a.revision+1
  where a.farm_id=new.farm_id and a.farm_generation=new.farm_generation and v_id=any(a.label_ids);
 return new;
end
$$;
revoke all on function esheep_cloud.project_sheep_label_delete_event() from public,anon,authenticated;
drop trigger if exists sheep_label_delete_on_accepted_event on esheep_cloud.events;
create trigger sheep_label_delete_on_accepted_event after insert on esheep_cloud.events for each row execute function esheep_cloud.project_sheep_label_delete_event();

insert into esheep_cloud.command_catalog(command_kind,merge_mode,allowed_roles,requires_online,current_schema_version)
values ('care.sheepLabel.delete','lifecycle',array['owner','administrator'],false,1)
on conflict (command_kind) do update set merge_mode=excluded.merge_mode,allowed_roles=excluded.allowed_roles,requires_online=excluded.requires_online,current_schema_version=excluded.current_schema_version;

