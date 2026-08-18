alter table public.farm_checkpoints
  add column if not exists migration_id uuid
  references public.authority_transitions(migration_id);

create index if not exists farm_checkpoints_latest_generation_idx
  on public.farm_checkpoints (farm_id, authority_generation, created_at desc);

create or replace function public.stage_farm_baseline_batch(
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
  v_account_id uuid;
  v_registry public.farm_registry%rowtype;
  v_item jsonb;
  v_payload jsonb;
  v_kind text;
  v_count integer;
  v_sequence bigint;
  v_operation_id uuid;
  v_server_revision bigint;
  v_received_at timestamptz;
  v_existing public.farm_operations%rowtype;
  v_deleted_at timestamptz;
begin
  if v_user_id is null then
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

  select * into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if not found
    or v_registry.owner_user_id <> v_user_id
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'preparing'
    or v_registry.authority_generation <> p_authority_generation
    or not exists (
      select 1
      from public.authority_transitions transition
      where transition.migration_id = p_migration_id
        and transition.farm_id = p_farm_id
        and transition.target_generation = p_authority_generation
        and transition.initiated_by = v_user_id
        and transition.state in ('preparing', 'uploading_baseline')
    )
  then
    raise exception using errcode = '42501', message = 'baseline_staging_denied';
  end if;

  select profile.app_account_id into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  update public.authority_transitions
  set state = 'uploading_baseline', updated_at = now()
  where migration_id = p_migration_id
    and state in ('preparing', 'uploading_baseline');

  for v_item in
    select value
    from jsonb_array_elements(p_operations)
    order by (value->>'client_sequence')::bigint
  loop
    v_operation_id := (v_item->>'operation_id')::uuid;
    v_sequence := (v_item->>'client_sequence')::bigint;
    v_deleted_at := nullif(v_item->>'deleted_at', '')::timestamptz;

    if v_sequence < 1
      or (v_item->>'payload_digest') !~ '^[0-9a-f]{64}$'
      or encode(
        extensions.digest(decode(v_item->>'payload_base64', 'base64'), 'sha256'),
        'hex'
      ) <> v_item->>'payload_digest'
    then
      raise exception using errcode = '22023', message = 'invalid_baseline_operation';
    end if;

    begin
      v_payload := convert_from(
        decode(v_item->>'payload_base64', 'base64'),
        'utf8'
      )::jsonb;
    exception when others then
      raise exception using errcode = '22023', message = 'invalid_baseline_payload';
    end;
    v_kind := v_payload->>'kind';

    if v_kind = 'bootstrapEntity' then
      if (v_item->>'base_revision')::integer <> 0
        or (v_item->>'resulting_revision')::integer < 1
        or v_item->>'capability_certificate'
          <> 'supabase-authenticated-owner-baseline'
      then
        raise exception using errcode = '22023',
          message = 'bootstrap_revision_invalid';
      end if;
    elsif (v_item->>'resulting_revision')::integer
      <> (v_item->>'base_revision')::integer + 1
    then
      raise exception using errcode = '22023',
        message = 'baseline_history_revision_invalid';
    end if;

    if (v_item->>'modified_by_account_id')::uuid <> v_account_id
      or not exists (
        select 1
        from public.devices device
        where device.device_id = (v_item->>'modified_by_device_id')::uuid
          and device.user_id = v_user_id
          and device.status = 'active'
      )
    then
      raise exception using errcode = '42501',
        message = 'baseline_operation_identity_mismatch';
    end if;
    if v_item->>'entity_type' like 'tmr%'
      and not exists (
        select 1
        from public.devices device
        where device.device_id = (v_item->>'modified_by_device_id')::uuid
          and device.user_id = v_user_id
          and device.status = 'active'
          and coalesce(device.tmr_data_protocol_version, 0) >= 1
      )
    then
      raise exception using errcode = '55000',
        message = 'tmr_client_upgrade_required';
    end if;

    select * into v_existing
    from public.farm_operations existing
    where existing.operation_id = v_operation_id;

    if found then
      if v_existing.farm_id <> p_farm_id
        or v_existing.authority_generation <> p_authority_generation
        or v_existing.client_sequence <> v_sequence
        or v_existing.entity_type <> v_item->>'entity_type'
        or v_existing.entity_id <> (v_item->>'entity_id')::uuid
        or v_existing.base_revision <> (v_item->>'base_revision')::integer
        or v_existing.resulting_revision
          <> (v_item->>'resulting_revision')::integer
        or v_existing.payload_base64 <> v_item->>'payload_base64'
        or v_existing.payload_digest <> v_item->>'payload_digest'
        or v_existing.modified_by_account_id
          <> (v_item->>'modified_by_account_id')::uuid
        or v_existing.modified_by_device_id
          <> (v_item->>'modified_by_device_id')::uuid
        or v_existing.deleted_at is distinct from v_deleted_at
        or not v_existing.is_staged
      then
        raise exception using errcode = '23505',
          message = 'operation_id_payload_mismatch';
      end if;
      operation_id := v_existing.operation_id;
      revision := v_existing.revision;
      server_received_at := v_existing.server_received_at;
      result_status := 'accepted';
      error_code := null;
      return next;
      continue;
    end if;

    v_server_revision := v_registry.current_revision + 1;
    v_received_at := now();

    insert into public.farm_operations (
      operation_id, farm_id, authority_generation, client_sequence,
      is_staged, revision, base_revision, resulting_revision,
      schema_version, entity_type, entity_id, actor_user_id,
      modified_by_account_id, modified_by_device_id, payload_base64,
      payload_digest, capability_certificate, operation_signature,
      deleted_at, occurred_at, modified_at, server_received_at
    ) values (
      v_operation_id, p_farm_id, p_authority_generation, v_sequence,
      true, v_server_revision, (v_item->>'base_revision')::integer,
      (v_item->>'resulting_revision')::integer,
      (v_item->>'schema_version')::integer, v_item->>'entity_type',
      (v_item->>'entity_id')::uuid, v_user_id,
      (v_item->>'modified_by_account_id')::uuid,
      (v_item->>'modified_by_device_id')::uuid,
      v_item->>'payload_base64', v_item->>'payload_digest',
      v_item->>'capability_certificate', v_item->>'operation_signature',
      v_deleted_at, (v_item->>'occurred_at')::timestamptz,
      (v_item->>'modified_at')::timestamptz, v_received_at
    );

    insert into public.farm_entities (
      farm_id, entity_type, entity_id, authority_generation, revision,
      operation_id, payload_base64, payload_digest, modified_by,
      modified_at, deleted_at
    ) values (
      p_farm_id, v_item->>'entity_type', (v_item->>'entity_id')::uuid,
      p_authority_generation, (v_item->>'resulting_revision')::integer,
      v_operation_id, v_item->>'payload_base64',
      v_item->>'payload_digest', v_user_id,
      (v_item->>'modified_at')::timestamptz, v_deleted_at
    )
    on conflict (farm_id, entity_type, entity_id) do update set
      authority_generation = excluded.authority_generation,
      revision = excluded.revision,
      operation_id = excluded.operation_id,
      payload_base64 = excluded.payload_base64,
      payload_digest = excluded.payload_digest,
      modified_by = excluded.modified_by,
      modified_at = excluded.modified_at,
      deleted_at = excluded.deleted_at;

    if v_deleted_at is not null then
      insert into public.farm_tombstones (
        farm_id, entity_type, entity_id, authority_generation, revision,
        operation_id, deleted_by, deleted_at, reason
      ) values (
        p_farm_id, v_item->>'entity_type', (v_item->>'entity_id')::uuid,
        p_authority_generation, (v_item->>'resulting_revision')::integer,
        v_operation_id, v_user_id, v_deleted_at,
        left(coalesce(v_payload->'strings'->>'reason', ''), 500)
      )
      on conflict (farm_id, entity_type, entity_id) do update set
        authority_generation = excluded.authority_generation,
        revision = excluded.revision,
        operation_id = excluded.operation_id,
        deleted_by = excluded.deleted_by,
        deleted_at = excluded.deleted_at,
        reason = excluded.reason;
    else
      delete from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
        and tombstone.entity_type = v_item->>'entity_type'
        and tombstone.entity_id = (v_item->>'entity_id')::uuid;
    end if;

    update public.farm_registry
    set current_revision = v_server_revision, updated_at = v_received_at
    where farm_registry.farm_id = p_farm_id
    returning * into v_registry;

    operation_id := v_operation_id;
    revision := v_server_revision;
    server_received_at := v_received_at;
    result_status := 'accepted';
    error_code := null;
    return next;
  end loop;
end;
$$;

revoke all on function public.stage_farm_baseline_batch(
  uuid, uuid, integer, jsonb
) from public, anon;
grant execute on function public.stage_farm_baseline_batch(
  uuid, uuid, integer, jsonb
) to authenticated;

create or replace function public.get_farm_authority_transition_status(
  p_farm_id uuid,
  p_migration_id uuid
)
returns table (
  migration_id uuid,
  farm_id uuid,
  authority_generation integer,
  status text,
  staged_operation_count bigint,
  staged_asset_count bigint,
  current_revision bigint,
  checkpoint_id uuid
)
language sql
security definer
set search_path = ''
stable
as $$
  select transition.migration_id, registry.farm_id,
    registry.authority_generation, transition.state,
    (
      select count(*) from public.farm_operations operation
      where operation.farm_id = registry.farm_id
        and operation.authority_generation = transition.target_generation
        and operation.is_staged
    ),
    (
      select count(*) from public.farm_assets asset
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
      order by checkpoint.created_at desc
      limit 1
    )
  from public.authority_transitions transition
  join public.farm_registry registry on registry.farm_id = transition.farm_id
  where transition.migration_id = p_migration_id
    and transition.farm_id = p_farm_id
    and registry.owner_user_id = (select auth.uid());
$$;

revoke all on function public.get_farm_authority_transition_status(
  uuid, uuid
) from public, anon;
grant execute on function public.get_farm_authority_transition_status(
  uuid, uuid
) to authenticated;

create or replace function public.abort_farm_authority_transition(
  p_farm_id uuid,
  p_migration_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
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
      and registry.status = 'preparing'
      and transition.migration_id = p_migration_id
      and transition.initiated_by = v_user_id
      and transition.state in (
        'preparing', 'uploading_baseline', 'verifying', 'failed'
      )
      and transition.committed_at is null
  ) then
    raise exception using errcode = '55000',
      message = 'authority_transition_not_abortable';
  end if;

  delete from public.farm_registry registry
  where registry.farm_id = p_farm_id
    and registry.owner_user_id = v_user_id
    and registry.status = 'preparing';
end;
$$;

revoke all on function public.abort_farm_authority_transition(
  uuid, uuid
) from public, anon;
grant execute on function public.abort_farm_authority_transition(
  uuid, uuid
) to authenticated;

-- Baseline assets are uploaded before the registry becomes active. Only the
-- initiating owner of the matching preparing transition may register them.
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
  v_asset public.farm_assets%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$'
    or p_byte_count < 0
    or p_storage_path <> lower(p_farm_id::text) || '/' || p_sha256
  then
    raise exception using errcode = '22023', message = 'invalid_asset_manifest';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_farm_id::text, 0));
  select * into v_registry from public.farm_registry registry
  where registry.farm_id = p_farm_id for update;

  if not found
    or v_registry.provider <> 'supabase'
    or v_registry.authority_generation <> p_authority_generation
    or (
      v_registry.status = 'active'
      and not esheep_private.is_active_farm_member(
        p_farm_id, array['owner', 'administrator', 'worker']
      )
    )
    or (
      v_registry.status = 'preparing'
      and (
        v_registry.owner_user_id <> v_user_id
        or not exists (
          select 1 from public.authority_transitions transition
          where transition.farm_id = p_farm_id
            and transition.initiated_by = v_user_id
            and transition.target_generation = p_authority_generation
            and transition.state in ('preparing', 'uploading_baseline')
        )
      )
    )
    or v_registry.status not in ('preparing', 'active')
  then
    raise exception using errcode = '55000',
      message = 'farm_authority_not_writable';
  end if;

  if not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'farm-assets'
      and object.name = p_storage_path
  ) then
    raise exception using errcode = '23503', message = 'asset_object_missing';
  end if;

  insert into public.farm_assets (
    asset_id, farm_id, sha256, storage_path, byte_count, content_type,
    authority_generation, uploaded_by
  ) values (
    p_asset_id, p_farm_id, p_sha256, p_storage_path, p_byte_count,
    left(p_content_type, 160), p_authority_generation, v_user_id
  )
  on conflict (farm_id, sha256) do update set deleted_at = null
  returning * into v_asset;

  if v_asset.asset_id <> p_asset_id
    or v_asset.storage_path <> p_storage_path
    or v_asset.byte_count <> p_byte_count
  then
    raise exception using errcode = '23505',
      message = 'asset_digest_payload_mismatch';
  end if;
  return query select v_asset.asset_id, v_asset.storage_path;
