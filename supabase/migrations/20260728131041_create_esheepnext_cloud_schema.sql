create extension if not exists pgcrypto with schema extensions;

create schema if not exists esheep_private;
revoke all on schema esheep_private from public, anon, authenticated;
grant usage on schema esheep_private to authenticated;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  app_account_id uuid not null unique,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.devices (
  device_id uuid primary key,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  public_key_jwk jsonb not null,
  display_name text not null default '',
  status text not null default 'active' check (status in ('active', 'revoked')),
  registered_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table public.farm_registry (
  farm_id uuid primary key,
  owner_user_id uuid not null references public.profiles(user_id),
  provider text not null check (provider in ('icloud', 'supabase')),
  status text not null default 'active'
    check (status in ('preparing', 'active', 'read_only', 'archived', 'failed')),
  authority_generation integer not null default 0 check (authority_generation >= 0),
  current_revision bigint not null default 0 check (current_revision >= 0),
  cloud_locator jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.farm_members (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  app_account_id uuid not null,
  role text not null check (role in ('owner', 'administrator', 'worker')),
  status text not null default 'active'
    check (status in ('pending', 'active', 'revoked')),
  invited_by uuid references public.profiles(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (farm_id, user_id)
);

create table public.farm_invites (
  invite_id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  invited_by uuid not null references public.profiles(user_id),
  role text not null check (role in ('administrator', 'worker')),
  code_digest bytea not null unique,
  invitee_email_digest bytea,
  status text not null default 'pending'
    check (status in ('pending', 'redeemed', 'revoked', 'expired')),
  expires_at timestamptz not null,
  redeemed_by uuid references public.profiles(user_id),
  created_at timestamptz not null default now(),
  redeemed_at timestamptz
);

create table public.farm_operations (
  operation_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  authority_generation integer not null check (authority_generation >= 0),
  client_sequence bigint not null default 0 check (client_sequence >= 0),
  is_staged boolean not null default false,
  revision bigint not null check (revision > 0),
  base_revision integer not null check (base_revision >= 0),
  resulting_revision integer not null check (resulting_revision > base_revision),
  schema_version integer not null check (schema_version > 0),
  entity_type text not null,
  entity_id uuid not null,
  actor_user_id uuid not null references public.profiles(user_id),
  modified_by_account_id uuid not null,
  modified_by_device_id uuid not null references public.devices(device_id),
  payload_base64 text not null,
  payload_digest text not null check (payload_digest ~ '^[0-9a-f]{64}$'),
  capability_certificate text not null,
  operation_signature text,
  deleted_at timestamptz,
  occurred_at timestamptz not null,
  modified_at timestamptz not null,
  server_received_at timestamptz not null default now(),
  unique (farm_id, revision)
);

create table public.farm_entities (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  authority_generation integer not null check (authority_generation >= 0),
  revision integer not null check (revision > 0),
  operation_id uuid not null references public.farm_operations(operation_id),
  payload_base64 text not null,
  payload_digest text not null check (payload_digest ~ '^[0-9a-f]{64}$'),
  modified_by uuid not null references public.profiles(user_id),
  modified_at timestamptz not null,
  deleted_at timestamptz,
  primary key (farm_id, entity_type, entity_id)
);

create table public.farm_tombstones (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  authority_generation integer not null check (authority_generation >= 0),
  revision integer not null check (revision > 0),
  operation_id uuid not null references public.farm_operations(operation_id),
  deleted_by uuid not null references public.profiles(user_id),
  deleted_at timestamptz not null,
  reason text not null default '',
  primary key (farm_id, entity_type, entity_id)
);

create table public.farm_assets (
  asset_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path text not null unique,
  byte_count bigint not null check (byte_count >= 0),
  content_type text not null,
  authority_generation integer not null check (authority_generation >= 0),
  uploaded_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (farm_id, sha256)
);

create table public.farm_checkpoints (
  checkpoint_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  authority_generation integer not null check (authority_generation >= 0),
  through_revision bigint not null check (through_revision >= 0),
  manifest jsonb not null,
  manifest_digest text not null check (manifest_digest ~ '^[0-9a-f]{64}$'),
  storage_path text not null,
  operation_count bigint not null default 0 check (operation_count >= 0),
  entity_count bigint not null default 0 check (entity_count >= 0),
  tombstone_count bigint not null default 0 check (tombstone_count >= 0),
  asset_count bigint not null default 0 check (asset_count >= 0),
  created_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  verified_at timestamptz
);

create table public.authority_transitions (
  migration_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  source_provider text check (source_provider in ('local_only', 'icloud', 'supabase')),
  target_provider text not null check (target_provider in ('local_only', 'icloud', 'supabase')),
  source_generation integer not null check (source_generation >= 0),
  target_generation integer not null check (target_generation > source_generation),
  baseline_revision bigint not null default 0 check (baseline_revision >= 0),
  state text not null check (
    state in (
      'preparing',
      'uploading_baseline',
      'verifying',
      'committing',
      'draining',
      'archiving_source',
      'completed',
      'failed'
    )
  ),
  initiated_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  committed_at timestamptz
);

create table public.entitlements (
  owner_user_id uuid primary key references public.profiles(user_id) on delete cascade,
  product_id text,
  original_transaction_id text unique,
  state text not null default 'inactive'
    check (state in ('inactive', 'active', 'grace_period', 'billing_retry', 'expired', 'revoked')),
  valid_until timestamptz,
  grace_until timestamptz,
  read_only_until timestamptz,
  last_notification_id text unique,
  updated_at timestamptz not null default now()
);

create table public.account_deletion_requests (
  deletion_job_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'completed', 'failed')),
  requested_at timestamptz not null default now(),
  completed_at timestamptz
);

create table esheep_private.legacy_account_claim_tickets (
  ticket_digest bytea primary key,
  app_account_id uuid not null unique,
  provider text not null check (provider in ('apple', 'email')),
  provider_identity_digest bytea not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index farm_members_user_active_idx
  on public.farm_members (user_id, farm_id)
  where status = 'active';
create index farm_operations_cursor_idx
  on public.farm_operations (farm_id, authority_generation, revision);
create unique index farm_operations_client_sequence_idx
  on public.farm_operations (farm_id, authority_generation, client_sequence)
  where client_sequence > 0;
create index farm_entities_revision_idx
  on public.farm_entities (farm_id, authority_generation, revision);
create index farm_assets_farm_idx
  on public.farm_assets (farm_id, created_at);
create index farm_invites_farm_status_idx
  on public.farm_invites (farm_id, status, expires_at);
create index devices_user_status_idx
  on public.devices (user_id, status);
create index farm_registry_owner_status_idx
  on public.farm_registry (owner_user_id, status);
create index farm_members_invited_by_idx
  on public.farm_members (invited_by)
  where invited_by is not null;
create index farm_invites_invited_by_idx
  on public.farm_invites (invited_by);
create index farm_invites_redeemed_by_idx
  on public.farm_invites (redeemed_by)
  where redeemed_by is not null;
create index farm_operations_actor_user_idx
  on public.farm_operations (actor_user_id);
create index farm_operations_device_idx
  on public.farm_operations (modified_by_device_id);
create index farm_entities_operation_idx
  on public.farm_entities (operation_id);
create index farm_entities_modified_by_idx
  on public.farm_entities (modified_by);
create index farm_tombstones_operation_idx
  on public.farm_tombstones (operation_id);
create index farm_tombstones_deleted_by_idx
  on public.farm_tombstones (deleted_by);
create index farm_assets_uploaded_by_idx
  on public.farm_assets (uploaded_by);
create index farm_checkpoints_farm_generation_idx
  on public.farm_checkpoints (farm_id, authority_generation, through_revision);
create index farm_checkpoints_created_by_idx
  on public.farm_checkpoints (created_by);
create index authority_transitions_farm_state_idx
  on public.authority_transitions (farm_id, state, target_generation);
create index authority_transitions_initiated_by_idx
  on public.authority_transitions (initiated_by);
create index deletion_requests_user_status_idx
  on public.account_deletion_requests (user_id, status);

create or replace function esheep_private.is_active_farm_member(
  p_farm_id uuid,
  p_roles text[] default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select auth.uid()) is not null
    and exists (
      select 1
      from public.farm_members member
      where member.farm_id = p_farm_id
        and member.user_id = (select auth.uid())
        and member.status = 'active'
        and (p_roles is null or member.role = any (p_roles))
    );
$$;

revoke all on function esheep_private.is_active_farm_member(uuid, text[]) from public, anon;
grant execute on function esheep_private.is_active_farm_member(uuid, text[]) to authenticated;

create or replace function esheep_private.storage_farm_id(p_name text)
returns uuid
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when split_part(p_name, '/', 1) ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    then split_part(p_name, '/', 1)::uuid
    else null
  end;
$$;

revoke all on function esheep_private.storage_farm_id(text) from public, anon;
grant execute on function esheep_private.storage_farm_id(text) to authenticated;

create or replace function esheep_private.realtime_farm_id(p_topic text)
returns uuid
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when split_part(p_topic, ':', 1) = 'farm'
      and split_part(p_topic, ':', 2) ~
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    then split_part(p_topic, ':', 2)::uuid
    else null
  end;
$$;

revoke all on function esheep_private.realtime_farm_id(text) from public, anon;
grant execute on function esheep_private.realtime_farm_id(text) to authenticated;

create or replace function esheep_private.member_allows_operation(
  p_farm_id uuid,
  p_entity_type text,
  p_deleted_at timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select case member.role
      when 'owner' then true
      when 'administrator' then
        p_deleted_at is null
        and p_entity_type <> 'farm'
      when 'worker' then
        p_deleted_at is null
        and p_entity_type not in (
          'farm',
          'feedIngredient',
          'feedRecipe',
          'feedRecipeComponent',
          'semen',
          'breedingProgram',
          'healthCatalogItem',
          'careRule'
        )
      else false
    end
    from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = (select auth.uid())
      and member.status = 'active'
  ), false);
$$;

revoke all on function esheep_private.member_allows_operation(uuid, text, timestamptz)
  from public, anon;
grant execute on function esheep_private.member_allows_operation(uuid, text, timestamptz)
  to authenticated;

create or replace function esheep_private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, app_account_id, display_name)
  values (new.id, new.id, null)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function esheep_private.handle_new_auth_user() from public, anon, authenticated;

