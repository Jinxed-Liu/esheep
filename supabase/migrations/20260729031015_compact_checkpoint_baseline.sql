-- Compact initial authority:
--   * the checkpoint archive owns the complete original history;
--   * farm_entities stores one JSONB projection per current entity;
--   * farm_operations starts at revision zero and contains only real commands
--     produced after authority activation.
--
-- This migration is additive so the already-deployed legacy baseline RPC
-- remains readable while Development clients move to compact_v1.

alter table public.authority_transitions
  add column if not exists baseline_format text not null default 'legacy_v2'
    check (baseline_format in ('legacy_v2', 'compact_v1')),
  add column if not exists baseline_digest text
    check (
      baseline_digest is null
      or baseline_digest ~ '^[0-9a-f]{64}$'
    );

alter table public.farm_entities
  alter column operation_id drop not null,
  alter column payload_base64 drop not null,
  add column if not exists payload_json jsonb,
  add column if not exists baseline_migration_id uuid
    references public.authority_transitions(migration_id) on delete cascade;

alter table public.farm_entities
  drop constraint if exists farm_entities_payload_available_check,
  add constraint farm_entities_payload_available_check
    check (payload_base64 is not null or payload_json is not null),
  drop constraint if exists farm_entities_projection_origin_check,
  add constraint farm_entities_projection_origin_check
    check (
      operation_id is not null
      or baseline_migration_id is not null
    );

alter table public.farm_tombstones
  alter column operation_id drop not null,
  add column if not exists baseline_migration_id uuid
    references public.authority_transitions(migration_id) on delete cascade;

alter table public.farm_tombstones
  drop constraint if exists farm_tombstones_projection_origin_check,
  add constraint farm_tombstones_projection_origin_check
    check (
      operation_id is not null
      or baseline_migration_id is not null
    );

alter table public.farm_checkpoints
  add column if not exists checkpoint_format text not null default 'legacy_v2'
    check (checkpoint_format in ('legacy_v2', 'compact_v1')),
  add column if not exists archive_digest text
    check (
      archive_digest is null
      or archive_digest ~ '^[0-9a-f]{64}$'
    ),
  add column if not exists archive_byte_count bigint
    check (archive_byte_count is null or archive_byte_count > 0),
  add column if not exists history_operation_count bigint not null default 0
    check (history_operation_count >= 0),
  add column if not exists tombstone_history_count bigint not null default 0
    check (tombstone_history_count >= 0);

create index if not exists farm_entities_baseline_migration_idx
  on public.farm_entities (baseline_migration_id)
  where baseline_migration_id is not null;

create index if not exists farm_tombstones_baseline_migration_idx
  on public.farm_tombstones (baseline_migration_id)
  where baseline_migration_id is not null;

create index if not exists farm_checkpoints_compact_latest_idx
  on public.farm_checkpoints (
    farm_id, authority_generation, created_at desc
  )
  where checkpoint_format = 'compact_v1';

-- A real operation supersedes the checkpoint projection for that entity.
-- Clearing the JSONB copy prevents payload accumulation after normal edits.
create or replace function esheep_private.normalize_farm_entity_projection()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.operation_id is not null then
    new.payload_json := null;
    new.baseline_migration_id := null;
  elsif new.baseline_migration_id is not null then
    new.payload_base64 := null;
  end if;
  return new;
end;
$$;

drop trigger if exists normalize_farm_entity_projection
  on public.farm_entities;
create trigger normalize_farm_entity_projection
before insert or update on public.farm_entities
for each row execute function
  esheep_private.normalize_farm_entity_projection();

create or replace function esheep_private.normalize_farm_tombstone_projection()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.operation_id is not null then
    new.baseline_migration_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists normalize_farm_tombstone_projection
  on public.farm_tombstones;
create trigger normalize_farm_tombstone_projection
before insert or update on public.farm_tombstones
for each row execute function
  esheep_private.normalize_farm_tombstone_projection();

revoke all on function
  esheep_private.normalize_farm_entity_projection()
  from public, anon, authenticated;
revoke all on function
  esheep_private.normalize_farm_tombstone_projection()
  from public, anon, authenticated;