end;
$$;

revoke all on function public.register_farm_asset(
  uuid, uuid, integer, text, text, bigint, text
) from public, anon;
grant execute on function public.register_farm_asset(
  uuid, uuid, integer, text, text, bigint, text
) to authenticated;

-- Record which transition owns the checkpoint without changing the public RPC
-- signature used by existing Development clients.
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
returns table (checkpoint_id uuid, manifest_digest text, verified boolean)
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
    or p_storage_path <> lower(p_farm_id::text) || '/' ||
      lower(p_migration_id::text) || '/' || p_manifest_digest || '.json'
    or least(
      p_operation_count, p_entity_count, p_tombstone_count, p_asset_count
    ) < 0
  then
    raise exception using errcode = '22023',
      message = 'invalid_checkpoint_manifest';
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
      and transition.state in ('uploading_baseline', 'verifying')
  ) then
    raise exception using errcode = '42501',
      message = 'checkpoint_registration_denied';
  end if;
  if not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'farm-checkpoints'
      and object.name = p_storage_path
  ) then
    raise exception using errcode = '23503',
      message = 'checkpoint_object_missing';
  end if;

  insert into public.farm_checkpoints (
    checkpoint_id, farm_id, migration_id, authority_generation,
    through_revision, manifest, manifest_digest, storage_path,
    operation_count, entity_count, tombstone_count, asset_count, created_by
  ) values (
    p_checkpoint_id, p_farm_id, p_migration_id, p_authority_generation,
    p_through_revision, p_manifest, p_manifest_digest, p_storage_path,
    p_operation_count, p_entity_count, p_tombstone_count, p_asset_count,
    v_user_id
  )
  on conflict (checkpoint_id) do nothing;

  select * into v_checkpoint from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id;
  if v_checkpoint.farm_id <> p_farm_id
    or v_checkpoint.migration_id <> p_migration_id
    or v_checkpoint.authority_generation <> p_authority_generation
    or v_checkpoint.through_revision <> p_through_revision
    or v_checkpoint.manifest_digest <> p_manifest_digest
    or v_checkpoint.storage_path <> p_storage_path
    or v_checkpoint.operation_count <> p_operation_count
    or v_checkpoint.entity_count <> p_entity_count
    or v_checkpoint.tombstone_count <> p_tombstone_count
    or v_checkpoint.asset_count <> p_asset_count
  then
    raise exception using errcode = '23505',
      message = 'checkpoint_id_payload_mismatch';
  end if;

  update public.authority_transitions
  set state = 'verifying', updated_at = now()
  where migration_id = p_migration_id
    and state in ('uploading_baseline', 'verifying');

  return query select v_checkpoint.checkpoint_id,
    v_checkpoint.manifest_digest, v_checkpoint.verified_at is not null;
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

