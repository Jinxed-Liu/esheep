-- Finish an already-committed local-to-Supabase authority transition.
--
-- This RPC intentionally does not require an active entitlement. Once the
-- target authority is active, billing changes must not leave the transition
-- permanently stuck in its post-commit cleanup state.

create function public.complete_farm_authority_transition(
  p_farm_id uuid,
  p_migration_id uuid,
  p_expected_generation integer
)
returns table (
  farm_id uuid,
  authority_generation integer,
  current_revision bigint,
  status text,
  transition_state text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registry public.farm_registry%rowtype;
  v_transition public.authority_transitions%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'authentication_required';
  end if;

  if p_expected_generation < 1 then
    raise exception using errcode = '22023',
      message = 'invalid_authority_generation';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  select *
  into v_transition
  from public.authority_transitions transition
  where transition.migration_id = p_migration_id
    and transition.farm_id = p_farm_id
  for update;

  if v_registry.farm_id is null
    or v_transition.migration_id is null
    or v_registry.owner_user_id <> v_user_id
    or not exists (
      select 1
      from public.farm_members member
      where member.farm_id = p_farm_id
        and member.user_id = v_user_id
        and member.role = 'owner'
        and member.status = 'active'
    )
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'active'
    or v_registry.authority_generation <> p_expected_generation
    or v_transition.initiated_by <> v_user_id
    or v_transition.target_provider <> 'supabase'
    or v_transition.target_generation <> p_expected_generation
    or v_transition.committed_at is null
    or v_transition.state not in (
      'draining',
      'archiving_source',
      'completed'
    )
  then
    raise exception using errcode = '42501',
      message = 'farm_transition_completion_denied';
  end if;

  if v_transition.state <> 'completed' then
    update public.authority_transitions transition
    set state = 'completed',
        updated_at = now()
    where transition.migration_id = p_migration_id
    returning * into v_transition;
  end if;

  return query
  select
    v_registry.farm_id,
    v_registry.authority_generation,
    v_registry.current_revision,
    v_registry.status,
    v_transition.state;
end;
$$;

revoke all on function public.complete_farm_authority_transition(
  uuid, uuid, integer
) from public, anon, authenticated;
grant execute on function public.complete_farm_authority_transition(
  uuid, uuid, integer
) to authenticated;

-- Hosted migrations execute as `postgres`, which is deliberately not a member
-- of the platform-owned `supabase_admin` role. PostgreSQL therefore rejects
-- ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin. The existing
-- esheep_guard_public_data_api_exposure event trigger remains the effective
-- public-schema guard and revokes implicit client grants as each supported
-- object is created. Storage, GraphQL and Realtime defaults remain untouched.

comment on function public.complete_farm_authority_transition(
  uuid, uuid, integer
) is
  'Idempotently completes an already committed owner authority transition.';

notify pgrst, 'reload schema';
