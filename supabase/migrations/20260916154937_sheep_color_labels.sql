-- Sheep labels are a farm-scoped projection of accepted Cloud V2 events.
-- No client can write these private tables. The existing farm lock serializes
-- catalogue changes, assignments and sex patches; a trigger failure rolls back
-- the command, event, receipt and projection in the same transaction.
create table esheep_cloud.sheep_label_catalog (
 farm_id uuid not null references public.farm_registry(farm_id),
 farm_generation integer not null,
 label_id uuid not null,
 name text not null check (char_length(btrim(name)) between 1 and 40),
 color text not null check (color in ('yellow','green','red','white','orange','light-blue','pink','black','purple','dark-blue')),
 note text not null default '' check (char_length(note)<=500),
 sort_order integer not null check(sort_order>=0),
 is_active boolean not null,
 revision integer not null check(revision>0),
 primary key(farm_id,farm_generation,label_id)
);
create unique index sheep_label_unique_name on esheep_cloud.sheep_label_catalog(farm_id,farm_generation,lower(btrim(name)));
create table esheep_cloud.sheep_label_assignments (
 farm_id uuid not null references public.farm_registry(farm_id), farm_generation integer not null,
 sheep_id uuid not null, label_ids uuid[] not null default '{}', primary_label_id uuid,
 revision integer not null default 0,
 primary key(farm_id,farm_generation,sheep_id),
 check(primary_label_id is null or primary_label_id=any(label_ids))
);
alter table esheep_cloud.sheep_label_catalog enable row level security;
alter table esheep_cloud.sheep_label_assignments enable row level security;
revoke all on esheep_cloud.sheep_label_catalog,esheep_cloud.sheep_label_assignments from public,anon,authenticated;

create function esheep_cloud.sheep_label_color_allows(p_color text,p_sex text)
returns boolean language sql immutable set search_path='' as $$
 select case when p_color='yellow' then p_sex='ram' when p_color='green' then p_sex='ewe'
 when p_color in ('red','white','orange','light-blue','pink','black','purple','dark-blue') then true else false end
$$;

