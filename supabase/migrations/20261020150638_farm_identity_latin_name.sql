-- Optional global display identity. Business events and checkpoints remain unchanged.
alter table esheep_cloud.farm_profiles add column latin_name text
  check (latin_name is null or (char_length(latin_name) between 1 and 80 and latin_name !~ '[[:cntrl:]]'));
alter table esheep_cloud.farm_name_commands
  add column previous_latin_name text,
  add column requested_latin_name text,
  add column updates_latin_name boolean not null default false;

create or replace function esheep_cloud.farm_identity_json_v2(p_farm_id uuid, p_farm_generation integer)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('farmID',p.farm_id,'farmGeneration',p.farm_generation,
    'name',p.name,'latinName',p.latin_name,'revision',p.name_revision)
  from esheep_cloud.farm_profiles p
  where p.farm_id=p_farm_id and p.farm_generation=p_farm_generation;
$$;
revoke all on function esheep_cloud.farm_identity_json_v2(uuid,integer) from public,anon,authenticated;

create function public.esheep_cloud_update_farm_identity_v2(p_farm_id uuid,p_farm_generation integer,
  p_name text,p_latin_name text,p_expected_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_name text := btrim(p_name);
  v_latin_name text := nullif(btrim(p_latin_name),'');
  v_profile esheep_cloud.farm_profiles%rowtype;
  v_prior esheep_cloud.farm_name_commands%rowtype;
  v_result jsonb;
begin
  if v_user is null or not esheep_private.is_active_farm_member(p_farm_id,array['owner']) then
    raise exception using errcode='42501',message='esheep_cloud_owner_required';
  end if;
  if p_request_id is null or p_expected_revision is null or p_expected_revision < 0
    or (v_latin_name is not null and (char_length(v_latin_name)>80 or v_latin_name ~ '[[:cntrl:]]'))
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
    if not v_prior.updates_latin_name or v_prior.requested_latin_name is distinct from v_latin_name
      or v_prior.farm_id<>p_farm_id or v_prior.farm_generation<>p_farm_generation
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
  if v_profile.name<>v_name or v_profile.latin_name is distinct from v_latin_name then
    update esheep_cloud.farm_profiles set name=v_name,latin_name=v_latin_name,name_revision=name_revision+1,updated_at=now()
      where farm_id=p_farm_id and farm_generation=p_farm_generation;
  end if;
  v_result := esheep_cloud.farm_identity_json_v2(p_farm_id,p_farm_generation);
  insert into esheep_cloud.farm_name_commands(request_id,farm_id,farm_generation,actor_user_id,
    expected_revision,previous_name,requested_name,result,previous_latin_name,requested_latin_name,updates_latin_name)
    values(p_request_id,p_farm_id,p_farm_generation,v_user,p_expected_revision,v_profile.name,v_name,v_result,v_profile.latin_name,v_latin_name,true);
  return v_result;
end;
$$;
revoke all on function public.esheep_cloud_update_farm_identity_v2(uuid,integer,text,text,bigint,uuid) from public,anon;
grant execute on function public.esheep_cloud_update_farm_identity_v2(uuid,integer,text,text,bigint,uuid) to authenticated;


-- Older clients rename only the Chinese name and preserve the optional Latin name.
create or replace function public.esheep_cloud_rename_farm_v2(p_farm_id uuid,p_farm_generation integer,
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
    if v_prior.updates_latin_name or v_prior.farm_id<>p_farm_id or v_prior.farm_generation<>p_farm_generation
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
