-- Account deletion is asynchronous. The iOS client only queues a request;
-- these service-role-only RPCs support the protected Edge Function worker.

alter table public.account_deletion_requests
  add column if not exists attempt_count integer not null default 0
    check (attempt_count >= 0),
  add column if not exists last_error_code text,
  add column if not exists processing_started_at timestamptz,
  add column if not exists next_attempt_at timestamptz not null default now();

alter table public.account_deletion_requests
  alter column user_id drop not null;

alter table public.account_deletion_requests
  drop constraint if exists account_deletion_requests_user_id_fkey;
alter table public.account_deletion_requests
  add constraint account_deletion_requests_user_id_fkey
  foreign key (user_id) references public.profiles(user_id) on delete set null;

-- Preserve immutable farm audit history while removing the user's profile,
-- memberships and devices. Historical actor references become anonymous.
alter table public.farm_members
  drop constraint if exists farm_members_invited_by_fkey;
alter table public.farm_members
  add constraint farm_members_invited_by_fkey
  foreign key (invited_by) references public.profiles(user_id) on delete set null;

alter table public.farm_invites
  alter column invited_by drop not null;
alter table public.farm_invites
  drop constraint if exists farm_invites_invited_by_fkey;
alter table public.farm_invites
  add constraint farm_invites_invited_by_fkey
  foreign key (invited_by) references public.profiles(user_id) on delete set null;
alter table public.farm_invites
  drop constraint if exists farm_invites_redeemed_by_fkey;
alter table public.farm_invites
  add constraint farm_invites_redeemed_by_fkey
  foreign key (redeemed_by) references public.profiles(user_id) on delete set null;

alter table public.farm_operations
  alter column actor_user_id drop not null,
  alter column modified_by_device_id drop not null;
alter table public.farm_operations
  drop constraint if exists farm_operations_actor_user_id_fkey;
alter table public.farm_operations
  add constraint farm_operations_actor_user_id_fkey
  foreign key (actor_user_id) references public.profiles(user_id) on delete set null;
alter table public.farm_operations
  drop constraint if exists farm_operations_modified_by_device_id_fkey;
alter table public.farm_operations
  add constraint farm_operations_modified_by_device_id_fkey
  foreign key (modified_by_device_id) references public.devices(device_id) on delete set null;

alter table public.farm_entities alter column modified_by drop not null;
alter table public.farm_entities
  drop constraint if exists farm_entities_modified_by_fkey;
alter table public.farm_entities
  add constraint farm_entities_modified_by_fkey
  foreign key (modified_by) references public.profiles(user_id) on delete set null;

alter table public.farm_tombstones alter column deleted_by drop not null;
alter table public.farm_tombstones
  drop constraint if exists farm_tombstones_deleted_by_fkey;
alter table public.farm_tombstones
  add constraint farm_tombstones_deleted_by_fkey
  foreign key (deleted_by) references public.profiles(user_id) on delete set null;

alter table public.farm_assets alter column uploaded_by drop not null;
alter table public.farm_assets
  drop constraint if exists farm_assets_uploaded_by_fkey;
alter table public.farm_assets
  add constraint farm_assets_uploaded_by_fkey
  foreign key (uploaded_by) references public.profiles(user_id) on delete set null;

alter table public.farm_checkpoints alter column created_by drop not null;
alter table public.farm_checkpoints
  drop constraint if exists farm_checkpoints_created_by_fkey;
alter table public.farm_checkpoints
  add constraint farm_checkpoints_created_by_fkey
  foreign key (created_by) references public.profiles(user_id) on delete set null;

alter table public.authority_transitions alter column initiated_by drop not null;
alter table public.authority_transitions
  drop constraint if exists authority_transitions_initiated_by_fkey;
alter table public.authority_transitions
  add constraint authority_transitions_initiated_by_fkey
  foreign key (initiated_by) references public.profiles(user_id) on delete set null;

alter table esheep_private.legacy_account_claim_tickets
  drop constraint if exists legacy_account_claim_tickets_consumed_by_fkey;
alter table esheep_private.legacy_account_claim_tickets
  add constraint legacy_account_claim_tickets_consumed_by_fkey
  foreign key (consumed_by) references auth.users(id) on delete set null;

create unique index if not exists account_deletion_one_open_job_idx
  on public.account_deletion_requests (user_id)
  where user_id is not null and status in ('queued', 'processing');

