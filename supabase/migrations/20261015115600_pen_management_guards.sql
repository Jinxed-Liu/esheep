-- Private constraints projected from accepted events. Existing facts, streams,
-- event bytes and duplicate legacy names are never rewritten. The command
-- transaction already holds the farm_state lock, serializing name claims and
-- new references with lifecycle changes across devices.
create function esheep_cloud.pen_name_key(p_name text)
returns text language sql immutable set search_path='' as $$
 select lower(btrim(p_name, E' \t\n\r\f' || chr(11) || chr(133) || chr(160) || chr(5760) ||
   chr(8192)||chr(8193)||chr(8194)||chr(8195)||chr(8196)||chr(8197)||chr(8198)||
   chr(8199)||chr(8200)||chr(8201)||chr(8202)||chr(8232)||chr(8233)||chr(8239)||chr(8287)||chr(12288)))
$$;

create table esheep_cloud.pen_management_catalog (
 farm_id uuid not null references public.farm_registry(farm_id),
 farm_generation integer not null,
 pen_id uuid not null,
 name_key text,
 is_deleted boolean not null default false,
 primary key(farm_id,farm_generation,pen_id)
);
-- Deliberately nonunique: old duplicate names remain intact until explicitly
-- corrected. The trigger rejects only new claims, renames and restoration.
create index pen_management_name_lookup on esheep_cloud.pen_management_catalog(farm_id,farm_generation,name_key) where not is_deleted;
create table esheep_cloud.pen_historical_references (
 farm_id uuid not null references public.farm_registry(farm_id),
 farm_generation integer not null,
 pen_id uuid not null,
 primary key(farm_id,farm_generation,pen_id)
);
alter table esheep_cloud.pen_management_catalog enable row level security;
alter table esheep_cloud.pen_historical_references enable row level security;
revoke all on esheep_cloud.pen_management_catalog,esheep_cloud.pen_historical_references from public,anon,authenticated;

