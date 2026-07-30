alter function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) rename to verify_and_activate_farm_authority_once;

revoke all on function public.verify_and_activate_farm_authority_once(
  uuid, uuid, uuid, integer, text
) from public, anon, authenticated;

create function public.verify_and_activate_farm_authority(
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

  if v_registry.owner_user_id = v_user_id
    and v_registry.provider = 'supabase'
    and v_registry.status = 'active'
    and v_registry.authority_generation = p_expected_generation
    and exists (
      select 1
      from public.authority_transitions transition
      join public.farm_checkpoints checkpoint
        on checkpoint.farm_id = transition.farm_id
       and checkpoint.authority_generation = transition.target_generation
      where transition.migration_id = p_migration_id
        and transition.farm_id = p_farm_id
        and transition.target_generation = p_expected_generation
        and transition.state in ('draining', 'archiving_source', 'completed')
        and checkpoint.checkpoint_id = p_checkpoint_id
        and checkpoint.manifest_digest = p_manifest_digest
        and checkpoint.verified_at is not null
    )
  then
    return query
    select v_registry.farm_id, v_registry.authority_generation,
      v_registry.current_revision, v_registry.status;
    return;
  end if;

  return query
  select *
  from public.verify_and_activate_farm_authority_once(
    p_farm_id,
    p_migration_id,
    p_checkpoint_id,
    p_expected_generation,
    p_manifest_digest
  );
end;
$$;

revoke all on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) from public, anon;
grant execute on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) to authenticated;

create index if not exists legacy_claim_tickets_consumed_by_idx
  on esheep_private.legacy_account_claim_tickets (consumed_by)
  where consumed_by is not null;
