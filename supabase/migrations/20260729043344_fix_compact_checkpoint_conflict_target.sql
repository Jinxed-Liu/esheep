-- `checkpoint_id` is also an output column of this RPC. Name the primary-key
-- constraint explicitly so the idempotent insert cannot be confused with the
-- PL/pgSQL output variable.
create or replace function public.register_compact_farm_checkpoint(
  p_checkpoint_id uuid,
  p_farm_id uuid,
  p_migration_id uuid,
  p_authority_generation integer,
  p_archive_digest text,
  p_archive_byte_count bigint,
  p_storage_path text,
  p_manifest jsonb,
  p_projection_count bigint,
  p_tombstone_projection_count bigint,
  p_tombstone_history_count bigint,
  p_history_operation_count bigint,
  p_asset_count bigint
)
returns table (
  checkpoint_id uuid,
  archive_digest text,
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
    raise exception using errcode = '42501',
      message = 'authentication_required';
  end if;
  if p_archive_digest !~ '^[0-9a-f]{64}$'
    or p_archive_byte_count < 1
    or p_storage_path <> lower(p_farm_id::text) || '/' ||
      lower(p_migration_id::text) || '/' || p_archive_digest || '.esbc'
    or least(
      p_projection_count,
      p_tombstone_projection_count,
      p_tombstone_history_count,
      p_history_operation_count,
      p_asset_count
    ) < 0
    or p_tombstone_projection_count > p_projection_count
  then
    raise exception using errcode = '22023',
      message = 'invalid_compact_checkpoint_manifest';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));
  if not exists (
    select 1
    from public.farm_registry registry
    join public.authority_transitions transition
      on transition.farm_id = registry.farm_id
    where registry.farm_id = p_farm_id
      and registry.owner_user_id = v_user_id
      and registry.status = 'preparing'
      and registry.authority_generation = p_authority_generation
      and transition.migration_id = p_migration_id
      and transition.target_generation = p_authority_generation
      and transition.baseline_format = 'compact_v1'
      and transition.baseline_digest = p_archive_digest
      and transition.state in ('uploading_baseline', 'verifying')
      and transition.committed_at is null
  ) then
    raise exception using errcode = '42501',
      message = 'compact_checkpoint_registration_denied';
  end if;

  if not exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'farm-checkpoints'
      and object.name = p_storage_path
      and coalesce(
        nullif(object.metadata->>'size', '')::bigint,
        p_archive_byte_count
      ) = p_archive_byte_count
  ) then
    raise exception using errcode = '23503',
      message = 'compact_checkpoint_object_missing';
  end if;

  insert into public.farm_checkpoints (
    checkpoint_id, farm_id, migration_id, authority_generation,
    through_revision, manifest, manifest_digest, storage_path,
    operation_count, entity_count, tombstone_count, asset_count,
    checkpoint_format, archive_digest, archive_byte_count,
    history_operation_count, tombstone_history_count, created_by
  ) values (
    p_checkpoint_id, p_farm_id, p_migration_id, p_authority_generation,
    0, p_manifest, p_archive_digest, p_storage_path,
    0, p_projection_count, p_tombstone_projection_count, p_asset_count,
    'compact_v1', p_archive_digest, p_archive_byte_count,
    p_history_operation_count, p_tombstone_history_count, v_user_id
  )
  on conflict on constraint farm_checkpoints_pkey do nothing;

  select * into v_checkpoint
  from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id;

  if v_checkpoint.farm_id <> p_farm_id
    or v_checkpoint.migration_id <> p_migration_id
    or v_checkpoint.authority_generation <> p_authority_generation
    or v_checkpoint.checkpoint_format <> 'compact_v1'
    or v_checkpoint.archive_digest <> p_archive_digest
    or v_checkpoint.archive_byte_count <> p_archive_byte_count
    or v_checkpoint.storage_path <> p_storage_path
    or v_checkpoint.operation_count <> 0
    or v_checkpoint.entity_count <> p_projection_count
    or v_checkpoint.tombstone_count <> p_tombstone_projection_count
    or v_checkpoint.tombstone_history_count <> p_tombstone_history_count
    or v_checkpoint.history_operation_count <> p_history_operation_count
    or v_checkpoint.asset_count <> p_asset_count
  then
    raise exception using errcode = '23505',
      message = 'compact_checkpoint_id_payload_mismatch';
  end if;

  update public.authority_transitions
  set state = 'verifying', updated_at = now()
  where authority_transitions.migration_id = p_migration_id
    and authority_transitions.state in ('uploading_baseline', 'verifying');

  return query select
    v_checkpoint.checkpoint_id,
    v_checkpoint.archive_digest,
    v_checkpoint.verified_at is not null;
end;
$$;

revoke all on function public.register_compact_farm_checkpoint(
  uuid, uuid, uuid, integer, text, bigint, text, jsonb,
  bigint, bigint, bigint, bigint, bigint
) from public, anon;
grant execute on function public.register_compact_farm_checkpoint(
  uuid, uuid, uuid, integer, text, bigint, text, jsonb,
  bigint, bigint, bigint, bigint, bigint
) to authenticated;
