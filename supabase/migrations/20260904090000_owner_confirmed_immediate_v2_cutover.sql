-- The normal cut-over RPC remains receipt-gated.  This separate, explicit
-- owner-confirmed path exists for the real-farm decision to switch authority
-- before the two physical devices are visually exercised.  It never invents
-- device receipts or changes the parity facts: the audit report records that
-- physical acceptance is still pending and that this was an owner-directed
-- immediate cut-over.

alter table esheep_cloud.migration_reconciliations
  add column if not exists cutover_mode text not null default 'standard'
    check (cutover_mode in ('standard', 'owner_confirmed_immediate'));

alter table esheep_cloud.migration_reconciliations
  add column if not exists owner_confirmation text;

alter table esheep_cloud.migration_reconciliations
  add column if not exists owner_confirmation_user_id uuid
    references auth.users(id);

alter table esheep_cloud.migration_reconciliations
  add column if not exists owner_confirmation_at timestamptz;

create or replace function public.esheep_cloud_cut_over_farm_v2_owner_confirmed(
  p_farm_id uuid,
  p_expected_source_generation integer,
  p_expected_parity_digest text,
  p_owner_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_registry public.farm_registry%rowtype;
  v_migration esheep_cloud.migration_reconciliations%rowtype;
  v_state esheep_cloud.farm_state%rowtype;
  v_integrity_report jsonb;
  v_owner_user_id uuid := auth.uid();
  v_cutover_at timestamptz := clock_timestamp();
  v_confirmation text := '本人确认：以 iPhone Air 为唯一源，立即切换 Cloud V2 权威，设备验收在切换后进行';
begin
  if not esheep_private.is_active_farm_member(p_farm_id, array['owner']) then
    raise exception using errcode = '42501', message = 'esheep_cloud_owner_required';
  end if;
  if p_owner_confirmation is distinct from v_confirmation then
    raise exception using errcode = '22023', message = 'esheep_cloud_owner_confirmation_invalid';
  end if;
  if p_expected_source_generation < 0
     or p_expected_parity_digest is null
     or lower(p_expected_parity_digest) !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'esheep_cloud_cutover_argument_invalid';
  end if;

  perform esheep_cloud.assert_protocol_ready_v2();

  select * into v_registry
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;
  select * into v_migration
  from esheep_cloud.migration_reconciliations migration
  where migration.farm_id = p_farm_id
  for update;
  select * into v_state
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id
  for update;

  -- A retry after a successful transaction is a read of the durable receipt,
  -- not a second generation change.
  if v_registry.provider = 'esheep_cloud'
     and v_migration.status = 'cut_over'
     and v_migration.cutover_mode = 'owner_confirmed_immediate' then
    return jsonb_build_object(
      'farm_id', p_farm_id,
      'farm_generation', v_migration.target_generation,
      'provider', 'eSheepCloud',
      'status', 'active',
      'idempotent', true,
      'cutover_mode', v_migration.cutover_mode,
      'pending_device_acceptance', true,
      'cut_over_at', v_migration.cut_over_at
    );
  end if;

  if v_registry.farm_id is null
     or v_migration.farm_id is null
     or v_state.farm_id is null
     or v_registry.provider <> 'supabase'
     or v_registry.status not in ('active', 'read_only')
     or v_registry.authority_generation <> p_expected_source_generation
     or v_migration.source_generation <> p_expected_source_generation
     or v_migration.target_generation <> p_expected_source_generation + 1
     or v_migration.status not in ('shadowing', 'v2_ready')
     or not v_state.v2_ready
     or v_state.status not in ('preparing', 'read_only')
     or v_state.farm_generation <> v_migration.target_generation
     or v_migration.parity_digest <> lower(p_expected_parity_digest)
     or v_state.latest_snapshot_id is null
     or v_state.write_frozen
     or exists (
       select 1
       from esheep_cloud.attention_items attention
       where attention.farm_id = p_farm_id
         and attention.farm_generation = v_migration.target_generation
         and attention.status in ('open', 'resolving')
     )
     or exists (
       select 1
       from esheep_cloud.assets asset
       where asset.farm_id = p_farm_id
         and asset.farm_generation = v_migration.target_generation
         and (
           asset.thumbnail_state <> 'verified'
           or asset.avatar_state <> 'verified'
           or asset.original_state <> 'verified'
         )
     )
     or not exists (
       select 1
       from esheep_cloud.snapshots snapshot
       where snapshot.snapshot_id = v_state.latest_snapshot_id
         and snapshot.farm_id = p_farm_id
         and snapshot.farm_generation = v_state.farm_generation
         and snapshot.status = 'verified'
         and snapshot.boundary_event_sequence <= v_state.event_head
         and snapshot.schema_version = v_state.schema_version
         and snapshot.farm_profile_digest is not null
         and snapshot.total_digest is not null
         and snapshot.manifest ->> 'snapshot_id' = snapshot.snapshot_id::text
         and snapshot.manifest ->> 'farm_id' = snapshot.farm_id::text
         and snapshot.manifest ->> 'farm_generation' = snapshot.farm_generation::text
         and snapshot.manifest ->> 'boundary_event_sequence' = snapshot.boundary_event_sequence::text
         and snapshot.manifest ->> 'total_digest' = snapshot.total_digest
     ) then
    raise exception using errcode = '40001', message = 'esheep_cloud_cutover_precondition_failed';
  end if;

  v_integrity_report := esheep_cloud.audit_farm_integrity_v2(
    p_farm_id,
    v_state.farm_generation
  );
  if not coalesce((v_integrity_report ->> 'passed')::boolean, false) then
    return jsonb_build_object(
      'farm_id', p_farm_id,
      'farm_generation', v_state.farm_generation,
      'status', 'integrity_hold',
      'trace_id', v_integrity_report ->> 'trace_id'
    );
  end if;

  update public.farm_registry
  set provider = 'esheep_cloud',
      status = 'active',
      authority_generation = v_migration.target_generation,
      updated_at = v_cutover_at
  where farm_id = p_farm_id;

  update esheep_cloud.farm_state
  set status = 'active',
      v1_final_revision = v_registry.current_revision,
      updated_at = v_cutover_at
  where farm_id = p_farm_id;

  update esheep_cloud.migration_reconciliations
  set status = 'cut_over',
      cutover_mode = 'owner_confirmed_immediate',
      owner_confirmation = p_owner_confirmation,
      owner_confirmation_user_id = v_owner_user_id,
      owner_confirmation_at = v_cutover_at,
      v1_final_event_boundary = v_registry.current_revision,
      cut_over_at = v_cutover_at,
      parity_report = parity_report || jsonb_build_object(
        'authority_cutover', true,
        'cutover_mode', 'owner_confirmed_immediate',
        'owner_confirmation_user_id', v_owner_user_id::text,
        'owner_confirmation_at', v_cutover_at,
        'physical_acceptance_pending', true,
        'fresh_device_projection_parity', false,
        'real_device_acceptance', false
      ),
      updated_at = v_cutover_at
  where farm_id = p_farm_id;

  return jsonb_build_object(
    'farm_id', p_farm_id,
    'farm_generation', v_migration.target_generation,
    'provider', 'eSheepCloud',
    'status', 'active',
    'cutover_mode', 'owner_confirmed_immediate',
    'pending_device_acceptance', true,
    'v1_final_revision', v_registry.current_revision,
    'event_head', v_state.event_head,
    'snapshot_id', v_state.latest_snapshot_id,
    'parity_digest', v_migration.parity_digest,
    'cut_over_at', v_cutover_at
  );
end;
$$;

revoke all on function public.esheep_cloud_cut_over_farm_v2_owner_confirmed(uuid, integer, text, text)
  from public, anon;
grant execute on function public.esheep_cloud_cut_over_farm_v2_owner_confirmed(uuid, integer, text, text)
  to authenticated;

notify pgrst, 'reload schema';