-- UUIDs are matched only under explicit pen reference keys, never free text.
-- The same suffix rule is used by PenManagementPolicy for immutable local
-- commands. Descending through arrays covers TMR plans, allocations and repair
-- payloads; revoked references remain reserved for historical restoration.
create function esheep_cloud.pen_reference_ids(p_value jsonb)
returns setof uuid language plpgsql immutable set search_path='' as $$
declare k text; v jsonb; t text;
begin
 if jsonb_typeof(p_value)='object' then
  -- Conflict decisions and field patches carry the key separately from value.
  if lower(p_value->>'field') ~ 'penids?$' then
   return query select * from esheep_cloud.pen_reference_ids(jsonb_build_object(
    'penID',coalesce(p_value->'chosen_value',p_value->'value',p_value#>'{mutation,value}')));
  end if;
  for k,v in select * from jsonb_each(p_value) loop
   if lower(k) ~ 'penids?$' then
    for t in select q.value#>>'{}' from jsonb_path_query(v,'strict $.** ? (@.type() == "string")') q(value) loop
     if t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return next t::uuid; end if;
    end loop;
   end if;
   return query select * from esheep_cloud.pen_reference_ids(v);
  end loop;
 elsif jsonb_typeof(p_value)='array' then
  for v in select * from jsonb_array_elements(p_value) loop
   return query select * from esheep_cloud.pen_reference_ids(v);
  end loop;
 end if;
 return;
end
$$;

create function esheep_cloud.guard_pen_management_event()
returns trigger language plpgsql security invoker set search_path='' as $$
declare
 k text:=new.event_body->>'command_kind';
 old_pen esheep_cloud.pen_management_catalog%rowtype;
 next_key text; name_changed boolean:=false; restoring boolean:=false; ref_id uuid;
begin
 if new.stream_type='pen' and new.event_kind='attention_resolved'
    and new.event_body->>'field'='name' and new.before_digest<>new.after_digest then
  next_key:=esheep_cloud.pen_name_key(new.event_body#>>'{chosen_value,value}');
  if next_key is null or next_key='' then raise exception using errcode='22023',message='请填写羊舍名称。'; end if;
  if next_key is distinct from (select name_key from esheep_cloud.pen_management_catalog
    where farm_id=new.farm_id and farm_generation=new.farm_generation and pen_id=new.stream_id)
   and exists(select 1 from esheep_cloud.pen_management_catalog p where p.farm_id=new.farm_id and p.farm_generation=new.farm_generation
   and p.pen_id<>new.stream_id and not p.is_deleted and p.name_key=next_key) then
   raise exception using errcode='23505',message='当前牧场已有同名羊舍，请选择其他名称。';
  end if;
  update esheep_cloud.pen_management_catalog set name_key=next_key
   where farm_id=new.farm_id and farm_generation=new.farm_generation and pen_id=new.stream_id and not is_deleted;
  if not found then raise exception using errcode='23503',message='羊舍不存在或已删除。'; end if;
  return new;
 end if;
 if k is null and new.event_kind<>'attention_resolved' then return new; end if;
 if new.stream_type='pen' and (k like 'pen.%' or k in ('record.revoke','record.restore')) then
  select * into old_pen from esheep_cloud.pen_management_catalog
   where farm_id=new.farm_id and farm_generation=new.farm_generation and pen_id=new.stream_id;
  if k='pen.create' then
   if found then raise exception using errcode='23505',message='羊舍已存在，请刷新后重试。'; end if;
   next_key:=esheep_cloud.pen_name_key(new.event_body#>>'{command_payload,body,create,name}');
   name_changed:=true;
  else
   if not found then raise exception using errcode='23503',message='羊舍不存在或尚未同步完整，请刷新后重试。'; end if;
   if old_pen.is_deleted and k<>'record.restore' then raise exception using errcode='23503',message='羊舍已删除，不能再修改或使用。'; end if;
   next_key:=old_pen.name_key;
   if k='pen.update' then
    select esheep_cloud.pen_name_key(c#>>'{value,value}') into next_key
     from jsonb_array_elements(coalesce(new.event_body->'changes','[]')) c where c->>'field'='name';
    if found then name_changed:=next_key is distinct from old_pen.name_key;
    else next_key:=old_pen.name_key; end if;
   elsif k='record.restore' then
    restoring:=true;
   elsif k='record.revoke' then
    if exists(select 1 from esheep_cloud.pen_historical_references
     where farm_id=new.farm_id and farm_generation=new.farm_generation and pen_id=new.stream_id) then
     raise exception using errcode='23503',message='羊舍仍被业务或历史记录引用，不能删除；清空后可以停用。';
    end if;
   end if;
  end if;
  if name_changed or restoring then
   if next_key is null or next_key='' then raise exception using errcode='22023',message='请填写羊舍名称。'; end if;
   if exists(select 1 from esheep_cloud.pen_management_catalog p where p.farm_id=new.farm_id and p.farm_generation=new.farm_generation
    and p.pen_id<>new.stream_id and not p.is_deleted and p.name_key=next_key) then
    raise exception using errcode='23505',message='当前牧场已有同名羊舍（包括已停用羊舍），请使用其他名称。';
   end if;
  end if;
  insert into esheep_cloud.pen_management_catalog values(new.farm_id,new.farm_generation,new.stream_id,next_key,k='record.revoke')
   on conflict(farm_id,farm_generation,pen_id) do update set name_key=excluded.name_key,is_deleted=excluded.is_deleted;
  return new;
 end if;
 -- Do not index a pen's own management commands as business references.
 if k like 'pen.%' then return new; end if;
 for ref_id in select distinct * from esheep_cloud.pen_reference_ids(new.event_body) loop
  if exists(select 1 from esheep_cloud.pen_management_catalog p where p.farm_id=new.farm_id and p.farm_generation=new.farm_generation and p.pen_id=ref_id and p.is_deleted) then
   raise exception using errcode='23503',message='关联羊舍已删除，请刷新并重新选择羊舍。';
  end if;
  insert into esheep_cloud.pen_historical_references values(new.farm_id,new.farm_generation,ref_id) on conflict do nothing;
 end loop;
 return new;
end
$$;
create trigger pen_management_on_accepted_event after insert on esheep_cloud.events
 for each row execute function esheep_cloud.guard_pen_management_event();
-- Install the trigger before backfill: its table lock closes the gap where a
-- concurrent accepted event could otherwise escape the initial scan.
-- Reconstruct only constraint metadata. Latest applied field values win over
-- create payloads; lifecycle changes do not erase the prior name.
insert into esheep_cloud.pen_management_catalog(farm_id,farm_generation,pen_id,name_key,is_deleted)
select s.farm_id,s.farm_generation,s.stream_id,
 esheep_cloud.pen_name_key(coalesce(
  (select c#>>'{value,value}' from esheep_cloud.events e cross join lateral jsonb_array_elements(
    case when e.event_kind='attention_resolved' and e.before_digest<>e.after_digest
     then jsonb_build_array(jsonb_build_object('field',e.event_body->'field','value',e.event_body->'chosen_value'))
     else coalesce(e.event_body->'changes','[]') end) c
   where e.farm_id=s.farm_id and e.farm_generation=s.farm_generation and e.stream_type='pen' and e.stream_id=s.stream_id and c->>'field'='name'
   order by e.event_sequence desc limit 1),
  s.canonical_state#>>'{name,value}',
  (select e.event_body#>>'{command_payload,body,create,name}' from esheep_cloud.events e
   where e.farm_id=s.farm_id and e.farm_generation=s.farm_generation and e.stream_type='pen' and e.stream_id=s.stream_id and e.event_body->>'command_kind'='pen.create'
   order by e.event_sequence desc limit 1))),
 coalesce((select e.event_body->>'command_kind'='record.revoke' from esheep_cloud.events e
   where e.farm_id=s.farm_id and e.farm_generation=s.farm_generation and e.stream_type='pen' and e.stream_id=s.stream_id
    and e.event_body->>'command_kind' in ('record.revoke','record.restore') order by e.event_sequence desc limit 1),false)
from esheep_cloud.streams s where s.stream_type='pen' on conflict do nothing;

insert into esheep_cloud.pen_historical_references
select distinct e.farm_id,e.farm_generation,r.pen_id from esheep_cloud.events e
cross join lateral esheep_cloud.pen_reference_ids(e.event_body) r(pen_id)
where coalesce(e.event_body->>'command_kind','') not like 'pen.%'
on conflict do nothing;

revoke all on function esheep_cloud.pen_name_key(text),esheep_cloud.pen_reference_ids(jsonb),esheep_cloud.guard_pen_management_event() from public,anon,authenticated;

-- Keep the server's established role contract. The client applies exactly the
-- same owner/administrator lifecycle restriction, even with local overrides.
update esheep_cloud.command_catalog set allowed_roles=array['owner','administrator','worker'] where command_kind in ('pen.create','pen.update');
update esheep_cloud.command_catalog set allowed_roles=array['owner','administrator'] where command_kind='pen.setActive';