create or replace function public.begin_compact_farm_authority_transition(
  p_farm_id uuid,
  p_migration_id uuid,
  p_source_provider text,
  p_target_generation integer,
  p_archive_digest text
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
  v_transition public.authority_transitions%rowtype;
  v_registry public.farm_registry%rowtype;
begin
  if (select auth.uid()) is null then
    raise exception using errcode = '42501',
      message = 'authentication_required';
  end if;
  if p_archive_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023',
      message = 'invalid_compact_archive_digest';
  end if;

  perform *
  from public.begin_farm_authority_transition(
    p_farm_id,
    p_migration_id,
    p_source_provider,
    p_target_generation,
    0,
    p_archive_digest
  );

  select * into v_transition
  from public.authority_transitions transition
  where transition.migration_id = p_migration_id
  for update;

  if v_transition.initiated_by <> (select auth.uid())
    or v_transition.farm_id <> p_farm_id
    or v_transition.target_generation <> p_target_generation
    or (
      v_transition.baseline_format <> 'legacy_v2'
      and v_transition.baseline_format <> 'compact_v1'
    )
    or (
      v_transition.baseline_digest is not null
      and v_transition.baseline_digest <> p_archive_digest
    )
  then
    raise exception using errcode = '23505',
      message = 'compact_transition_payload_mismatch';
  end if;

  update public.authority_transitions
  set baseline_format = 'compact_v1',
      baseline_digest = p_archive_digest,
      baseline_revision = 0,
      updated_at = now()
  where authority_transitions.migration_id = p_migration_id;

  select * into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id;

  return query select
    p_migration_id,
    v_registry.authority_generation,
    v_registry.status;
end;
$$;

revoke all on function public.begin_compact_farm_authority_transition(
  uuid, uuid, text, integer, text
) from public, anon;
grant execute on function public.begin_compact_farm_authority_transition(
  uuid, uuid, text, integer, text
) to authenticated;

create or replace function public.stage_farm_projection_batch(
  p_farm_id uuid,
  p_migration_id uuid,
  p_authority_generation integer,
  p_projections jsonb
)
returns table (
  entity_type text,
  entity_id uuid,
  result_status text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_transition public.authority_transitions%rowtype;
  v_item jsonb;
  v_payload jsonb;
  v_payload_bytes bytea;
  v_entity_type text;
  v_entity_id uuid;
  v_revision integer;
  v_deleted_at timestamptz;
  v_existing public.farm_entities%rowtype;
  v_count integer;
begin
  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'authentication_required';
  end if;
  if jsonb_typeof(p_projections) <> 'array' then
    raise exception using errcode = '22023',
      message = 'projections_must_be_array';
  end if;
  v_count := jsonb_array_length(p_projections);
  if v_count < 1 or v_count > 100 then
    raise exception using errcode = '22023',
      message = 'projection_batch_size_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));
  select transition.* into v_transition
  from public.authority_transitions transition
  join public.farm_registry registry
    on registry.farm_id = transition.farm_id
  where transition.migration_id = p_migration_id
    and transition.farm_id = p_farm_id
    and transition.target_generation = p_authority_generation
    and transition.initiated_by = v_user_id
    and transition.baseline_format = 'compact_v1'
    and transition.state in ('preparing', 'uploading_baseline')
    and transition.committed_at is null
    and registry.owner_user_id = v_user_id
    and registry.provider = 'supabase'
    and registry.status = 'preparing'
  for update of transition;

  if not found then
    raise exception using errcode = '42501',
      message = 'compact_projection_staging_denied';
  end if;
  if not exists (
    select 1
    from public.entitlements entitlement
    where entitlement.owner_user_id = v_user_id
      and entitlement.state in ('active', 'grace_period', 'billing_retry')
      and (
        entitlement.valid_until is null
        or entitlement.valid_until > now()
        or entitlement.grace_until > now()
      )
  ) then
    raise exception using errcode = '42501',
      message = 'owner_supabase_entitlement_required';
  end if;

  update public.authority_transitions
  set state = 'uploading_baseline', updated_at = now()
  where authority_transitions.migration_id = p_migration_id
    and authority_transitions.state in ('preparing', 'uploading_baseline');

  for v_item in
    select value
    from jsonb_array_elements(p_projections)
    order by
      (value->>'replay_order')::integer,
      value->>'entity_type',
      value->>'entity_id'
  loop
    v_entity_type := nullif(v_item->>'entity_type', '');
    v_entity_id := (v_item->>'entity_id')::uuid;
    v_revision := (v_item->>'revision')::integer;
    v_deleted_at := nullif(v_item->>'deleted_at', '')::timestamptz;
    v_payload_bytes := decode(v_item->>'payload_base64', 'base64');

    if v_entity_type is null
      or v_revision < 1
      or (v_item->>'payload_digest') !~ '^[0-9a-f]{64}$'
      or encode(
        extensions.digest(v_payload_bytes, 'sha256'),
        'hex'
      ) <> v_item->>'payload_digest'
    then
      raise exception using errcode = '22023',
        message = 'invalid_compact_projection';
    end if;
    begin
      v_payload := convert_from(v_payload_bytes, 'utf8')::jsonb;
    exception when others then
      raise exception using errcode = '22023',
        message = 'invalid_compact_projection_payload';
    end;

    select * into v_existing
    from public.farm_entities existing
    where existing.farm_id = p_farm_id
      and existing.entity_type = v_entity_type
      and existing.entity_id = v_entity_id;

    if found then
      if v_existing.baseline_migration_id is distinct from p_migration_id
        or v_existing.authority_generation <> p_authority_generation
        or v_existing.revision <> v_revision
        or v_existing.payload_digest <> v_item->>'payload_digest'
        or v_existing.payload_json is distinct from v_payload
        or v_existing.deleted_at is distinct from v_deleted_at
      then
        raise exception using errcode = '23505',
          message = 'compact_projection_id_payload_mismatch';
      end if;
    else
      insert into public.farm_entities (
        farm_id, entity_type, entity_id, authority_generation, revision,
        operation_id, payload_base64, payload_json, payload_digest,
        baseline_migration_id, modified_by, modified_at, deleted_at
      ) values (
        p_farm_id, v_entity_type, v_entity_id, p_authority_generation,
        v_revision, null, null, v_payload, v_item->>'payload_digest',
        p_migration_id, v_user_id,
        (v_item->>'modified_at')::timestamptz, v_deleted_at
      );
    end if;

    if v_deleted_at is not null then
      insert into public.farm_tombstones (
        farm_id, entity_type, entity_id, authority_generation, revision,
        operation_id, baseline_migration_id, deleted_by, deleted_at, reason
      ) values (
        p_farm_id, v_entity_type, v_entity_id, p_authority_generation,
        v_revision, null, p_migration_id, v_user_id, v_deleted_at,
        left(coalesce(v_payload->'strings'->>'reason', ''), 500)
      )
      on conflict (farm_id, entity_type, entity_id) do update set
        authority_generation = excluded.authority_generation,
        revision = excluded.revision,
        operation_id = null,
        baseline_migration_id = excluded.baseline_migration_id,
        deleted_by = excluded.deleted_by,
        deleted_at = excluded.deleted_at,
        reason = excluded.reason;
    else
      delete from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
        and tombstone.entity_type = v_entity_type
        and tombstone.entity_id = v_entity_id
        and tombstone.baseline_migration_id = p_migration_id;
    end if;

    entity_type := v_entity_type;
    entity_id := v_entity_id;
    result_status := 'accepted';
    return next;
  end loop;
end;
$$;

revoke all on function public.stage_farm_projection_batch(
  uuid, uuid, integer, jsonb
) from public, anon;
grant execute on function public.stage_farm_projection_batch(
  uuid, uuid, integer, jsonb
) to authenticated;

create or replace function public.get_compact_authority_transition_status(
  p_farm_id uuid,
  p_migration_id uuid
)
returns table (
  migration_id uuid,
  farm_id uuid,
  authority_generation integer,
  status text,
  staged_projection_count bigint,
  staged_tombstone_count bigint,
  staged_asset_count bigint,
  current_revision bigint,
  checkpoint_id uuid
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    transition.migration_id,
    registry.farm_id,
    registry.authority_generation,
    transition.state,
    (
      select count(*)
      from public.farm_entities entity
      where entity.farm_id = registry.farm_id
        and entity.authority_generation = transition.target_generation
        and entity.baseline_migration_id = transition.migration_id
    ),
    (
      select count(*)
      from public.farm_tombstones tombstone
      where tombstone.farm_id = registry.farm_id
        and tombstone.authority_generation = transition.target_generation
        and tombstone.baseline_migration_id = transition.migration_id
    ),
    (
      select count(*)
      from public.farm_assets asset
      where asset.farm_id = registry.farm_id
        and asset.authority_generation = transition.target_generation
        and asset.deleted_at is null
    ),
    registry.current_revision,
    (
      select checkpoint.checkpoint_id
      from public.farm_checkpoints checkpoint
      where checkpoint.farm_id = registry.farm_id
        and checkpoint.migration_id = transition.migration_id
        and checkpoint.checkpoint_format = 'compact_v1'
      order by checkpoint.created_at desc
      limit 1
    )
  from public.authority_transitions transition
  join public.farm_registry registry
    on registry.farm_id = transition.farm_id
  where transition.migration_id = p_migration_id
    and transition.farm_id = p_farm_id
    and transition.initiated_by = (select auth.uid())
    and registry.owner_user_id = (select auth.uid())
    and transition.baseline_format = 'compact_v1';
$$;

revoke all on function public.get_compact_authority_transition_status(
  uuid, uuid
) from public, anon;
grant execute on function public.get_compact_authority_transition_status(
  uuid, uuid
) to authenticated;

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
  on conflict (checkpoint_id) do nothing;

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

create or replace function public.verify_and_activate_compact_farm_authority(
  p_farm_id uuid,
  p_migration_id uuid,
  p_checkpoint_id uuid,
  p_expected_generation integer,
  p_archive_digest text
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
  v_transition public.authority_transitions%rowtype;
  v_checkpoint public.farm_checkpoints%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501',
      message = 'authentication_required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));

  select * into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;
  select * into v_transition
  from public.authority_transitions transition
  where transition.migration_id = p_migration_id
    and transition.farm_id = p_farm_id;
  select * into v_checkpoint
  from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id
    and checkpoint.farm_id = p_farm_id;

  if v_registry.owner_user_id = v_user_id
    and v_registry.provider = 'supabase'
    and v_registry.status = 'active'
    and v_registry.authority_generation = p_expected_generation
    and v_transition.baseline_format = 'compact_v1'
    and v_transition.baseline_digest = p_archive_digest
    and v_transition.state in ('draining', 'archiving_source', 'completed')
    and v_checkpoint.checkpoint_format = 'compact_v1'
    and v_checkpoint.archive_digest = p_archive_digest
    and v_checkpoint.verified_at is not null
  then
    return query select
      v_registry.farm_id,
      v_registry.authority_generation,
      v_registry.current_revision,
      v_registry.status;
    return;
  end if;

  if v_registry.owner_user_id <> v_user_id
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'preparing'
    or v_registry.authority_generation <> p_expected_generation
    or v_transition.initiated_by <> v_user_id
    or v_transition.target_generation <> p_expected_generation
    or v_transition.state <> 'verifying'
    or v_transition.committed_at is not null
    or v_transition.baseline_format <> 'compact_v1'
    or v_transition.baseline_digest <> p_archive_digest
    or v_checkpoint.migration_id <> p_migration_id
    or v_checkpoint.authority_generation <> p_expected_generation
    or v_checkpoint.checkpoint_format <> 'compact_v1'
    or v_checkpoint.archive_digest <> p_archive_digest
  then
    raise exception using errcode = '42501',
      message = 'compact_farm_activation_denied';
  end if;

  if (
    select count(*)
    from public.farm_operations operation
    where operation.farm_id = p_farm_id
      and operation.authority_generation = p_expected_generation
  ) <> 0
    or (
      select count(*)
      from public.farm_entities entity
      where entity.farm_id = p_farm_id
        and entity.authority_generation = p_expected_generation
        and entity.baseline_migration_id = p_migration_id
    ) <> v_checkpoint.entity_count
    or (
      select count(*)
      from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
        and tombstone.authority_generation = p_expected_generation
        and tombstone.baseline_migration_id = p_migration_id
    ) <> v_checkpoint.tombstone_count
    or (
      select count(*)
      from public.farm_assets asset
      where asset.farm_id = p_farm_id
        and asset.authority_generation = p_expected_generation
        and asset.deleted_at is null
    ) <> v_checkpoint.asset_count
    or not exists (
      select 1
      from storage.objects object
      where object.bucket_id = 'farm-checkpoints'
        and object.name = v_checkpoint.storage_path
        and coalesce(
          nullif(object.metadata->>'size', '')::bigint,
          v_checkpoint.archive_byte_count
        ) = v_checkpoint.archive_byte_count
    )
  then
    raise exception using errcode = '23514',
      message = 'compact_checkpoint_projection_mismatch';
  end if;

  update public.farm_checkpoints
  set verified_at = now()
  where farm_checkpoints.checkpoint_id = p_checkpoint_id;

  update public.farm_registry
  set status = 'active',
      current_revision = 0,
      updated_at = now()
  where farm_registry.farm_id = p_farm_id
  returning * into v_registry;

  update public.authority_transitions
  set state = 'draining',
      committed_at = now(),
      updated_at = now()
  where authority_transitions.migration_id = p_migration_id;

  return query select
    v_registry.farm_id,
    v_registry.authority_generation,
    v_registry.current_revision,
    v_registry.status;
end;
$$;

revoke all on function public.verify_and_activate_compact_farm_authority(
  uuid, uuid, uuid, integer, text
) from public, anon;
grant execute on function public.verify_and_activate_compact_farm_authority(
  uuid, uuid, uuid, integer, text
) to authenticated;

-- Direct table writes remain forbidden. The new surface is RPC-only.
revoke insert, update, delete, truncate, references, trigger
  on public.farm_entities from authenticated, anon;
revoke insert, update, delete, truncate, references, trigger
  on public.farm_tombstones from authenticated, anon;
revoke insert, update, delete, truncate, references, trigger
  on public.farm_checkpoints from authenticated, anon;
