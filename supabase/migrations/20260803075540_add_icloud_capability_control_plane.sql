-- Supabase-authenticated control plane for CloudKit capability certificates.
-- The certificate table is deliberately not exposed to authenticated clients;
-- issuance happens in an authenticated Edge Function after RLS-bound checks.
create table public.icloud_capability_certificates (
  certificate_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  app_account_id uuid not null,
  device_id uuid not null references public.devices(device_id) on delete cascade,
  role text not null check (role in ('owner', 'administrator', 'worker')),
  capabilities jsonb not null check (jsonb_typeof(capabilities) = 'array'),
  certificate_jws text not null,
  certificate_digest text not null check (certificate_digest ~ '^[0-9a-f]{64}$'),
  key_id text not null,
  issued_at timestamptz not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > issued_at)
);

create unique index icloud_capability_one_active_per_device
  on public.icloud_capability_certificates (farm_id, user_id, device_id)
  where revoked_at is null;

create index icloud_capability_farm_revocation_lookup
  on public.icloud_capability_certificates (farm_id, revoked_at, expires_at);

alter table public.icloud_capability_certificates enable row level security;
revoke all on table public.icloud_capability_certificates
  from public, anon, authenticated;
grant select, insert, update on table public.icloud_capability_certificates
  to service_role;

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
  on conflict (farm_id) do update
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
  on conflict (farm_id, user_id) do update
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

-- Preserve the established revoke API while ensuring CloudKit capabilities
-- become unusable as soon as membership is revoked.
create or replace function public.revoke_farm_member(
  p_farm_id uuid,
  p_member_user_id uuid
)
returns table (
  farm_id uuid,
  member_user_id uuid,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator']
  ) then
    raise exception using errcode = '42501', message = 'farm_member_revoke_denied';
  end if;
  if exists (
    select 1
    from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = p_member_user_id
      and member.role = 'owner'
  ) then
    raise exception using errcode = '42501', message = 'farm_owner_cannot_be_revoked';
  end if;

  update public.farm_members
  set status = 'revoked', updated_at = now()
  where farm_members.farm_id = p_farm_id
    and farm_members.user_id = p_member_user_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'farm_member_missing';
  end if;

  update public.icloud_capability_certificates certificate
  set revoked_at = coalesce(certificate.revoked_at, now())
  where certificate.farm_id = p_farm_id
    and certificate.user_id = p_member_user_id
    and certificate.revoked_at is null;

  return query select p_farm_id, p_member_user_id, 'revoked'::text;
end;
$$;

revoke all on function public.revoke_farm_member(uuid, uuid)
  from public, anon;
grant execute on function public.revoke_farm_member(uuid, uuid)
  to authenticated;

comment on table public.icloud_capability_certificates is
  'Server-only audit and revocation store for Supabase-issued CloudKit capability certificates.';
comment on function public.register_owned_icloud_farm(uuid, uuid, uuid, text, text) is
  'Registers only CloudKit control-plane metadata for a Supabase-authenticated owner; no farm business content is stored.';
