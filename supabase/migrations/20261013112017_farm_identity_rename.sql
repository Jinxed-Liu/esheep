-- Farm identity is control-plane metadata, like membership. It has its own
-- audited, idempotent command and revision, outside the immutable business
-- event chain. Old clients can continue replaying every business event.
alter table esheep_cloud.farm_profiles add column name_revision bigint not null default 0 check (name_revision >= 0);

create table esheep_cloud.farm_name_commands (
  request_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null,
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  expected_revision bigint not null,
  previous_name text not null,
  requested_name text not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table esheep_cloud.farm_name_commands enable row level security;
revoke all on esheep_cloud.farm_name_commands from public, anon, authenticated;

create function esheep_cloud.farm_identity_json_v2(p_farm_id uuid, p_farm_generation integer)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('farmID',p.farm_id,'farmGeneration',p.farm_generation,
    'name',p.name,'revision',p.name_revision)
  from esheep_cloud.farm_profiles p
  where p.farm_id=p_farm_id and p.farm_generation=p_farm_generation;
$$;
revoke all on function esheep_cloud.farm_identity_json_v2(uuid,integer) from public,anon,authenticated;

create function public.esheep_cloud_farm_identity_v2(p_farm_id uuid, p_farm_generation integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_identity jsonb;
begin
  if auth.uid() is null or not esheep_private.is_active_farm_member(p_farm_id,array['owner','administrator','worker']) then
    raise exception using errcode='42501',message='esheep_cloud_farm_read_denied';
  end if;
  if not exists (select 1 from esheep_cloud.farm_state s join public.farm_registry r using(farm_id)
    where s.farm_id=p_farm_id and s.farm_generation=p_farm_generation
      and r.authority_generation=p_farm_generation and r.provider='esheep_cloud') then
    raise exception using errcode='55000',message='esheep_cloud_generation_mismatch';
  end if;
  v_identity := esheep_cloud.farm_identity_json_v2(p_farm_id,p_farm_generation);
  if v_identity is null then
    raise exception using errcode='55000',message='esheep_cloud_farm_profile_missing';
  end if;
  return v_identity;
end;
$$;
revoke all on function public.esheep_cloud_farm_identity_v2(uuid,integer) from public,anon;
grant execute on function public.esheep_cloud_farm_identity_v2(uuid,integer) to authenticated;

create function public.esheep_cloud_rename_farm_v2(p_farm_id uuid,p_farm_generation integer,
  p_name text,p_expected_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_name text := btrim(p_name);
  v_profile esheep_cloud.farm_profiles%rowtype;
  v_prior esheep_cloud.farm_name_commands%rowtype;
  v_result jsonb;
begin
  if v_user is null or not esheep_private.is_active_farm_member(p_farm_id,array['owner']) then
    raise exception using errcode='42501',message='esheep_cloud_owner_required';
  end if;
  if p_request_id is null or p_expected_revision is null or p_expected_revision < 0
    or v_name is null or char_length(v_name) not between 1 and 80 or v_name ~ '[[:cntrl:]]' then
    raise exception using errcode='22023',message='esheep_cloud_farm_name_invalid';
  end if;
  -- Lock the authority and production state before the identity row.
  perform 1 from public.farm_registry r where r.farm_id=p_farm_id
    and r.provider='esheep_cloud' and r.authority_generation=p_farm_generation
    and r.owner_user_id=v_user and r.status='active' for update;
  if not found then
    raise exception using errcode='55000',message='esheep_cloud_generation_mismatch';
  end if;
  perform 1 from esheep_cloud.farm_state s where s.farm_id=p_farm_id
    and s.farm_generation=p_farm_generation and s.status='active' and s.v2_ready and not s.write_frozen for update;
  if not found then
    raise exception using errcode='55000',message='esheep_cloud_farm_not_writable';
  end if;
  select * into v_prior from esheep_cloud.farm_name_commands c where c.request_id=p_request_id;
  if found then
    if v_prior.farm_id<>p_farm_id or v_prior.farm_generation<>p_farm_generation
      or v_prior.actor_user_id<>v_user or v_prior.requested_name<>v_name
      or v_prior.expected_revision<>p_expected_revision then
      raise exception using errcode='22023',message='esheep_cloud_request_reused';
    end if;
    return v_prior.result;
  end if;
  select * into v_profile from esheep_cloud.farm_profiles p
    where p.farm_id=p_farm_id and p.farm_generation=p_farm_generation for update;
  if not found then
    raise exception using errcode='55000',message='esheep_cloud_farm_profile_missing';
  end if;
  if v_profile.name_revision<>p_expected_revision then
    raise exception using errcode='40001',message='esheep_cloud_farm_name_conflict';
  end if;
  if v_profile.name<>v_name then
    update esheep_cloud.farm_profiles set name=v_name,name_revision=name_revision+1,updated_at=now()
      where farm_id=p_farm_id and farm_generation=p_farm_generation;
  end if;
  v_result := esheep_cloud.farm_identity_json_v2(p_farm_id,p_farm_generation);
  insert into esheep_cloud.farm_name_commands(request_id,farm_id,farm_generation,actor_user_id,
    expected_revision,previous_name,requested_name,result)
    values(p_request_id,p_farm_id,p_farm_generation,v_user,p_expected_revision,v_profile.name,v_name,v_result);
  return v_result;
end;
$$;
revoke all on function public.esheep_cloud_rename_farm_v2(uuid,integer,text,bigint,uuid) from public,anon;
grant execute on function public.esheep_cloud_rename_farm_v2(uuid,integer,text,bigint,uuid) to authenticated;

-- Add optional identity to existing authenticated reads. Do not rewrite old
-- snapshots, chunk digests, business streams, event receipts or checkpoints.
do $$
declare d text; marker text := 'return jsonb_build_object(';
begin
  d:=pg_get_functiondef('public.esheep_cloud_pull_events_v2(uuid,integer,bigint,integer)'::regprocedure);
  if (length(d)-length(replace(d,marker,'')))/length(marker)<>1 then raise exception 'pull identity patch anchor changed'; end if;
  execute replace(d,marker,'return jsonb_build_object(''farm_identity'',esheep_cloud.farm_identity_json_v2(p_farm_id,p_farm_generation)) || jsonb_build_object(');
  d:=pg_get_functiondef('public.esheep_cloud_list_my_farms_v2()'::regprocedure);
  if strpos(d,'''farm_generation'', registry.authority_generation,')=0 then raise exception 'discovery identity patch anchor changed'; end if;
  execute replace(d,'''farm_generation'', registry.authority_generation,',
    '''farm_generation'', registry.authority_generation, ''farm_identity'', esheep_cloud.farm_identity_json_v2(registry.farm_id,registry.authority_generation),');
  d:=pg_get_functiondef('public.esheep_cloud_fetch_status_v2(uuid)'::regprocedure);
  if (length(d)-length(replace(d,marker,'')))/length(marker)<>1 then raise exception 'status identity patch anchor changed'; end if;
  execute replace(d,marker,'return jsonb_build_object(''farm_identity'',esheep_cloud.farm_identity_json_v2(p_farm_id,v_state.farm_generation)) || jsonb_build_object(');
end;
$$;

-- The public DDL guard revokes client grants on CREATE OR REPLACE as well.
-- Keep these explicit grants AFTER every public read-function definition.
grant execute on function public.esheep_cloud_list_my_farms_v2() to authenticated;
grant execute on function public.esheep_cloud_fetch_status_v2(uuid) to authenticated;
grant execute on function public.esheep_cloud_pull_events_v2(uuid,integer,bigint,integer) to authenticated;