create trigger create_esheep_profile_after_auth_user
after insert on auth.users
for each row execute function esheep_private.handle_new_auth_user();

create or replace function esheep_private.broadcast_farm_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Realtime is provisioned independently on a brand-new hosted project.
  -- Cursor pull remains authoritative while that managed schema is not yet
  -- present; once provisioned, the same trigger starts broadcasting without
  -- another application release.
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null then
    execute 'select realtime.send($1, $2, $3, $4)'
    using
      jsonb_build_object(
        'revision', new.revision,
        'authority_generation', new.authority_generation
      ),
      'revision_available',
      'farm:' || lower(new.farm_id::text),
      true;
  end if;
  return null;
end;
$$;

revoke all on function esheep_private.broadcast_farm_revision()
  from public, anon, authenticated;

create trigger broadcast_farm_operation_revision
after insert on public.farm_operations
for each row execute function esheep_private.broadcast_farm_revision();

create or replace function public.register_device(
  p_device_id uuid,
  p_public_key_jwk jsonb,
  p_display_name text
)
returns table (device_id uuid, registered_at bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registered_at timestamptz;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  insert into public.devices (
    device_id,
    user_id,
    public_key_jwk,
    display_name,
    status,
    registered_at,
    revoked_at
  )
  values (
    p_device_id,
    v_user_id,
    p_public_key_jwk,
    left(coalesce(p_display_name, ''), 120),
    'active',
    now(),
    null
  )
  on conflict (device_id) do update
  set
    public_key_jwk = excluded.public_key_jwk,
    display_name = excluded.display_name,
    status = 'active',
    revoked_at = null
  where public.devices.user_id = v_user_id
  returning public.devices.registered_at into v_registered_at;

  if v_registered_at is null then
    raise exception using errcode = '42501', message = 'device_owned_by_another_user';
  end if;

  return query
  select p_device_id, extract(epoch from v_registered_at)::bigint;
end;
$$;

revoke all on function public.register_device(uuid, jsonb, text) from public, anon;
grant execute on function public.register_device(uuid, jsonb, text) to authenticated;

create or replace function public.claim_legacy_account(p_ticket text)
returns table (app_account_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_ticket esheep_private.legacy_account_claim_tickets%rowtype;
  v_identity_matches boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select *
  into v_ticket
  from esheep_private.legacy_account_claim_tickets ticket
  where ticket.ticket_digest = extensions.digest(p_ticket, 'sha256')
  for update;

  if not found
    or v_ticket.consumed_at is not null
    or v_ticket.expires_at <= now()
  then
    raise exception using errcode = '22023', message = 'legacy_claim_invalid_or_expired';
  end if;

  if v_ticket.provider = 'apple' then
    select exists (
      select 1
      from auth.identities identity
      where identity.user_id = v_user_id
        and identity.provider = 'apple'
        and extensions.digest(lower(identity.provider_id), 'sha256')
          = v_ticket.provider_identity_digest
    ) into v_identity_matches;
  elsif v_ticket.provider = 'email' then
    select exists (
      select 1
      from auth.users auth_user
      where auth_user.id = v_user_id
        and auth_user.email_confirmed_at is not null
        and extensions.digest(lower(auth_user.email), 'sha256')
          = v_ticket.provider_identity_digest
    ) into v_identity_matches;
  end if;

  if not v_identity_matches then
    raise exception using errcode = '42501', message = 'legacy_identity_mismatch';
  end if;

  if exists (
    select 1
    from public.profiles profile
    where profile.app_account_id = v_ticket.app_account_id
      and profile.user_id <> v_user_id
  ) then
    raise exception using errcode = '23505', message = 'legacy_account_already_claimed';
  end if;

  update public.profiles
  set app_account_id = v_ticket.app_account_id, updated_at = now()
  where user_id = v_user_id;

  update esheep_private.legacy_account_claim_tickets
  set consumed_at = now(), consumed_by = v_user_id
  where ticket_digest = v_ticket.ticket_digest;

  return query select v_ticket.app_account_id;
end;
$$;

revoke all on function public.claim_legacy_account(text) from public, anon;
grant execute on function public.claim_legacy_account(text) to authenticated;

create or replace function public.request_account_deletion()
returns table (deletion_job_id text, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_job_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  if exists (
    select 1
    from public.farm_registry registry
    where registry.owner_user_id = v_user_id
      and registry.status not in ('archived', 'failed')
  ) then
    raise exception using errcode = '23514', message = 'owned_farms_must_be_resolved';
  end if;

  insert into public.account_deletion_requests (user_id)
  values (v_user_id)
  returning account_deletion_requests.deletion_job_id into v_job_id;

  return query select v_job_id::text, 'queued'::text;
end;
$$;

revoke all on function public.request_account_deletion() from public, anon;
grant execute on function public.request_account_deletion() to authenticated;

create or replace function public.register_farm_authority(
  p_farm_id uuid,
  p_provider text,
  p_cloud_locator jsonb default null
)
returns table (farm_id uuid, authority_generation integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_existing public.farm_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_provider not in ('icloud', 'supabase') then
    raise exception using errcode = '22023', message = 'invalid_farm_provider';
  end if;

  select profile.app_account_id
  into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  if v_account_id is null then
    raise exception using errcode = '23503', message = 'profile_missing';
  end if;

  select *
  into v_existing
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if found then
    if v_existing.owner_user_id <> v_user_id
      or v_existing.provider <> p_provider
    then
      raise exception using errcode = '42501', message = 'farm_authority_already_registered';
    end if;
  else
    insert into public.farm_registry (
      farm_id,
      owner_user_id,
      provider,
      status,
      authority_generation,
      cloud_locator
    )
    values (
      p_farm_id,
      v_user_id,
      p_provider,
      'preparing',
      0,
      case when p_provider = 'icloud' then p_cloud_locator else null end
    )
    returning * into v_existing;
  end if;

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by
  )
  values (
    p_farm_id,
    v_user_id,
    v_account_id,
    'owner',
    'active',
    v_user_id
  )
  on conflict (farm_id, user_id) do update
  set role = 'owner', status = 'active', updated_at = now()
  where public.farm_members.user_id = v_user_id;

  return query select p_farm_id, v_existing.authority_generation;
end;
$$;

revoke all on function public.register_farm_authority(uuid, text, jsonb) from public, anon;
grant execute on function public.register_farm_authority(uuid, text, jsonb) to authenticated;

create or replace function public.activate_farm_authority(
  p_farm_id uuid,
  p_expected_generation integer,
  p_expected_revision bigint,
  p_manifest_digest text
)
returns table (farm_id uuid, authority_generation integer, current_revision bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
  v_operation_count bigint;
  v_max_revision bigint;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_expected_generation < 0
    or p_expected_revision < 0
    or p_manifest_digest !~ '^[0-9a-f]{64}$'
  then
    raise exception using errcode = '22023', message = 'invalid_activation_manifest';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if not found
    or v_registry.owner_user_id <> v_user_id
    or v_registry.status <> 'preparing'
    or v_registry.authority_generation <> p_expected_generation
  then
    raise exception using errcode = '42501', message = 'farm_activation_denied';
  end if;

  select count(*), coalesce(max(operation.revision), 0)
  into v_operation_count, v_max_revision
  from public.farm_operations operation
  where operation.farm_id = p_farm_id
    and operation.authority_generation = p_expected_generation;

  if v_operation_count <> p_expected_revision
    or v_max_revision <> p_expected_revision
  then
    raise exception using errcode = '23514', message = 'activation_revision_mismatch';
  end if;

  if p_expected_revision > 0 and not exists (
    select 1
    from public.farm_checkpoints checkpoint
    where checkpoint.farm_id = p_farm_id
      and checkpoint.authority_generation = p_expected_generation
      and checkpoint.through_revision = p_expected_revision
      and checkpoint.manifest_digest = p_manifest_digest
      and checkpoint.verified_at is not null
  ) then
    raise exception using errcode = '23514', message = 'verified_checkpoint_required';
  end if;

  update public.farm_registry
  set
    status = 'active',
    current_revision = p_expected_revision,
    updated_at = now()
  where farm_registry.farm_id = p_farm_id
  returning * into v_registry;

  return query
  select v_registry.farm_id, v_registry.authority_generation, v_registry.current_revision;
end;
$$;

revoke all on function public.activate_farm_authority(uuid, integer, bigint, text) from public, anon;
grant execute on function public.activate_farm_authority(uuid, integer, bigint, text) to authenticated;

create or replace function public.deactivate_farm_authority(
  p_farm_id uuid,
  p_expected_generation integer,
  p_archive boolean default false
)
returns table (farm_id uuid, authority_generation integer, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if not found
    or v_registry.owner_user_id <> v_user_id
    or v_registry.authority_generation <> p_expected_generation
    or v_registry.status not in ('preparing', 'active', 'read_only')
  then
    raise exception using errcode = '42501', message = 'farm_deactivation_denied';
  end if;

  update public.farm_registry
  set status = case when p_archive then 'archived' else 'read_only' end,
      updated_at = now()
  where farm_registry.farm_id = p_farm_id
  returning * into v_registry;

  return query
  select v_registry.farm_id, v_registry.authority_generation, v_registry.status;
end;
$$;

revoke all on function public.deactivate_farm_authority(uuid, integer, boolean) from public, anon;
grant execute on function public.deactivate_farm_authority(uuid, integer, boolean) to authenticated;

create or replace function public.apply_farm_operation(
  p_farm_id uuid,
  p_operation_id uuid,
  p_authority_generation integer,
  p_entity_type text,
  p_entity_id uuid,
  p_base_revision integer,
  p_resulting_revision integer,
  p_schema_version integer,
  p_payload_base64 text,
  p_payload_digest text,
  p_modified_by_account_id uuid,
  p_modified_by_device_id uuid,
  p_capability_certificate text,
  p_operation_signature text,
  p_occurred_at timestamptz,
  p_modified_at timestamptz,
  p_deleted_at timestamptz default null
)
returns table (
  operation_id uuid,
  revision bigint,
  server_received_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
  v_current_entity_revision integer := 0;
  v_next_revision bigint;
  v_received_at timestamptz;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'farm_write_denied';
  end if;
  if not esheep_private.member_allows_operation(
    p_farm_id,
    p_entity_type,
    p_deleted_at
  ) then
    raise exception using errcode = '42501', message = 'farm_operation_capability_denied';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if not found or v_registry.provider <> 'supabase' or v_registry.status <> 'active' then
    raise exception using errcode = '55000', message = 'farm_authority_not_writable';
  end if;

  if v_registry.authority_generation <> p_authority_generation then
    raise exception using errcode = '40001', message = 'authority_generation_mismatch';
  end if;

  select existing.revision, existing.server_received_at
  into v_next_revision, v_received_at
  from public.farm_operations existing
  where existing.operation_id = p_operation_id;

  if found then
    if not exists (
      select 1
      from public.farm_operations existing
      where existing.operation_id = p_operation_id
        and existing.farm_id = p_farm_id
        and existing.authority_generation = p_authority_generation
        and existing.entity_type = p_entity_type
        and existing.entity_id = p_entity_id
        and existing.base_revision = p_base_revision
        and existing.resulting_revision = p_resulting_revision
        and existing.payload_base64 = p_payload_base64
        and existing.payload_digest = p_payload_digest
        and existing.modified_by_account_id = p_modified_by_account_id
        and existing.modified_by_device_id = p_modified_by_device_id
    ) then
      raise exception using errcode = '23505', message = 'operation_id_payload_mismatch';
    end if;
    return query select p_operation_id, v_next_revision, v_received_at;
    return;
  end if;

  select entity.revision
  into v_current_entity_revision
  from public.farm_entities entity
  where entity.farm_id = p_farm_id
    and entity.entity_type = p_entity_type
    and entity.entity_id = p_entity_id;
  v_current_entity_revision := coalesce(v_current_entity_revision, 0);

  if v_current_entity_revision <> p_base_revision then
    raise exception using errcode = '40001', message = 'base_revision_mismatch';
  end if;
  if p_resulting_revision <> p_base_revision + 1 then
    raise exception using errcode = '22023', message = 'resulting_revision_invalid';
  end if;

  if p_payload_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_payload_digest';
  end if;
  if encode(
    extensions.digest(decode(p_payload_base64, 'base64'), 'sha256'),
    'hex'
  ) <> p_payload_digest then
    raise exception using errcode = '22023', message = 'payload_digest_mismatch';
  end if;
  if not exists (
    select 1
    from public.profiles profile
    join public.devices device on device.user_id = profile.user_id
    where profile.user_id = v_user_id
      and profile.app_account_id = p_modified_by_account_id
      and device.device_id = p_modified_by_device_id
      and device.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'operation_identity_mismatch';
  end if;
  if p_entity_type like 'tmr%'
    and not exists (
      select 1
      from public.devices device
      where device.device_id = p_modified_by_device_id
        and device.user_id = v_user_id
        and device.status = 'active'
        and coalesce(device.tmr_data_protocol_version, 0) >= 1
    )
  then
    raise exception using errcode = '55000',
      message = 'tmr_client_upgrade_required';
  end if;

  v_next_revision := v_registry.current_revision + 1;
  v_received_at := now();

  insert into public.farm_operations (
    operation_id,
    farm_id,
    authority_generation,
    revision,
    base_revision,
    resulting_revision,
    schema_version,
    entity_type,
    entity_id,
    actor_user_id,
    modified_by_account_id,
    modified_by_device_id,
    payload_base64,
    payload_digest,
    capability_certificate,
    operation_signature,
    deleted_at,
    occurred_at,
    modified_at,
    server_received_at
  )
  values (
    p_operation_id,
    p_farm_id,
    p_authority_generation,
    v_next_revision,
    p_base_revision,
    p_resulting_revision,
    p_schema_version,
    p_entity_type,
    p_entity_id,
    v_user_id,
    p_modified_by_account_id,
    p_modified_by_device_id,
    p_payload_base64,
    p_payload_digest,
    p_capability_certificate,
    p_operation_signature,
    p_deleted_at,
    p_occurred_at,
    p_modified_at,
    v_received_at
  );

  insert into public.farm_entities (
    farm_id,
    entity_type,
    entity_id,
    authority_generation,
    revision,
    operation_id,
    payload_base64,
    payload_digest,
    modified_by,
    modified_at,
    deleted_at
  )
  values (
    p_farm_id,
    p_entity_type,
    p_entity_id,
    p_authority_generation,
    p_resulting_revision,
    p_operation_id,
    p_payload_base64,
    p_payload_digest,
    v_user_id,
    p_modified_at,
    p_deleted_at
  )
  on conflict (farm_id, entity_type, entity_id) do update
  set
    authority_generation = excluded.authority_generation,
    revision = excluded.revision,
    operation_id = excluded.operation_id,
    payload_base64 = excluded.payload_base64,
    payload_digest = excluded.payload_digest,
    modified_by = excluded.modified_by,
    modified_at = excluded.modified_at,
    deleted_at = excluded.deleted_at;

  if p_deleted_at is not null then
    insert into public.farm_tombstones (
      farm_id,
      entity_type,
      entity_id,
      authority_generation,
      revision,
      operation_id,
      deleted_by,
      deleted_at
    )
    values (
      p_farm_id,
      p_entity_type,
      p_entity_id,
      p_authority_generation,
      p_resulting_revision,
      p_operation_id,
      v_user_id,
      p_deleted_at
    )
    on conflict (farm_id, entity_type, entity_id) do update
    set
      authority_generation = excluded.authority_generation,
      revision = excluded.revision,
      operation_id = excluded.operation_id,
      deleted_by = excluded.deleted_by,
      deleted_at = excluded.deleted_at;
  else
    delete from public.farm_tombstones tombstone
    where tombstone.farm_id = p_farm_id
      and tombstone.entity_type = p_entity_type
      and tombstone.entity_id = p_entity_id;
  end if;

  update public.farm_registry
  set current_revision = v_next_revision, updated_at = v_received_at
  where farm_id = p_farm_id;

  return query select p_operation_id, v_next_revision, v_received_at;
end;
$$;

revoke all on function public.apply_farm_operation(
  uuid,
  uuid,
  integer,
  text,
  uuid,
  integer,
  integer,
  integer,
  text,
  text,
  uuid,
  uuid,
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz
) from public, anon;
grant execute on function public.apply_farm_operation(
  uuid,
  uuid,
  integer,
  text,
  uuid,
  integer,
  integer,
  integer,
  text,
  text,
  uuid,
  uuid,
  text,
  text,
  timestamptz,
  timestamptz,
  timestamptz
) to authenticated;

create or replace function public.register_farm_asset(
  p_asset_id uuid,
  p_farm_id uuid,
  p_authority_generation integer,
  p_sha256 text,
  p_storage_path text,
  p_byte_count bigint,
  p_content_type text
)
returns table (asset_id uuid, storage_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
  v_asset_id uuid;
  v_storage_path text;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'farm_asset_write_denied';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$'
    or p_byte_count < 0
    or p_storage_path <> (lower(p_farm_id::text) || '/' || p_sha256)
  then
    raise exception using errcode = '22023', message = 'invalid_asset_manifest';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id;

  if not found
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'active'
    or v_registry.authority_generation <> p_authority_generation
  then
    raise exception using errcode = '55000', message = 'farm_authority_not_writable';
  end if;

  if not exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'farm-assets'
      and object.name = p_storage_path
  ) then
    raise exception using errcode = '23503', message = 'asset_object_missing';
  end if;

  insert into public.farm_assets (
    asset_id,
    farm_id,
    sha256,
    storage_path,
    byte_count,
    content_type,
    authority_generation,
    uploaded_by
  )
  values (
    p_asset_id,
    p_farm_id,
    p_sha256,
    p_storage_path,
    p_byte_count,
    left(p_content_type, 160),
    p_authority_generation,
    v_user_id
  )
  on conflict (farm_id, sha256) do update
  set deleted_at = null
  returning public.farm_assets.asset_id, public.farm_assets.storage_path
  into v_asset_id, v_storage_path;

  return query select v_asset_id, v_storage_path;
end;
$$;

revoke all on function public.register_farm_asset(
  uuid,
  uuid,
  integer,
  text,
  text,
  bigint,
  text
) from public, anon;
grant execute on function public.register_farm_asset(
  uuid,
  uuid,
  integer,
  text,
  text,
  bigint,
  text
) to authenticated;

create or replace function public.begin_farm_authority_transition(
  p_farm_id uuid,
  p_migration_id uuid,
  p_source_provider text,
  p_target_generation integer,
  p_baseline_revision bigint,
  p_manifest_digest text
)
returns table (
  migration_id uuid,
  authority_generation integer,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_registry public.farm_registry%rowtype;
  v_transition public.authority_transitions%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_source_provider not in ('local_only', 'icloud', 'supabase')
    or p_target_generation < 1
    or p_baseline_revision < 0
    or p_manifest_digest !~ '^[0-9a-f]{64}$'
  then
    raise exception using errcode = '22023', message = 'invalid_authority_transition';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  select profile.app_account_id
  into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;
  if v_account_id is null then
    raise exception using errcode = '23503', message = 'profile_missing';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if found then
    if v_registry.owner_user_id <> v_user_id
      or v_registry.provider <> 'supabase'
      or v_registry.status not in ('preparing', 'failed')
    then
      raise exception using errcode = '42501', message = 'farm_transition_denied';
    end if;
  else
    insert into public.farm_registry (
      farm_id,
      owner_user_id,
      provider,
      status,
      authority_generation,
      current_revision
    )
    values (
      p_farm_id,
      v_user_id,
      'supabase',
      'preparing',
      p_target_generation,
      0
    )
    returning * into v_registry;
  end if;

  if v_registry.authority_generation <> p_target_generation then
    raise exception using errcode = '40001', message = 'authority_generation_mismatch';
  end if;

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by
  )
  values (
    p_farm_id,
    v_user_id,
    v_account_id,
    'owner',
    'active',
    v_user_id
  )
  on conflict (farm_id, user_id) do update
  set role = 'owner', status = 'active', updated_at = now()
  where public.farm_members.user_id = v_user_id;

  insert into public.authority_transitions (
    migration_id,
    farm_id,
    source_provider,
    target_provider,
    source_generation,
    target_generation,
    baseline_revision,
    state,
    initiated_by
  )
  values (
    p_migration_id,
    p_farm_id,
    p_source_provider,
    'supabase',
    p_target_generation - 1,
    p_target_generation,
    p_baseline_revision,
    'preparing',
    v_user_id
  )
  on conflict (migration_id) do nothing;

  select *
  into v_transition
  from public.authority_transitions transition
  where transition.migration_id = p_migration_id;

  if v_transition.farm_id <> p_farm_id
    or v_transition.target_provider <> 'supabase'
    or v_transition.target_generation <> p_target_generation
  then
    raise exception using errcode = '23505', message = 'migration_id_payload_mismatch';
  end if;

  return query
  select v_transition.migration_id, v_registry.authority_generation, v_registry.status;
end;
$$;

revoke all on function public.begin_farm_authority_transition(
  uuid, uuid, text, integer, bigint, text
) from public, anon;
grant execute on function public.begin_farm_authority_transition(
  uuid, uuid, text, integer, bigint, text
) to authenticated;

create or replace function public.register_farm_checkpoint(
  p_checkpoint_id uuid,
  p_farm_id uuid,
  p_migration_id uuid,
  p_authority_generation integer,
  p_through_revision bigint,
  p_manifest jsonb,
  p_manifest_digest text,
  p_storage_path text,
  p_operation_count bigint,
  p_entity_count bigint,
  p_tombstone_count bigint,
  p_asset_count bigint
)
returns table (
  checkpoint_id uuid,
  manifest_digest text,
  verified boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_checkpoint public.farm_checkpoints%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_manifest_digest !~ '^[0-9a-f]{64}$'
    or p_storage_path <> (
      lower(p_farm_id::text) || '/' ||
      lower(p_migration_id::text) || '/' ||
      p_manifest_digest || '.json'
    )
    or p_operation_count < 0
    or p_entity_count < 0
    or p_tombstone_count < 0
    or p_asset_count < 0
  then
    raise exception using errcode = '22023', message = 'invalid_checkpoint_manifest';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  if not exists (
    select 1
    from public.farm_registry registry
    join public.authority_transitions transition
      on transition.farm_id = registry.farm_id
    where registry.farm_id = p_farm_id
      and registry.owner_user_id = v_user_id
      and registry.provider = 'supabase'
      and registry.status = 'preparing'
      and registry.authority_generation = p_authority_generation
      and transition.migration_id = p_migration_id
      and transition.target_generation = p_authority_generation
      and transition.state in ('preparing', 'uploading_baseline', 'verifying')
  ) then
    raise exception using errcode = '42501', message = 'checkpoint_registration_denied';
  end if;

  if not exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'farm-checkpoints'
      and object.name = p_storage_path
      and object.owner_id = v_user_id::text
  ) then
    raise exception using errcode = '23503', message = 'checkpoint_object_missing';
  end if;

  insert into public.farm_checkpoints (
    checkpoint_id,
    farm_id,
    authority_generation,
    through_revision,
    manifest,
    manifest_digest,
    storage_path,
    operation_count,
    entity_count,
    tombstone_count,
    asset_count,
    created_by
  )
  values (
    p_checkpoint_id,
    p_farm_id,
    p_authority_generation,
    p_through_revision,
    p_manifest,
    p_manifest_digest,
    p_storage_path,
    p_operation_count,
    p_entity_count,
    p_tombstone_count,
    p_asset_count,
    v_user_id
  )
  on conflict (checkpoint_id) do nothing;

  select *
  into v_checkpoint
  from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id;

  if v_checkpoint.farm_id <> p_farm_id
    or v_checkpoint.authority_generation <> p_authority_generation
    or v_checkpoint.manifest_digest <> p_manifest_digest
    or v_checkpoint.storage_path <> p_storage_path
  then
    raise exception using errcode = '23505', message = 'checkpoint_id_payload_mismatch';
  end if;

  update public.authority_transitions
  set state = 'verifying', updated_at = now()
  where migration_id = p_migration_id
    and state in ('preparing', 'uploading_baseline', 'verifying');

  return query
  select v_checkpoint.checkpoint_id, v_checkpoint.manifest_digest,
    v_checkpoint.verified_at is not null;
end;
$$;

revoke all on function public.register_farm_checkpoint(
  uuid, uuid, uuid, integer, bigint, jsonb, text, text,
  bigint, bigint, bigint, bigint
) from public, anon;
grant execute on function public.register_farm_checkpoint(
  uuid, uuid, uuid, integer, bigint, jsonb, text, text,
  bigint, bigint, bigint, bigint
) to authenticated;

create or replace function public.verify_and_activate_farm_authority(
  p_farm_id uuid,
  p_migration_id uuid,
  p_checkpoint_id uuid,
  p_expected_generation integer,
  p_manifest_digest text
)
returns table (
  farm_id uuid,
  authority_generation integer,
  current_revision bigint,
  status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
  v_checkpoint public.farm_checkpoints%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  select *
  into v_checkpoint
  from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id
    and checkpoint.farm_id = p_farm_id;

  if v_registry.owner_user_id <> v_user_id
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'preparing'
    or v_registry.authority_generation <> p_expected_generation
    or v_checkpoint.authority_generation <> p_expected_generation
    or v_checkpoint.manifest_digest <> p_manifest_digest
    or not exists (
      select 1
      from public.authority_transitions transition
      where transition.migration_id = p_migration_id
        and transition.farm_id = p_farm_id
        and transition.target_generation = p_expected_generation
        and transition.state = 'verifying'
    )
  then
    raise exception using errcode = '42501', message = 'farm_activation_denied';
  end if;

  if (
    select count(*)
    from public.farm_operations operation
    where operation.farm_id = p_farm_id
      and operation.authority_generation = p_expected_generation
      and operation.is_staged
  ) <> v_checkpoint.operation_count
    or (
      select coalesce(max(operation.revision), 0)
      from public.farm_operations operation
      where operation.farm_id = p_farm_id
        and operation.authority_generation = p_expected_generation
        and operation.is_staged
    ) <> v_checkpoint.through_revision
    or (
      select count(*)
      from public.farm_entities entity
      where entity.farm_id = p_farm_id
        and entity.authority_generation = p_expected_generation
    ) <> v_checkpoint.entity_count
    or (
      select count(*)
      from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
        and tombstone.authority_generation = p_expected_generation
    ) <> v_checkpoint.tombstone_count
  then
    raise exception using errcode = '23514', message = 'checkpoint_projection_mismatch';
  end if;

  update public.farm_checkpoints
  set verified_at = now()
  where checkpoint_id = p_checkpoint_id;

  update public.farm_registry
  set status = 'active', updated_at = now()
  where farm_registry.farm_id = p_farm_id
  returning * into v_registry;

  update public.authority_transitions
  set state = 'draining', committed_at = now(), updated_at = now()
  where migration_id = p_migration_id;

  return query
  select v_registry.farm_id, v_registry.authority_generation,
    v_registry.current_revision, v_registry.status;
end;
$$;

revoke all on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) from public, anon;
grant execute on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) to authenticated;

create or replace function public.apply_farm_operations_batch(
  p_farm_id uuid,
  p_authority_generation integer,
  p_operations jsonb
)
returns table (
  operation_id uuid,
  revision bigint,
  server_received_at timestamptz,
  result_status text,
  error_code text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_count integer;
  v_client_sequence bigint;
  v_receipt record;
begin
  if (select auth.uid()) is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if jsonb_typeof(p_operations) <> 'array' then
    raise exception using errcode = '22023', message = 'operations_must_be_array';
  end if;

  v_count := jsonb_array_length(p_operations);
  if v_count < 1 or v_count > 25 then
    raise exception using errcode = '22023', message = 'operation_batch_size_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  for v_item in
    select value
    from jsonb_array_elements(p_operations)
    order by (value->>'client_sequence')::bigint
  loop
    v_client_sequence := (v_item->>'client_sequence')::bigint;
    if v_client_sequence < 1 then
      raise exception using errcode = '22023', message = 'client_sequence_invalid';
    end if;

    begin
      select *
      into v_receipt
      from public.apply_farm_operation(
        p_farm_id,
        (v_item->>'operation_id')::uuid,
        p_authority_generation,
        v_item->>'entity_type',
        (v_item->>'entity_id')::uuid,
        (v_item->>'base_revision')::integer,
        (v_item->>'resulting_revision')::integer,
        (v_item->>'schema_version')::integer,
        v_item->>'payload_base64',
        v_item->>'payload_digest',
        (v_item->>'modified_by_account_id')::uuid,
        (v_item->>'modified_by_device_id')::uuid,
        v_item->>'capability_certificate',
        v_item->>'operation_signature',
        (v_item->>'occurred_at')::timestamptz,
        (v_item->>'modified_at')::timestamptz,
        nullif(v_item->>'deleted_at', '')::timestamptz
      );

      update public.farm_operations operation
      set client_sequence = v_client_sequence
      where operation.operation_id = (v_item->>'operation_id')::uuid
        and operation.client_sequence in (0, v_client_sequence);

      if not found then
        raise exception using errcode = '23505', message = 'client_sequence_payload_mismatch';
      end if;

      operation_id := v_receipt.operation_id;
      revision := v_receipt.revision;
      server_received_at := v_receipt.server_received_at;
      result_status := 'accepted';
      error_code := null;
      return next;
    exception
      when serialization_failure then
        operation_id := (v_item->>'operation_id')::uuid;
        revision := null;
        server_received_at := null;
        result_status := 'conflict';
        error_code := sqlerrm;
        return next;
        exit;
    end;
  end loop;
end;
$$;

revoke all on function public.apply_farm_operations_batch(
  uuid, integer, jsonb
) from public, anon;
grant execute on function public.apply_farm_operations_batch(
  uuid, integer, jsonb
) to authenticated;

create or replace function public.stage_farm_operations_batch(
  p_farm_id uuid,
  p_migration_id uuid,
  p_authority_generation integer,
  p_operations jsonb
)
returns table (
  operation_id uuid,
  revision bigint,
  server_received_at timestamptz,
  result_status text,
  error_code text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_result record;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  if not exists (
    select 1
    from public.farm_registry registry
    join public.authority_transitions transition
      on transition.farm_id = registry.farm_id
    where registry.farm_id = p_farm_id
      and registry.owner_user_id = v_user_id
      and registry.provider = 'supabase'
      and registry.status = 'preparing'
      and registry.authority_generation = p_authority_generation
      and transition.migration_id = p_migration_id
      and transition.target_generation = p_authority_generation
      and transition.state in ('preparing', 'uploading_baseline')
  ) then
    raise exception using errcode = '42501', message = 'baseline_staging_denied';
  end if;

  update public.authority_transitions
  set state = 'uploading_baseline', updated_at = now()
  where migration_id = p_migration_id;

  -- The temporary state is visible only inside this transaction. It lets the
  -- ordinary operation validator and projector remain the single write path;
  -- concurrent clients continue to see the committed `preparing` state.
  update public.farm_registry
  set status = 'active', updated_at = now()
  where farm_registry.farm_id = p_farm_id;

  for v_result in
    select *
    from public.apply_farm_operations_batch(
      p_farm_id,
      p_authority_generation,
      p_operations
    )
  loop
    if v_result.result_status <> 'accepted' then
      raise exception using errcode = '40001', message = 'baseline_operation_conflict';
    end if;

    update public.farm_operations
    set is_staged = true
    where farm_operations.operation_id = v_result.operation_id;

    operation_id := v_result.operation_id;
    revision := v_result.revision;
    server_received_at := v_result.server_received_at;
    result_status := v_result.result_status;
    error_code := v_result.error_code;
    return next;
  end loop;

  update public.farm_registry
  set status = 'preparing', updated_at = now()
  where farm_registry.farm_id = p_farm_id;
end;
$$;

revoke all on function public.stage_farm_operations_batch(
  uuid, uuid, integer, jsonb
) from public, anon;
grant execute on function public.stage_farm_operations_batch(
  uuid, uuid, integer, jsonb
) to authenticated;

create or replace function public.create_farm_invite(
  p_farm_id uuid,
  p_role text,
  p_code_digest_hex text,
  p_expires_at timestamptz
)
returns table (
  invite_id uuid,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_invite_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_role not in ('administrator', 'worker')
    or p_code_digest_hex !~ '^[0-9a-f]{64}$'
    or p_expires_at <= now()
    or p_expires_at > now() + interval '24 hours'
  then
    raise exception using errcode = '22023', message = 'invalid_farm_invite';
  end if;
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator']
  ) then
    raise exception using errcode = '42501', message = 'farm_invite_denied';
  end if;

  insert into public.farm_invites (
    farm_id,
    invited_by,
    role,
    code_digest,
    expires_at
  )
  values (
    p_farm_id,
    v_user_id,
    p_role,
    decode(p_code_digest_hex, 'hex'),
    p_expires_at
  )
  returning farm_invites.invite_id into v_invite_id;

  return query select v_invite_id, p_expires_at;
end;
$$;

revoke all on function public.create_farm_invite(
  uuid, text, text, timestamptz
) from public, anon;
grant execute on function public.create_farm_invite(
  uuid, text, text, timestamptz
) to authenticated;

create or replace function public.redeem_farm_invite(
  p_code text
)
returns table (
  farm_id uuid,
  role text,
  authority_generation integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_invite public.farm_invites%rowtype;
  v_registry public.farm_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select profile.app_account_id
  into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  select *
  into v_invite
  from public.farm_invites invite
  where invite.code_digest = extensions.digest(p_code, 'sha256')
  for update;

  if not found
    or v_invite.status <> 'pending'
    or v_invite.expires_at <= now()
  then
    raise exception using errcode = '22023', message = 'farm_invite_invalid_or_expired';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = v_invite.farm_id
    and registry.status in ('active', 'read_only');

  if not found then
    raise exception using errcode = '55000', message = 'farm_authority_not_available';
  end if;

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by
  )
  values (
    v_invite.farm_id,
    v_user_id,
    v_account_id,
    v_invite.role,
    'active',
    v_invite.invited_by
  )
  on conflict (farm_id, user_id) do update
  set role = excluded.role, status = 'active', updated_at = now();

  update public.farm_invites
  set status = 'redeemed',
      redeemed_by = v_user_id,
      redeemed_at = now()
  where invite_id = v_invite.invite_id;

  return query
  select v_registry.farm_id, v_invite.role, v_registry.authority_generation;
end;
$$;

revoke all on function public.redeem_farm_invite(text) from public, anon;
grant execute on function public.redeem_farm_invite(text) to authenticated;

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

  return query select p_farm_id, p_member_user_id, 'revoked'::text;
end;
$$;

revoke all on function public.revoke_farm_member(uuid, uuid) from public, anon;
grant execute on function public.revoke_farm_member(uuid, uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.devices enable row level security;
alter table public.farm_registry enable row level security;
alter table public.farm_members enable row level security;
alter table public.farm_invites enable row level security;
alter table public.farm_operations enable row level security;
alter table public.farm_entities enable row level security;
alter table public.farm_tombstones enable row level security;
alter table public.farm_assets enable row level security;
alter table public.farm_checkpoints enable row level security;
alter table public.authority_transitions enable row level security;
alter table public.entitlements enable row level security;
alter table public.account_deletion_requests enable row level security;

create policy profiles_select_self
on public.profiles for select to authenticated
using ((select auth.uid()) = user_id);

create policy profiles_update_self
on public.profiles for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy devices_select_self
on public.devices for select to authenticated
using ((select auth.uid()) = user_id);

create policy farm_registry_select_member
on public.farm_registry for select to authenticated
using (
  owner_user_id = (select auth.uid())
  or esheep_private.is_active_farm_member(farm_id)
);

create policy farm_members_select_member
on public.farm_members for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy farm_invites_select_admin
on public.farm_invites for select to authenticated
using (
  esheep_private.is_active_farm_member(
    farm_id,
    array['owner', 'administrator']
  )
);

create policy farm_operations_select_member
on public.farm_operations for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy farm_entities_select_member
on public.farm_entities for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy farm_tombstones_select_member
on public.farm_tombstones for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy farm_assets_select_member
on public.farm_assets for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy farm_checkpoints_select_member
on public.farm_checkpoints for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy authority_transitions_select_member
on public.authority_transitions for select to authenticated
using (esheep_private.is_active_farm_member(farm_id));

create policy entitlements_select_owner_or_member
on public.entitlements for select to authenticated
using (
  owner_user_id = (select auth.uid())
  or exists (
    select 1
    from public.farm_registry registry
    where registry.owner_user_id = entitlements.owner_user_id
      and esheep_private.is_active_farm_member(registry.farm_id)
  )
);

create policy account_deletion_requests_select_self
on public.account_deletion_requests for select to authenticated
using (user_id = (select auth.uid()));

grant usage on schema public to authenticated;
grant select, update (display_name, updated_at) on public.profiles to authenticated;
grant select on public.devices to authenticated;
grant select on public.farm_registry to authenticated;
grant select on public.farm_members to authenticated;
grant select on public.farm_invites to authenticated;
grant select on public.farm_operations to authenticated;
grant select on public.farm_entities to authenticated;
grant select on public.farm_tombstones to authenticated;
grant select on public.farm_assets to authenticated;
grant select on public.farm_checkpoints to authenticated;
grant select on public.authority_transitions to authenticated;
grant select on public.entitlements to authenticated;
grant select on public.account_deletion_requests to authenticated;

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;

insert into storage.buckets (id, name, public, file_size_limit)
values ('farm-assets', 'farm-assets', false, 52428800)
on conflict (id) do update
set public = false, file_size_limit = excluded.file_size_limit;

insert into storage.buckets (id, name, public, file_size_limit)
values ('farm-checkpoints', 'farm-checkpoints', false, 104857600)
on conflict (id) do update
set public = false, file_size_limit = excluded.file_size_limit;

create policy farm_assets_storage_select_member
on storage.objects for select to authenticated
using (
  bucket_id = 'farm-assets'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name)
  )
);

create policy farm_assets_storage_insert_member
on storage.objects for insert to authenticated
with check (
  bucket_id = 'farm-assets'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name)
  )
);

create policy farm_assets_storage_update_member
on storage.objects for update to authenticated
using (
  bucket_id = 'farm-assets'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name)
  )
)
with check (
  bucket_id = 'farm-assets'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name)
  )
);

create policy farm_assets_storage_delete_admin
on storage.objects for delete to authenticated
using (
  bucket_id = 'farm-assets'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name),
    array['owner', 'administrator']
  )
);

create policy farm_checkpoints_storage_select_member
on storage.objects for select to authenticated
using (
  bucket_id = 'farm-checkpoints'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name)
  )
);

create policy farm_checkpoints_storage_insert_owner
on storage.objects for insert to authenticated
with check (
  bucket_id = 'farm-checkpoints'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name),
    array['owner']
  )
);

create policy farm_checkpoints_storage_update_owner
on storage.objects for update to authenticated
using (
  bucket_id = 'farm-checkpoints'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name),
    array['owner']
  )
)
with check (
  bucket_id = 'farm-checkpoints'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name),
    array['owner']
  )
);

create policy farm_checkpoints_storage_delete_owner
on storage.objects for delete to authenticated
using (
  bucket_id = 'farm-checkpoints'
  and esheep_private.is_active_farm_member(
    esheep_private.storage_farm_id(name),
    array['owner']
  )
);

-- Supabase locked the managed `realtime` schema against SQL migration changes
-- in 2026. Broadcast authorization is configured after project creation via
-- the supported Realtime Dashboard/API workflow; see REALTIME_SETUP.md.