-- Replace the previous idempotent wrapper. It retains idempotency and adds
-- asset/count verification before the one-way authority commit.
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
  select * into v_registry from public.farm_registry registry
  where registry.farm_id = p_farm_id for update;
  select * into v_checkpoint from public.farm_checkpoints checkpoint
  where checkpoint.checkpoint_id = p_checkpoint_id
    and checkpoint.farm_id = p_farm_id;

  if v_registry.owner_user_id = v_user_id
    and v_registry.provider = 'supabase'
    and v_registry.status = 'active'
    and v_registry.authority_generation = p_expected_generation
    and v_checkpoint.migration_id = p_migration_id
    and v_checkpoint.manifest_digest = p_manifest_digest
    and v_checkpoint.verified_at is not null
  then
    return query select v_registry.farm_id,
      v_registry.authority_generation, v_registry.current_revision,
      v_registry.status;
    return;
  end if;

  if v_registry.owner_user_id <> v_user_id
    or v_registry.provider <> 'supabase'
    or v_registry.status <> 'preparing'
    or v_registry.authority_generation <> p_expected_generation
    or v_checkpoint.migration_id <> p_migration_id
    or v_checkpoint.authority_generation <> p_expected_generation
    or v_checkpoint.manifest_digest <> p_manifest_digest
    or not exists (
      select 1 from public.authority_transitions transition
      where transition.migration_id = p_migration_id
        and transition.farm_id = p_farm_id
        and transition.target_generation = p_expected_generation
        and transition.state = 'verifying'
        and transition.committed_at is null
    )
  then
    raise exception using errcode = '42501', message = 'farm_activation_denied';
  end if;

  if (
    select count(*) from public.farm_operations operation
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
      select count(*) from public.farm_entities entity
      where entity.farm_id = p_farm_id
        and entity.authority_generation = p_expected_generation
    ) <> v_checkpoint.entity_count
    or (
      select count(*) from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
        and tombstone.authority_generation = p_expected_generation
    ) <> v_checkpoint.tombstone_count
    or (
      select count(*) from public.farm_assets asset
      where asset.farm_id = p_farm_id
        and asset.authority_generation = p_expected_generation
        and asset.deleted_at is null
    ) <> v_checkpoint.asset_count
  then
    raise exception using errcode = '23514',
      message = 'checkpoint_projection_mismatch';
  end if;

  update public.farm_checkpoints set verified_at = now()
  where checkpoint_id = p_checkpoint_id;
  update public.farm_registry set status = 'active', updated_at = now()
  where farm_registry.farm_id = p_farm_id returning * into v_registry;
  update public.authority_transitions
  set state = 'draining', committed_at = now(), updated_at = now()
  where migration_id = p_migration_id;

  return query select v_registry.farm_id,
    v_registry.authority_generation, v_registry.current_revision,
    v_registry.status;
end;
$$;

revoke all on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) from public, anon;
grant execute on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) to authenticated;