-- Resolve sex from authoritative field patches, initial typed add events or
-- a migration's scalar stream. Missing sex is unknown, never guessed.
create function esheep_cloud.sheep_label_subject_sex(p_farm uuid,p_generation integer,p_sheep uuid)
returns text language plpgsql stable set search_path='' as $$
declare v_sex text; v_exists boolean;
begin
 -- A lamb created by a lambing command has a reproduction stream, not a sheep
 -- stream. Read its accepted birth command as well as scalar profile patches.
 select exists(select 1 from esheep_cloud.streams where farm_id=p_farm and farm_generation=p_generation and stream_id=p_sheep and stream_type='sheepProfile' and canonical_state#>>'{sex,value}' in ('ram','ewe','unknown')) into v_exists;
 select candidate.sex into v_sex from (
  select e.event_sequence, coalesce(
    (select c->'value'->>'value' from jsonb_array_elements(coalesce(e.event_body->'changes','[]')) c where c->>'field'='sex'),
    e.event_body#>>'{command_payload,body,add,sex}') sex
  from esheep_cloud.events e where e.farm_id=p_farm and e.farm_generation=p_generation and e.stream_id=p_sheep and e.stream_type in ('sheep','sheepProfile')
  union all
  select e.event_sequence, child->>'sex' from esheep_cloud.events e
  cross join lateral jsonb_array_elements(coalesce(e.event_body#>'{command_payload,body,recordLambing,_0,offspring}','[]'::jsonb)) child
  where e.farm_id=p_farm and e.farm_generation=p_generation and e.event_body->>'command_kind'='care.lambing.record'
   and child->>'createSheepRecord'='true' and (child->>'sheepID')::uuid=p_sheep
 ) candidate where candidate.sex in ('ram','ewe','unknown') order by candidate.event_sequence desc limit 1;
 if v_sex is null then
  select canonical_state#>>'{sex,value}' into v_sex from esheep_cloud.streams
  where farm_id=p_farm and farm_generation=p_generation and stream_id=p_sheep and stream_type='sheepProfile';
 end if;
 if not v_exists and v_sex is null then raise exception using errcode='23503',message='羊只不存在或不属于当前牧场。'; end if;
 return coalesce(v_sex,'unknown');
end
$$;

create function esheep_cloud.sheep_label_primary(p_farm uuid,p_generation integer,p_ids uuid[],p_preferred uuid)
returns uuid language sql stable set search_path='' as $$
 select label_id from esheep_cloud.sheep_label_catalog
 where farm_id=p_farm and farm_generation=p_generation and label_id=any(p_ids) and is_active
 order by (label_id=p_preferred) desc nulls last,sort_order,label_id limit 1
$$;

create function esheep_cloud.project_sheep_labels_event()
returns trigger language plpgsql security invoker set search_path='' as $$
declare
 v_kind text:=new.event_body->>'command_kind'; v_action text; v_d jsonb; v_id uuid;
 v_sheep uuid; v_sex text; v_label esheep_cloud.sheep_label_catalog%rowtype;
 v_a esheep_cloud.sheep_label_assignments%rowtype; v_add uuid[]; v_remove uuid[]; v_ids uuid[];
 v_primary uuid; v_conflicts integer; v_target uuid; v_changed_sex text;
begin
 if coalesce(v_kind,'') not in ('care.sheepLabel.save','care.sheepLabels.edit','care.sheepLabels.patchProfile')
    and not(new.stream_type='sheepProfile' and new.event_kind='fields_patched') then return new; end if;
 if v_kind in ('care.sheepLabel.save','care.sheepLabels.edit','care.sheepLabels.patchProfile') then
  v_action:=case v_kind when 'care.sheepLabel.save' then 'saveLabel' when 'care.sheepLabels.edit' then 'editLabels' else 'patchProfile' end;
  v_d:=new.event_body#>array['command_payload','body','sheepLabels','_0',v_action,'_0'];
  if jsonb_typeof(v_d) is distinct from 'object' then raise exception '标签命令内容无效。'; end if;
 end if;
 if v_kind='care.sheepLabel.save' then
  v_id:=(v_d->>'id')::uuid;
  if new.stream_type<>'sheepLabel' or new.stream_id<>v_id then raise exception '标签命令对象不匹配。'; end if;
  select * into v_label from esheep_cloud.sheep_label_catalog where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_id;
  if coalesce(v_label.revision,0) is distinct from (v_d->>'expectedRevision')::integer then raise exception '标签已由其他成员修改，请刷新后重试。'; end if;
  select count(*) into v_conflicts from esheep_cloud.sheep_label_assignments a
  where a.farm_id=new.farm_id and a.farm_generation=new.farm_generation and v_id=any(a.label_ids)
    and not esheep_cloud.sheep_label_color_allows(v_d->>'color',esheep_cloud.sheep_label_subject_sex(a.farm_id,a.farm_generation,a.sheep_id));
  if v_conflicts>0 then raise exception '该颜色与 % 只羊冲突，请先移除关联标签。',v_conflicts; end if;
  insert into esheep_cloud.sheep_label_catalog values(new.farm_id,new.farm_generation,v_id,btrim(v_d->>'name'),v_d->>'color',coalesce(v_d->>'note',''),(v_d->>'sortOrder')::integer,(v_d->>'isActive')::boolean,coalesce(v_label.revision,0)+1)
  on conflict(farm_id,farm_generation,label_id) do update set name=excluded.name,color=excluded.color,note=excluded.note,sort_order=excluded.sort_order,is_active=excluded.is_active,revision=excluded.revision;
  update esheep_cloud.sheep_label_assignments a set primary_label_id=esheep_cloud.sheep_label_primary(a.farm_id,a.farm_generation,a.label_ids,a.primary_label_id),revision=revision+1
   where a.farm_id=new.farm_id and a.farm_generation=new.farm_generation and v_id=any(a.label_ids)
    and a.primary_label_id is distinct from esheep_cloud.sheep_label_primary(a.farm_id,a.farm_generation,a.label_ids,a.primary_label_id);
  return new;
 end if;
 if new.stream_type='sheepProfile' and new.event_kind='fields_patched' then
  select c->'value'->>'value' into v_changed_sex from jsonb_array_elements(new.event_body->'changes') c where c->>'field'='sex';
  if v_changed_sex is null then return new; end if;
  if v_changed_sex not in ('ram','ewe','unknown') then raise exception '羊只性别无效。'; end if;
  v_sheep:=new.stream_id;
  select * into v_a from esheep_cloud.sheep_label_assignments where farm_id=new.farm_id and farm_generation=new.farm_generation and sheep_id=v_sheep;
  v_ids:=coalesce(v_a.label_ids,'{}');
  if v_kind='care.sheepLabels.patchProfile' then
   if (v_d->>'sheepID')::uuid<>v_sheep then raise exception '羊只标签对象不匹配。'; end if;
   select coalesce(array_agg(value::uuid),'{}') into v_remove from jsonb_array_elements_text(v_d->'removeLabelIDs');
   select coalesce(array_agg(id),'{}') into v_ids from unnest(v_ids) id where not(id=any(v_remove));
  end if;
  if exists(select 1 from esheep_cloud.sheep_label_catalog l where l.farm_id=new.farm_id and l.farm_generation=new.farm_generation and l.label_id=any(v_ids) and not esheep_cloud.sheep_label_color_allows(l.color,v_changed_sex)) then
   raise exception '必须明确移除所有与新性别冲突的标签。';
  end if;
  if v_kind='care.sheepLabels.patchProfile' then
   v_primary:=esheep_cloud.sheep_label_primary(new.farm_id,new.farm_generation,v_ids,v_a.primary_label_id);
   insert into esheep_cloud.sheep_label_assignments values(new.farm_id,new.farm_generation,v_sheep,v_ids,v_primary,coalesce(v_a.revision,0)+1)
   on conflict(farm_id,farm_generation,sheep_id) do update set label_ids=excluded.label_ids,primary_label_id=excluded.primary_label_id,revision=excluded.revision;
  end if;
  return new;
 end if;
 if v_kind<>'care.sheepLabels.edit' then raise exception '标签档案修改必须使用字段更新通道。'; end if;
 v_sheep:=(v_d->>'sheepID')::uuid;
 if new.stream_type<>'sheepLabels' or new.stream_id<>v_sheep then raise exception '羊只标签对象不匹配。'; end if;
 v_sex:=esheep_cloud.sheep_label_subject_sex(new.farm_id,new.farm_generation,v_sheep);
 select * into v_a from esheep_cloud.sheep_label_assignments where farm_id=new.farm_id and farm_generation=new.farm_generation and sheep_id=v_sheep;
 select coalesce(array_agg(value::uuid),'{}') into v_add from jsonb_array_elements_text(v_d->'addIDs');
 select coalesce(array_agg(value::uuid),'{}') into v_remove from jsonb_array_elements_text(v_d->'removeIDs');
 if v_add && v_remove then raise exception '同一标签不能同时添加和移除。'; end if;
 foreach v_target in array v_add loop
  select * into v_label from esheep_cloud.sheep_label_catalog where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_target;
  if not found or not v_label.is_active or not esheep_cloud.sheep_label_color_allows(v_label.color,v_sex) then raise exception '标签不存在、已停用或不适用于该羊的性别。'; end if;
 end loop;
 select coalesce(array_agg(distinct id order by id),'{}') into v_ids from unnest(coalesce(v_a.label_ids,'{}')||v_add) id where not(id=any(v_remove));
 v_primary:=v_a.primary_label_id;
 if coalesce((v_d->>'setsPrimary')::boolean,false) then
  if v_d->>'expectedRevision' is not null and coalesce(v_a.revision,0)<>(v_d->>'expectedRevision')::integer then raise exception '主标签已发生变化，请刷新后重试。'; end if;
  v_primary:=nullif(v_d->>'primaryLabelID','')::uuid;
  if v_primary is not null and not exists(select 1 from esheep_cloud.sheep_label_catalog l where l.farm_id=new.farm_id and l.farm_generation=new.farm_generation and l.label_id=v_primary and v_primary=any(v_ids) and l.is_active and esheep_cloud.sheep_label_color_allows(l.color,v_sex)) then raise exception '主标签必须是已关联且适用的启用标签。'; end if;
 end if;
 v_primary:=esheep_cloud.sheep_label_primary(new.farm_id,new.farm_generation,v_ids,v_primary);
 insert into esheep_cloud.sheep_label_assignments values(new.farm_id,new.farm_generation,v_sheep,v_ids,v_primary,coalesce(v_a.revision,0)+1)
 on conflict(farm_id,farm_generation,sheep_id) do update set label_ids=excluded.label_ids,primary_label_id=excluded.primary_label_id,revision=excluded.revision;
 return new;
end
$$;
create trigger sheep_labels_on_accepted_event after insert on esheep_cloud.events for each row execute function esheep_cloud.project_sheep_labels_event();
revoke all on function esheep_cloud.sheep_label_color_allows(text,text),esheep_cloud.sheep_label_subject_sex(uuid,integer,uuid),esheep_cloud.sheep_label_primary(uuid,integer,uuid[],uuid),esheep_cloud.project_sheep_labels_event() from public,anon,authenticated;

insert into esheep_cloud.command_catalog(command_kind,merge_mode,allowed_roles,requires_online,current_schema_version) values
 ('care.sheepLabel.save','state_machine',array['owner','administrator'],false,1),
 ('care.sheepLabels.edit','state_machine',array['owner','administrator','worker'],false,1),
 ('care.sheepLabels.patchProfile','field_patch',array['owner','administrator','worker'],false,1);

-- Extend the installed dispatcher without replacing existing hardening.
do $migration$
declare d text; before_text text; after_text text; signature text;
begin
 foreach signature in array array['esheep_cloud.expected_payload_case_v2(text)','esheep_cloud.dispatch_command_v2(text,jsonb,text,jsonb)','esheep_cloud.client_projection_route_v2(text)'] loop
  d:=pg_get_functiondef(signature::regprocedure);
  before_text:=case when signature like '%expected_payload_case%' then 'when ''sheep.add'' then ''add''' else 'when ''sheep.add'' then ''sheep.add''' end;
  after_text:=before_text||E'\n    '||case when signature like '%expected_payload_case%' then
   'when ''care.sheepLabel.save'' then ''sheepLabels''
    when ''care.sheepLabels.edit'' then ''sheepLabels''
    when ''care.sheepLabels.patchProfile'' then ''sheepLabels''' else
   'when ''care.sheepLabel.save'' then ''care.sheepLabel.save''
    when ''care.sheepLabels.edit'' then ''care.sheepLabels.edit''
    when ''care.sheepLabels.patchProfile'' then ''care.sheepLabels.patchProfile''' end;
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then raise exception 'label route definition changed: %',signature; end if;
  execute replace(d,before_text,after_text);
 end loop;
 foreach signature in array array['esheep_cloud.primary_stream_v2(text,jsonb)','esheep_cloud.validate_command_semantics_v2_legacy(text,jsonb,text,jsonb,jsonb,jsonb)'] loop
  d:=pg_get_functiondef(signature::regprocedure);before_text:='when p_kind = ''sheep.add'' then ''sheep''';
  after_text:=before_text||E'\n    when p_kind = ''care.sheepLabel.save'' then ''sheepLabel''\n    when p_kind = ''care.sheepLabels.edit'' then ''sheepLabels''\n    when p_kind = ''care.sheepLabels.patchProfile'' then ''sheepProfile''';
  if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then raise exception 'label semantics definition changed: %',signature; end if;
  execute replace(d,before_text,after_text);
 end loop;
end
$migration$;

create function esheep_cloud.validate_sheep_label_payload(p_kind text,p_payload jsonb,p_streams jsonb,p_changes jsonb)
returns void language plpgsql immutable set search_path='' as $$
declare a text; d jsonb; c jsonb; f text; expected jsonb; field_names text[]; id uuid;
begin
 if p_kind not in ('care.sheepLabel.save','care.sheepLabels.edit','care.sheepLabels.patchProfile') then return; end if;
 a:=case p_kind when 'care.sheepLabel.save' then 'saveLabel' when 'care.sheepLabels.edit' then 'editLabels' else 'patchProfile' end;
 d:=p_payload#>array['body','sheepLabels','_0',a,'_0'];
 if jsonb_typeof(d) is distinct from 'object' then raise exception '标签命令内容无效。'; end if;
 id:=(d->>'id')::uuid;
 if id is null then raise exception '标签命令缺少稳定标识。'; end if;
 if a='saveLabel' then
  if (d->>'changeID')::uuid is null or (d->>'expectedRevision') is null or (d->>'expectedRevision')::integer<0 or jsonb_typeof(d->'isActive') is distinct from 'boolean' then raise exception '标签设置无效。'; end if;
 elsif a='editLabels' then
  if (d->>'sheepID')::uuid is null or jsonb_typeof(d->'addIDs') is distinct from 'array' or jsonb_typeof(d->'removeIDs') is distinct from 'array' or jsonb_typeof(d->'setsPrimary') is distinct from 'boolean' then raise exception '标签关联修改无效。'; end if;
  for c in select value from jsonb_array_elements((d->'addIDs')||(d->'removeIDs')) loop if jsonb_typeof(c) is distinct from 'string' or (c#>>'{}')::uuid is null then raise exception '标签标识无效。'; end if; end loop;
  if coalesce((d->>'setsPrimary')::boolean,false) and (d->>'expectedRevision') is null then raise exception '设置主标签需要修订信息。'; end if;
 else
  if (d->>'sheepID')::uuid is null or jsonb_typeof(d->'removeLabelIDs') is distinct from 'array' or coalesce(d->>'sex','') not in ('ram','ewe','unknown') or nullif(btrim(d->>'earTag'),'') is null or nullif(btrim(d->>'breed'),'') is null then raise exception '档案与标签修改无效。'; end if;
  for c in select value from jsonb_array_elements(d->'removeLabelIDs') loop if jsonb_typeof(c) is distinct from 'string' or (c#>>'{}')::uuid is null then raise exception '标签标识无效。'; end if; end loop;
  if jsonb_array_length(p_streams)<>1 or p_streams->0->>'type'<>'sheepProfile' or (p_streams->0->>'id')::uuid<>(d->>'sheepID')::uuid then raise exception '档案修改对象不匹配。'; end if;
  select array_agg(value->>'field' order by value->>'field') into field_names from jsonb_array_elements(p_changes);
  if field_names is distinct from array['birthAt','breed','currentParity','earTag','note','parityRecordedAt','sex'] then raise exception '档案字段集合不匹配。'; end if;
  for c in select value from jsonb_array_elements(p_changes) loop
   f:=c->>'field';
   if f in ('birthAt','currentParity','parityRecordedAt') and (d->f is null or d->f='null'::jsonb) then expected:=jsonb_build_object('action','clear');
   else expected:=jsonb_build_object('action','set','value',jsonb_build_object('type',case when f in ('birthAt','parityRecordedAt') then 'date' when f='currentParity' then 'integer' else 'string' end,'value',d->f)); end if;
   if c->'mutation' is distinct from expected then raise exception '档案字段与签名内容不一致。'; end if;
  end loop;
 end if;
end
$$;
revoke all on function esheep_cloud.validate_sheep_label_payload(text,jsonb,jsonb,jsonb) from public,anon,authenticated;
do $migration$
declare d text; marker text:='  -- Reorder only the validation view; signed bytes remain untouched.';
begin
 d:=pg_get_functiondef('esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure);
 if position(marker in d)=0 then raise exception 'label validation wrapper changed'; end if;
 execute replace(d,marker,'  perform esheep_cloud.validate_sheep_label_payload(p_kind,v_payload,v_streams,v_field_changes);'||E'\n'||marker);
end
$migration$;

-- The field transaction has its own closed handler gate in addition to the
-- command dispatcher. Keep the same typed-payload check inside that gate.
do $migration$
declare d text; marker text:='    elsif v_kind = ''sheepAvatar.set'' then';
begin
 d:=pg_get_functiondef('esheep_cloud.process_command_v2(uuid,integer,uuid,jsonb)'::regprocedure);
 if position(marker in d)=0 then raise exception 'label profile field handler definition changed'; end if;
 execute replace(d,marker,'    elsif v_kind = ''care.sheepLabels.patchProfile'' then
      perform esheep_cloud.validate_sheep_label_payload(v_kind, v_unsigned_json -> ''payload'', v_affected_streams, v_field_changes);
'||marker);
end
$migration$;

-- Only lambing events need child-array lookup; scalar sex reads use the existing stream index.
create index sheep_labels_lambing_lookup_idx on esheep_cloud.events(farm_id,farm_generation,event_sequence desc) where event_body->>'command_kind'='care.lambing.record';