create or replace function public.request_account_deletion()
returns table (deletion_job_id text, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_job public.account_deletion_requests%rowtype;
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

  select request.* into v_job
  from public.account_deletion_requests request
  where request.user_id = v_user_id
    and request.status in ('queued', 'processing')
  order by request.requested_at desc
  limit 1;

  if not found then
    insert into public.account_deletion_requests (user_id)
    values (v_user_id)
    returning * into v_job;
  end if;

  return query select v_job.deletion_job_id::text, v_job.status;
end;
$$;

revoke all on function public.request_account_deletion()
  from public, anon, authenticated;
grant execute on function public.request_account_deletion() to authenticated;

create or replace function public.get_account_deletion_status(
  p_deletion_job_id uuid
)
returns table (
  status text,
  requested_at timestamptz,
  completed_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select request.status, request.requested_at, request.completed_at
  from public.account_deletion_requests request
  where request.deletion_job_id = p_deletion_job_id;
$$;

revoke all on function public.get_account_deletion_status(uuid)
  from public, anon, authenticated;
grant execute on function public.get_account_deletion_status(uuid)
  to anon, authenticated;

create or replace function public.claim_account_deletion_jobs(p_limit integer default 20)
returns table (deletion_job_id uuid, user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.role()), '') <> 'service_role'
    and session_user not in ('supabase_admin', 'postgres')
  then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  return query
  with candidates as (
    select request.deletion_job_id
    from public.account_deletion_requests request
    where request.user_id is not null
      and request.status in ('queued', 'failed')
      and request.next_attempt_at <= now()
      and request.attempt_count < 12
    order by request.requested_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  )
  update public.account_deletion_requests request
  set status = 'processing',
      attempt_count = request.attempt_count + 1,
      processing_started_at = now(),
      last_error_code = null
  from candidates
  where request.deletion_job_id = candidates.deletion_job_id
  returning request.deletion_job_id, request.user_id;
end;
$$;

create or replace function public.fail_account_deletion_job(
  p_deletion_job_id uuid,
  p_error_code text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.role()), '') <> 'service_role'
    and session_user not in ('supabase_admin', 'postgres')
  then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  update public.account_deletion_requests request
  set status = 'failed',
      last_error_code = left(coalesce(p_error_code, 'unknown'), 120),
      next_attempt_at = now() + make_interval(
        mins => least(360, greatest(5, request.attempt_count * 5))
      )
  where request.deletion_job_id = p_deletion_job_id
    and request.status = 'processing';
end;
$$;

create or replace function public.list_account_deletion_orphaned_storage(
  p_deletion_job_id uuid
)
returns table (bucket_id text, object_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if coalesce((select auth.role()), '') <> 'service_role'
    and session_user not in ('supabase_admin', 'postgres')
  then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select request.user_id into v_user_id
  from public.account_deletion_requests request
  where request.deletion_job_id = p_deletion_job_id
    and request.status = 'processing';

  if v_user_id is null then
    return;
  end if;

  return query
  select object.bucket_id, object.name
  from storage.objects object
  where (
      object.owner_id = v_user_id::text
      and not exists (
        select 1
        from public.farm_assets asset
        where object.bucket_id = 'farm-assets'
          and asset.storage_path = object.name
          and asset.deleted_at is null
      )
      and not exists (
        select 1
        from public.farm_checkpoints checkpoint
        where object.bucket_id = 'farm-checkpoints'
          and checkpoint.storage_path = object.name
      )
    )
    or exists (
      select 1
      from public.farm_assets asset
      join public.farm_registry registry on registry.farm_id = asset.farm_id
      where object.bucket_id = 'farm-assets'
        and asset.storage_path = object.name
        and registry.owner_user_id = v_user_id
        and registry.status in ('archived', 'failed')
    )
    or exists (
      select 1
      from public.farm_checkpoints checkpoint
      join public.farm_registry registry on registry.farm_id = checkpoint.farm_id
      where object.bucket_id = 'farm-checkpoints'
        and checkpoint.storage_path = object.name
        and registry.owner_user_id = v_user_id
        and registry.status in ('archived', 'failed')
    );
end;
$$;

create or replace function public.prepare_account_deletion_job(
  p_deletion_job_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if coalesce((select auth.role()), '') <> 'service_role'
    and session_user not in ('supabase_admin', 'postgres')
  then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select request.user_id into v_user_id
  from public.account_deletion_requests request
  where request.deletion_job_id = p_deletion_job_id
    and request.status = 'processing';

  if v_user_id is null then
    raise exception using errcode = '22023', message = 'deletion_job_not_processing';
  end if;
  if exists (
    select 1 from public.farm_registry registry
    where registry.owner_user_id = v_user_id
      and registry.status not in ('archived', 'failed')
  ) then
    raise exception using errcode = '23514', message = 'owned_farms_must_be_resolved';
  end if;

  delete from public.farm_registry registry
  where registry.owner_user_id = v_user_id
    and registry.status in ('archived', 'failed');
end;
$$;

create or replace function public.complete_account_deletion_job(
  p_deletion_job_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((select auth.role()), '') <> 'service_role'
    and session_user not in ('supabase_admin', 'postgres')
  then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  update public.account_deletion_requests request
  set status = 'completed',
      completed_at = now(),
      next_attempt_at = now(),
      last_error_code = null
  where request.deletion_job_id = p_deletion_job_id;
end;
$$;

revoke all on function public.claim_account_deletion_jobs(integer)
  from public, anon, authenticated;
revoke all on function public.fail_account_deletion_job(uuid, text)
  from public, anon, authenticated;
revoke all on function public.list_account_deletion_orphaned_storage(uuid)
  from public, anon, authenticated;
revoke all on function public.prepare_account_deletion_job(uuid)
  from public, anon, authenticated;
revoke all on function public.complete_account_deletion_job(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_account_deletion_jobs(integer) to service_role;
grant execute on function public.fail_account_deletion_job(uuid, text) to service_role;
grant execute on function public.list_account_deletion_orphaned_storage(uuid) to service_role;
grant execute on function public.prepare_account_deletion_job(uuid) to service_role;
grant execute on function public.complete_account_deletion_job(uuid) to service_role;
