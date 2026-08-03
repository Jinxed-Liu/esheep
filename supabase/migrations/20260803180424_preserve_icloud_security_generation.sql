-- A legacy CloudKit farm can already have a signed membership generation
-- before it is registered in the Supabase control plane. Preserve that
-- monotonic history so a newly published trust snapshot wins deterministically
-- during clean-device rebuilds.
create or replace function public.register_owned_icloud_farm(
  p_farm_id uuid,
  p_owner_app_account_id uuid,
  p_device_id uuid,
  p_zone_name text,
  p_zone_owner_name text,
  p_observed_security_generation integer
)
returns table (
  farm_id uuid,
  authority_generation integer,
  current_revision bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_profile_account_id uuid;
  v_existing public.farm_registry%rowtype;
  v_initial_generation integer;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_observed_security_generation is null
     or p_observed_security_generation < 0
     or p_observed_security_generation > 1000000 then
    raise exception using errcode = '22023', message = 'invalid_security_generation';
  end if;

  select profile.app_account_id
    into v_profile_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  if v_profile_account_id is null
     or v_profile_account_id <> p_owner_app_account_id then
    raise exception using errcode = '42501', message = 'owner_account_mismatch';
  end if;

  if not exists (
    select 1
    from public.devices device
    where device.device_id = p_device_id
      and device.user_id = v_user_id
      and device.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'active_device_required';
  end if;

  if p_zone_name <> 'Farm_' || lower(p_farm_id::text)
     or length(p_zone_name) > 64 then
    raise exception using errcode = '22023', message = 'invalid_cloudkit_zone_name';
  end if;

  if p_zone_owner_name is null
     or length(btrim(p_zone_owner_name)) = 0
     or length(p_zone_owner_name) > 512
     or p_zone_owner_name ~ '[[:cntrl:]]' then
    raise exception using errcode = '22023', message = 'invalid_cloudkit_zone_owner';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  select registry.*
    into v_existing
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if found and (
    v_existing.owner_user_id <> v_user_id
    or v_existing.provider <> 'icloud'
  ) then
    raise exception using errcode = '42501', message = 'farm_authority_collision';
  end if;

  v_initial_generation := case
    when p_observed_security_generation > 0
      then p_observed_security_generation + 1
    else 0
  end;

  insert into public.farm_registry as target (
    farm_id,
    owner_user_id,
    provider,
    status,
    authority_generation,
    current_revision,
    cloud_locator,
    created_at,
    updated_at
  )
  values (
    p_farm_id,
    v_user_id,
    'icloud',
    'active',
    v_initial_generation,
    0,
    jsonb_build_object(
      'zone_name', p_zone_name,
      'zone_owner_name', p_zone_owner_name
    ),
    now(),
    now()
  )
  on conflict on constraint farm_registry_pkey do update
  set status = 'active',
      authority_generation = case
        when target.authority_generation < p_observed_security_generation
          then p_observed_security_generation + 1
        else target.authority_generation
      end,
      cloud_locator = excluded.cloud_locator,
      updated_at = now();

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by,
    created_at,
    updated_at
  )
  values (
    p_farm_id,
    v_user_id,
    v_profile_account_id,
    'owner',
    'active',
    v_user_id,
    now(),
    now()
  )
  on conflict on constraint farm_members_pkey do update
  set app_account_id = excluded.app_account_id,
      role = 'owner',
      status = 'active',
      updated_at = now();

  return query
  select registry.farm_id,
         registry.authority_generation,
         registry.current_revision
  from public.farm_registry registry
  where registry.farm_id = p_farm_id;
end;
$$;

revoke all on function public.register_owned_icloud_farm(
  uuid, uuid, uuid, text, text, integer
) from public, anon;
grant execute on function public.register_owned_icloud_farm(
  uuid, uuid, uuid, text, text, integer
) to authenticated;

comment on function public.register_owned_icloud_farm(
  uuid, uuid, uuid, text, text, integer
) is
  'Registers an owned iCloud farm and preserves a monotonic legacy CloudKit security generation.';
