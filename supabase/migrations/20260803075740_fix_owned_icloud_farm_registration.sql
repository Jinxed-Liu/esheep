-- The first deployed definition used ON CONFLICT (farm_id), which clashes
-- with the TABLE return column of the same name in PL/pgSQL. Target the
-- primary-key constraint explicitly while preserving the API and checks.
create or replace function public.register_owned_icloud_farm(
  p_farm_id uuid,
  p_owner_app_account_id uuid,
  p_device_id uuid,
  p_zone_name text,
  p_zone_owner_name text
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
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
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

  insert into public.farm_registry (
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
    0,
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
  uuid, uuid, uuid, text, text
) from public, anon;
grant execute on function public.register_owned_icloud_farm(
  uuid, uuid, uuid, text, text
) to authenticated;
