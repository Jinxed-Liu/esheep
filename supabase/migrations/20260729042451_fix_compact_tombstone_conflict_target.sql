-- The compact baseline function returns a column named `entity_type`.
-- In PL/pgSQL that output variable made the column-list conflict target
-- ambiguous the first time a deleted projection entered the tombstone path.
-- Naming the primary-key constraint removes the ambiguity without changing
-- the function contract or any staged data.
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
      on conflict on constraint farm_tombstones_pkey do update set
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
