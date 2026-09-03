-- eSheep+ Cloud V2 deliberately lives outside the exposed Data API schema.
-- Clients receive no table privileges; every read and write crosses one of
-- the public RPC transaction boundaries declared at the end of this file.

create schema if not exists esheep_cloud;
revoke all on schema esheep_cloud from public, anon, authenticated;

alter table public.farm_registry
  drop constraint if exists farm_registry_provider_check;
alter table public.farm_registry
  add constraint farm_registry_provider_check
  check (provider in ('icloud', 'supabase', 'esheep_cloud'));

create table esheep_cloud.farm_state (
  farm_id uuid primary key references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  protocol_version integer not null default 2 check (protocol_version = 2),
  schema_version integer not null default 1 check (schema_version > 0),
  event_head bigint not null default 0 check (event_head >= 0),
  status text not null default 'preparing'
    check (status in ('preparing', 'active', 'read_only', 'integrity_hold', 'access_revoked')),
  v2_ready boolean not null default false,
  write_frozen boolean not null default false,
  write_freeze_trace_id uuid,
  latest_snapshot_id uuid,
  v1_final_revision bigint,
  projection_digest text not null default repeat('0', 64)
    check (projection_digest ~ '^[0-9a-f]{64}$'),
  last_integrity_check_at timestamptz,
  last_integrity_report jsonb not null default '{}'::jsonb
    check (jsonb_typeof(last_integrity_report) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Shared farm identity is versioned with the cloud generation and captured
-- into every immutable snapshot. A requesting member's role is intentionally
-- read from farm_members at session-open time, never copied into this table.
create table esheep_cloud.farm_profiles (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  owner_account_id uuid not null,
  name text not null check (length(btrim(name)) > 0),
  location_display_name text,
  latitude double precision,
  longitude double precision,
  coordinate_reference_system text not null default 'wgs84'
    check (coordinate_reference_system = 'wgs84'),
  address_snapshot text,
  time_zone_identifier text not null default 'Asia/Shanghai'
    check (length(btrim(time_zone_identifier)) > 0),
  location_source text
    check (location_source is null or location_source in (
      'mapSearch', 'manualCoordinate', 'currentLocation', 'legacyMigration'
    )),
  horizontal_accuracy_meters double precision
    check (horizontal_accuracy_meters is null or horizontal_accuracy_meters >= 0),
  location_updated_at timestamptz,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  primary key (farm_id, farm_generation),
  check (
    (latitude is null and longitude is null)
    or
    (latitude is not null and longitude is not null
      and latitude between -90 and 90 and longitude between -180 and 180)
  )
);

create table esheep_cloud.command_catalog (
  command_kind text primary key,
  merge_mode text not null
    check (merge_mode in ('append_fact', 'field_patch', 'or_set', 'ledger', 'state_machine', 'lifecycle')),
  allowed_roles text[] not null,
  requires_online boolean not null default false,
  current_schema_version integer not null default 1 check (current_schema_version > 0),
  handler_schema_version integer check (handler_schema_version > 0),
  client_projection_schema_version integer
    check (client_projection_schema_version > 0)
);

create table esheep_cloud.commands (
  command_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  source_request_id uuid not null,
  bundle_id uuid,
  actor_user_id uuid not null references auth.users(id),
  account_id uuid not null,
  device_id uuid not null references public.devices(device_id),
  device_sequence bigint not null check (device_sequence > 0),
  protocol_version integer not null check (protocol_version = 2),
  schema_version integer not null check (schema_version > 0),
  command_kind text not null references esheep_cloud.command_catalog(command_kind),
  occurred_at timestamptz not null,
  client_created_at timestamptz not null,
  unsigned_command bytea not null,
  content_digest text not null check (content_digest ~ '^[0-9a-f]{64}$'),
  device_signature bytea not null,
  affected_streams jsonb not null check (jsonb_typeof(affected_streams) = 'array'),
  affected_fields jsonb not null check (jsonb_typeof(affected_fields) = 'array'),
  field_changes jsonb not null check (jsonb_typeof(field_changes) = 'array'),
  prerequisite_command_ids uuid[] not null default '{}',
  required_asset_ids uuid[] not null default '{}',
  status text not null
    check (status in ('processing', 'accepted', 'needs_confirmation', 'rejected')),
  result jsonb not null,
  server_received_at timestamptz not null default now(),
  completed_at timestamptz not null default now(),
  unique (farm_id, farm_generation, device_id, device_sequence),
  unique (farm_id, source_request_id)
);

create table esheep_cloud.streams (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  stream_type text not null,
  stream_id uuid not null,
  stream_version bigint not null default 0 check (stream_version >= 0),
  field_versions jsonb not null default '{}'::jsonb
    check (jsonb_typeof(field_versions) = 'object'),
  canonical_state jsonb not null default '{}'::jsonb,
  content_digest text not null default repeat('0', 64)
    check (content_digest ~ '^[0-9a-f]{64}$'),
  last_event_sequence bigint not null default 0 check (last_event_sequence >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (farm_id, farm_generation, stream_type, stream_id)
);

create table esheep_cloud.events (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  event_sequence bigint not null check (event_sequence > 0),
  event_id uuid not null unique default gen_random_uuid(),
  command_id uuid not null references esheep_cloud.commands(command_id),
  source_command_digest text not null check (source_command_digest ~ '^[0-9a-f]{64}$'),
  stream_type text not null,
  stream_id uuid not null,
  event_kind text not null,
  event_body jsonb not null,
  event_body_digest text not null check (event_body_digest ~ '^[0-9a-f]{64}$'),
  affected_fields text[] not null default '{}',
  before_digest text not null check (before_digest ~ '^[0-9a-f]{64}$'),
  after_digest text not null check (after_digest ~ '^[0-9a-f]{64}$'),
  actor_account_id uuid not null,
  source_device_id uuid not null,
  source_device_sequence bigint not null check (source_device_sequence > 0),
  occurred_at timestamptz not null,
  received_at timestamptz not null,
  event_digest text not null check (event_digest ~ '^[0-9a-f]{64}$'),
  primary key (farm_id, farm_generation, event_sequence)
);

create table esheep_cloud.attention_items (
  attention_id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  command_id uuid not null references esheep_cloud.commands(command_id),
  stream_type text not null,
  stream_id uuid not null,
  record_type text not null,
  record_id uuid not null,
  record_display_name text not null default '',
  field_key text not null,
  field_display_name text not null,
  base_value_digest text not null check (base_value_digest ~ '^[0-9a-f]{64}$'),
  device_value jsonb not null,
  cloud_value jsonb not null,
  device_account_id uuid not null,
  device_id uuid not null,
  device_occurred_at timestamptz not null,
  cloud_account_id uuid,
  cloud_device_id uuid,
  cloud_received_at timestamptz,
  explanation text not null,
  dependent_command_ids uuid[] not null default '{}',
  status text not null default 'open'
    check (status in ('open', 'resolving', 'resolved', 'obsolete')),
  resolution text
    check (resolution is null or resolution in ('use_this_device', 'keep_cloud', 'abandon_operation', 'resubmit')),
  resolution_command_id uuid,
  resolution_event_id uuid,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (command_id, stream_type, stream_id, field_key)
);

-- The current field author is not enough to order delayed commands. If device
-- A's sequence 30 is followed by device B and then A's delayed sequence 29,
-- the field now names B as its author even though A:29 is already superseded.
-- Keep an independent per-field watermark for every device so that causal
-- no-ops remain no-ops across arbitrary interleaving by other devices.
create table esheep_cloud.field_device_watermarks (
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  stream_type text not null,
  stream_id uuid not null,
  field_key text not null,
  device_id uuid not null,
  highest_device_sequence bigint not null check (highest_device_sequence > 0),
  command_id uuid not null references esheep_cloud.commands(command_id)
    deferrable initially deferred,
  desired_value_digest text not null check (desired_value_digest ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz not null default now(),
  primary key (
    farm_id, farm_generation, stream_type, stream_id, field_key, device_id
  )
);

create table esheep_cloud.assets (
  asset_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  sheep_id uuid,
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  thumbnail_sha256 text check (thumbnail_sha256 is null or thumbnail_sha256 ~ '^[0-9a-f]{64}$'),
  avatar_sha256 text check (avatar_sha256 is null or avatar_sha256 ~ '^[0-9a-f]{64}$'),
  original_sha256 text check (original_sha256 is null or original_sha256 ~ '^[0-9a-f]{64}$'),
  metadata jsonb not null default '{}'::jsonb,
  metadata_digest text not null check (metadata_digest ~ '^[0-9a-f]{64}$'),
  thumbnail_path text,
  avatar_path text,
  original_path text,
  thumbnail_state text not null default 'missing'
    check (thumbnail_state in ('missing', 'transferring', 'verified', 'failed', 'recycle_bin', 'deleted')),
  avatar_state text not null default 'missing'
    check (avatar_state in ('missing', 'transferring', 'verified', 'failed', 'recycle_bin', 'deleted')),
  original_state text not null default 'missing'
    check (original_state in ('missing', 'transferring', 'verified', 'failed', 'recycle_bin', 'deleted')),
  thumbnail_byte_count bigint not null default 0 check (thumbnail_byte_count >= 0),
  avatar_byte_count bigint not null default 0 check (avatar_byte_count >= 0),
  original_byte_count bigint not null default 0 check (original_byte_count >= 0),
  uploaded_by uuid references auth.users(id),
  recycle_expires_at timestamptz,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (farm_id, farm_generation, content_sha256)
);

create table esheep_cloud.snapshots (
  snapshot_id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references public.farm_registry(farm_id) on delete cascade,
  farm_generation integer not null check (farm_generation >= 0),
  boundary_event_sequence bigint not null check (boundary_event_sequence >= 0),
  schema_version integer not null check (schema_version > 0),
  farm_profile_data bytea,
  farm_profile_digest text
    check (farm_profile_digest is null or farm_profile_digest ~ '^[0-9a-f]{64}$'),
  manifest jsonb not null default '{}'::jsonb,
  total_digest text check (total_digest is null or total_digest ~ '^[0-9a-f]{64}$'),
  total_byte_count bigint not null default 0 check (total_byte_count >= 0),
  chunk_count integer not null default 0 check (chunk_count >= 0),
  status text not null default 'building'
    check (status in ('building', 'verified', 'obsolete', 'failed')),
  created_at timestamptz not null default now(),
  verified_at timestamptz
);

create table esheep_cloud.snapshot_chunks (
  snapshot_id uuid not null references esheep_cloud.snapshots(snapshot_id) on delete cascade,
  chunk_index integer not null check (chunk_index >= 0),
  content_data bytea not null,
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  byte_count bigint not null check (byte_count >= 0),
  created_at timestamptz not null default now(),
  primary key (snapshot_id, chunk_index)
);

create table esheep_cloud.migration_reconciliations (
  farm_id uuid primary key references public.farm_registry(farm_id) on delete cascade,
  source_generation integer not null check (source_generation >= 0),
  target_generation integer not null check (target_generation > source_generation),
  status text not null default 'shadowing'
    check (status in ('shadowing', 'parity_failed', 'v2_ready', 'cut_over', 'forward_repair_required')),
  source_manifest_digest text not null default repeat('0', 64)
    check (source_manifest_digest ~ '^[0-9a-f]{64}$'),
  target_manifest_digest text not null default repeat('0', 64)
    check (target_manifest_digest ~ '^[0-9a-f]{64}$'),
  parity_report jsonb not null default '{}'::jsonb,
  parity_digest text not null default repeat('0', 64)
    check (parity_digest ~ '^[0-9a-f]{64}$'),
  v1_final_event_boundary bigint,
  first_v2_command_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cut_over_at timestamptz
);

create index esheep_cloud_commands_ready_idx
  on esheep_cloud.commands (farm_id, farm_generation, server_received_at, command_id);
create index esheep_cloud_events_pull_idx
  on esheep_cloud.events (farm_id, farm_generation, event_sequence);
create index esheep_cloud_attention_open_idx
  on esheep_cloud.attention_items (farm_id, farm_generation, created_at)
  where status = 'open';
create index esheep_cloud_assets_farm_idx
  on esheep_cloud.assets (farm_id, farm_generation, created_at);
create index esheep_cloud_snapshots_open_idx
  on esheep_cloud.snapshots (farm_id, farm_generation, created_at desc)
  where status = 'verified';

insert into esheep_cloud.command_catalog (command_kind, merge_mode, allowed_roles, requires_online)
values
  ('farm.updateLocation', 'field_patch', array['owner', 'administrator'], false),
  ('pen.create', 'or_set', array['owner', 'administrator', 'worker'], false),
  ('pen.update', 'field_patch', array['owner', 'administrator', 'worker'], false),
  ('pen.setActive', 'field_patch', array['owner', 'administrator'], false),
  ('sheep.add', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('sheep.patchProfile', 'field_patch', array['owner', 'administrator', 'worker'], false),
  ('sheepAvatar.set', 'field_patch', array['owner', 'administrator', 'worker'], false),
  ('sheepAvatar.clear', 'field_patch', array['owner', 'administrator', 'worker'], false),
  ('weight.record', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('weight.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('weaning.record', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('breedingProgram.create', 'or_set', array['owner', 'administrator'], false),
  ('transfer.record', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('transfer.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('removal.record', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('removal.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('removal.restore', 'lifecycle', array['owner', 'administrator'], false),
  ('productionBatch.create', 'or_set', array['owner', 'administrator', 'worker'], false),
  ('batchMembership.assign', 'or_set', array['owner', 'administrator', 'worker'], false),
  ('batchMembership.leave', 'or_set', array['owner', 'administrator', 'worker'], false),
  ('batchMembership.restore', 'or_set', array['owner', 'administrator'], false),
  ('feedIngredient.add', 'or_set', array['owner', 'administrator'], false),
  ('feedRecipe.create', 'or_set', array['owner', 'administrator'], false),
  ('feedRecipe.member.add', 'or_set', array['owner', 'administrator'], false),
  ('feed.recordLegacy', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('feedIngredient.save', 'state_machine', array['owner', 'administrator'], false),
  ('feedBatch.save', 'state_machine', array['owner', 'administrator'], false),
  ('feedStock.adjust', 'ledger', array['owner', 'administrator'], false),
  ('feedStock.count', 'ledger', array['owner', 'administrator'], false),
  ('feedRecipe.save', 'state_machine', array['owner', 'administrator'], false),
  ('feed.record', 'ledger', array['owner', 'administrator', 'worker'], false),
  ('feedTrough.record', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('feed.importHistorical', 'append_fact', array['owner', 'administrator'], false),
  ('health.record', 'ledger', array['owner', 'administrator', 'worker'], false),
  ('inventory.receive', 'ledger', array['owner', 'administrator'], false),
  ('semen.add', 'ledger', array['owner', 'administrator'], false),
  ('reproduction.record', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('note.add', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('record.revoke', 'lifecycle', array['owner', 'administrator'], false),
  ('record.restore', 'lifecycle', array['owner', 'administrator'], false),
  ('photoAsset.register', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('photoAsset.recycle', 'lifecycle', array['owner', 'administrator'], false),
  ('photoAsset.restore', 'lifecycle', array['owner', 'administrator'], false),
  ('care.healthCatalog.upsert', 'state_machine', array['owner', 'administrator'], false),
  ('care.health.recordBatch', 'ledger', array['owner', 'administrator', 'worker'], false),
  ('care.health.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('care.inventory.receive', 'ledger', array['owner', 'administrator'], false),
  ('care.inventory.adjust', 'ledger', array['owner', 'administrator'], false),
  ('care.inventoryLot.setActive', 'state_machine', array['owner', 'administrator'], false),
  ('care.semen.adjust', 'ledger', array['owner', 'administrator'], false),
  ('care.semenDonor.upsert', 'state_machine', array['owner', 'administrator'], false),
  ('care.semen.setDonor', 'state_machine', array['owner', 'administrator'], false),
  ('care.sheepPedigree.update', 'state_machine', array['owner', 'administrator'], false),
  ('care.sheep.setBreedingRam', 'state_machine', array['owner', 'administrator'], false),
  ('care.sheep.setPurpose', 'state_machine', array['owner', 'administrator'], false),
  ('care.sheepPedigree.restoreAudit', 'lifecycle', array['owner', 'administrator'], false),
  ('care.reproduction.recordBatch', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('care.lambing.record', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('care.reproduction.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('care.lambing.correct', 'lifecycle', array['owner', 'administrator'], false),
  ('care.lambing.revoke', 'lifecycle', array['owner', 'administrator'], false),
  ('care.lambing.restore', 'lifecycle', array['owner', 'administrator'], false),
  ('care.careRules.update', 'state_machine', array['owner', 'administrator'], false),
  ('care.operationalAlertRules.update', 'state_machine', array['owner', 'administrator'], false),
  ('care.operationalAlert.defer', 'append_fact', array['owner', 'administrator', 'worker'], false),
  ('care.careReminder.setStatus', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('tmr.saveTMRFormula', 'state_machine', array['owner', 'administrator'], false),
  ('tmr.saveTMRMonitoringRule', 'state_machine', array['owner', 'administrator'], false),
  ('tmr.saveTMRFeedingPlan', 'state_machine', array['owner', 'administrator'], false),
  ('tmr.produceTMRBatch', 'ledger', array['owner', 'administrator', 'worker'], false),
  ('tmr.recordTMRFeeding', 'ledger', array['owner', 'administrator', 'worker'], false),
  ('tmr.correctTMRFeedingRun', 'lifecycle', array['owner', 'administrator'], false),
  ('tmr.reverseTMRFeedingRun', 'lifecycle', array['owner', 'administrator'], false),
  ('tmr.completeTMRMeal', 'state_machine', array['owner', 'administrator', 'worker'], false),
  ('tmr.reopenTMRMeal', 'lifecycle', array['owner', 'administrator'], false),
  ('tmr.adjustTMRBatch', 'ledger', array['owner', 'administrator'], false),
  ('tmr.closeTMRBatch', 'state_machine', array['owner', 'administrator'], false),
  ('tmr.deleteUnusedTMRBatch', 'lifecycle', array['owner', 'administrator'], false),
  ('tmr.acknowledgeTMRDeviation', 'append_fact', array['owner', 'administrator', 'worker'], false)
on conflict (command_kind) do update
set merge_mode = excluded.merge_mode,
    allowed_roles = excluded.allowed_roles,
    requires_online = excluded.requires_online,
    current_schema_version = excluded.current_schema_version,
    handler_schema_version = null,
    client_projection_schema_version = null;

-- Do not mark rows ready with a bulk UPDATE.  Readiness is derived from the
-- executable server dispatcher and the independent client projection route
-- below.  The nullable version columns remain only as migration metadata for
-- older readers; they are never used as proof of implementation.

-- A farm must never cross the irreversible V1 -> V2 boundary while the App
-- can still construct a command that the server cannot transact. Individual
-- commands already fail closed below; this second gate protects the migration
-- itself from turning a partially implemented protocol into the farm's only
-- writable authority.
create or replace function esheep_cloud.protocol_readiness_report_v2()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'protocol_version', 2,
    'schema_version', 1,
    'ready', count(*) filter (where
      catalog.handler_schema_version is distinct from catalog.current_schema_version
      or catalog.client_projection_schema_version is distinct from catalog.current_schema_version
    ) = 0,
    'declared_command_count', count(*),
    'implemented_command_count', count(*) filter (where
      catalog.handler_schema_version = catalog.current_schema_version
      and catalog.client_projection_schema_version = catalog.current_schema_version
    ),
    'server_implemented_command_count', count(*) filter (
      where catalog.handler_schema_version = catalog.current_schema_version
    ),
    'client_projected_command_count', count(*) filter (
      where catalog.client_projection_schema_version = catalog.current_schema_version
    ),
    'incomplete_command_kinds', coalesce(
      jsonb_agg(catalog.command_kind order by catalog.command_kind) filter (where
        catalog.handler_schema_version is distinct from catalog.current_schema_version
        or catalog.client_projection_schema_version is distinct from catalog.current_schema_version
      ),
      '[]'::jsonb
    ),
    'missing_server_handler_kinds', coalesce(
      jsonb_agg(catalog.command_kind order by catalog.command_kind) filter (
        where catalog.handler_schema_version is distinct from catalog.current_schema_version
      ),
      '[]'::jsonb
    ),
    'missing_client_projection_kinds', coalesce(
      jsonb_agg(catalog.command_kind order by catalog.command_kind) filter (
        where catalog.client_projection_schema_version is distinct from catalog.current_schema_version
      ),
      '[]'::jsonb
    )
  )
  from esheep_cloud.command_catalog catalog;
$$;

create or replace function esheep_cloud.assert_protocol_ready_v2()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_report jsonb := esheep_cloud.protocol_readiness_report_v2();
begin
  if coalesce((v_report ->> 'ready')::boolean, false) is not true then
    raise exception using
      errcode = '0A000',
      message = 'esheep_cloud_protocol_incomplete',
      detail = v_report::text;
  end if;
end;
$$;

create or replace function esheep_cloud.sha256_hex(p_data bytea)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select encode(extensions.digest(p_data, 'sha256'), 'hex');
$$;

-- Foundation's V2 codec hashes UTF-8 JSON with sorted object keys and no
-- insignificant whitespace. `jsonb::text` inserts spaces, so it must never be
-- used as the cross-platform digest input.
create or replace function esheep_cloud.canonical_json_text(p_value jsonb)
returns text
language plpgsql
immutable
strict
security invoker
set search_path = ''
as $$
declare
  v_type text := jsonb_typeof(p_value);
  v_result text;
begin
  case v_type
    when 'object' then
      select '{' || coalesce(string_agg(
        to_jsonb(entry.key)::text || ':' || esheep_cloud.canonical_json_text(entry.value),
        ',' order by entry.key
      ), '') || '}'
      into v_result
      from jsonb_each(p_value) entry;
    when 'array' then
      select '[' || coalesce(string_agg(
        esheep_cloud.canonical_json_text(entry.value),
        ',' order by entry.ordinality
      ), '') || ']'
      into v_result
      from jsonb_array_elements(p_value) with ordinality entry(value, ordinality);
    when 'string', 'number', 'boolean', 'null' then
      v_result := p_value::text;
    else
      raise exception using errcode = '22023', message = 'esheep_cloud_json_type_unknown';
  end case;
  return v_result;
end;
$$;

create or replace function esheep_cloud.json_digest(p_value jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select esheep_cloud.sha256_hex(
    convert_to(esheep_cloud.canonical_json_text(p_value), 'utf8')
  );
$$;

create or replace function esheep_cloud.farm_profile_json_v2(
  p_profile esheep_cloud.farm_profiles
)
returns jsonb
language sql
immutable
strict
security invoker
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'farmID', upper(p_profile.farm_id::text),
    'ownerAccountID', upper(p_profile.owner_account_id::text),
    'name', p_profile.name,
    'createdAt', round(extract(epoch from p_profile.created_at) * 1000)::bigint,
    'updatedAt', round(extract(epoch from p_profile.updated_at) * 1000)::bigint,
    'locationDisplayName', p_profile.location_display_name,
    'latitude', p_profile.latitude,
    'longitude', p_profile.longitude,
    'coordinateReferenceSystem', p_profile.coordinate_reference_system,
    'addressSnapshot', p_profile.address_snapshot,
    'timeZoneIdentifier', p_profile.time_zone_identifier,
    'locationSourceRawValue', p_profile.location_source,
    'horizontalAccuracyMeters', p_profile.horizontal_accuracy_meters,
    'locationUpdatedAt', case when p_profile.location_updated_at is null then null
      else round(extract(epoch from p_profile.location_updated_at) * 1000)::bigint end
  ));
$$;

create or replace function esheep_cloud.upsert_farm_profile_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_owner_account_id uuid,
  p_name text,
  p_created_at timestamptz,
  p_updated_at timestamptz,
  p_location_display_name text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_address_snapshot text default null,
  p_time_zone_identifier text default 'Asia/Shanghai',
  p_location_source text default null,
  p_horizontal_accuracy_meters double precision default null,
  p_location_updated_at timestamptz default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile esheep_cloud.farm_profiles%rowtype;
begin
  if (select auth.role()) <> 'service_role'
     and current_user not in ('postgres', 'supabase_admin') then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if not exists (
    select 1
    from public.farm_registry registry
    join public.profiles owner_profile
      on owner_profile.user_id = registry.owner_user_id
    where registry.farm_id = p_farm_id
      and registry.authority_generation <= p_farm_generation
      and owner_profile.app_account_id = p_owner_account_id
  ) then
    raise exception using errcode = '23503', message = 'esheep_cloud_farm_profile_owner_invalid';
  end if;
  insert into esheep_cloud.farm_profiles (
    farm_id, farm_generation, owner_account_id, name,
    location_display_name, latitude, longitude,
    coordinate_reference_system, address_snapshot, time_zone_identifier,
    location_source, horizontal_accuracy_meters, location_updated_at,
    created_at, updated_at
  ) values (
    p_farm_id, p_farm_generation, p_owner_account_id, btrim(p_name),
    nullif(btrim(p_location_display_name), ''), p_latitude, p_longitude,
    'wgs84', nullif(btrim(p_address_snapshot), ''), btrim(p_time_zone_identifier),
    p_location_source, p_horizontal_accuracy_meters, p_location_updated_at,
    p_created_at, p_updated_at
  ) on conflict (farm_id, farm_generation) do update set
    owner_account_id = excluded.owner_account_id,
    name = excluded.name,
    location_display_name = excluded.location_display_name,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    coordinate_reference_system = excluded.coordinate_reference_system,
    address_snapshot = excluded.address_snapshot,
    time_zone_identifier = excluded.time_zone_identifier,
    location_source = excluded.location_source,
    horizontal_accuracy_meters = excluded.horizontal_accuracy_meters,
    location_updated_at = excluded.location_updated_at,
    created_at = excluded.created_at,
    updated_at = excluded.updated_at
  returning * into v_profile;
  return esheep_cloud.json_digest(
    esheep_cloud.farm_profile_json_v2(v_profile)
  );
end;
$$;

create or replace function esheep_cloud.value_digest(p_value jsonb)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_type text := p_value ->> 'type';
  v_canonical text;
begin
  case v_type
    when 'null' then
      v_canonical := 'null';
    when 'string' then
      v_canonical := 'string:' || octet_length(coalesce(p_value ->> 'value', ''))::text || ':' || coalesce(p_value ->> 'value', '');
    when 'integer' then
      v_canonical := 'integer:' || (p_value ->> 'value')::bigint::text;
    when 'decimal' then
      v_canonical := 'decimal:' || coalesce(p_value ->> 'value', '');
    when 'boolean' then
      v_canonical := 'boolean:' || lower((p_value ->> 'value')::boolean::text);
    when 'date' then
      v_canonical := 'date:' || round((p_value ->> 'value')::numeric)::bigint::text;
    when 'identifier' then
      v_canonical := 'identifier:' || lower((p_value ->> 'value')::uuid::text);
    when 'strings' then
      select 'strings:' || coalesce(string_agg(octet_length(item.value)::text || ':' || item.value, '|' order by item.ordinality), '')
      into v_canonical
      from jsonb_array_elements_text(coalesce(p_value -> 'value', '[]'::jsonb)) with ordinality item(value, ordinality);
    when 'identifiers' then
      select 'identifiers:' || coalesce(string_agg(lower(item.value::uuid::text), '|' order by item.ordinality), '')
      into v_canonical
      from jsonb_array_elements_text(coalesce(p_value -> 'value', '[]'::jsonb)) with ordinality item(value, ordinality);
    else
      raise exception using errcode = '22023', message = 'esheep_cloud_value_type_unknown';
  end case;
  return esheep_cloud.sha256_hex(convert_to(v_canonical, 'utf8'));
end;
$$;

create or replace function esheep_cloud.field_display_name(p_field text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_field
    when 'avatar' then '头像'
    when 'earTag' then '耳号'
    when 'breed' then '品种'
    when 'sex' then '性别'
    when 'birthAt' then '出生日期'
    when 'currentParity' then '当前胎次'
    when 'parityRecordedAt' then '胎次确认时间'
    when 'note' then '备注'
    when 'name' then '名称'
    when 'isActive' then '启用状态'
    when 'displayName' then '牧场地点'
    when 'latitude' then '纬度'
    when 'longitude' then '经度'
    when 'addressSnapshot' then '地址'
    when 'timeZoneIdentifier' then '时区'
    else p_field
  end;
$$;

create or replace function esheep_cloud.record_display_name_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_stream_type text,
  p_stream_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_stream_type in ('sheepProfile', 'sheepAvatar') then
      coalesce(
        nullif((
          select profile_stream.canonical_state #>> '{earTag,value}'
          from esheep_cloud.streams profile_stream
          where profile_stream.farm_id = p_farm_id
            and profile_stream.farm_generation = p_farm_generation
            and profile_stream.stream_type = 'sheepProfile'
            and profile_stream.stream_id = p_stream_id
        ), ''),
        '羊只 ' || left(p_stream_id::text, 8)
      )
    when p_stream_type = 'pen' then
      coalesce(
        nullif((
          select pen_stream.canonical_state #>> '{name,value}'
          from esheep_cloud.streams pen_stream
          where pen_stream.farm_id = p_farm_id
            and pen_stream.farm_generation = p_farm_generation
            and pen_stream.stream_type = 'pen'
            and pen_stream.stream_id = p_stream_id
        ), ''),
        '圈舍 ' || left(p_stream_id::text, 8)
      )
    when p_stream_type = 'farm' then '牧场资料'
    else '业务记录 ' || left(p_stream_id::text, 8)
  end;
$$;

create or replace function esheep_cloud.expected_payload_case_v2(p_kind text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_kind
    when 'farm.updateLocation' then 'updateLocation'
    when 'pen.create' then 'create'
    when 'pen.update' then 'update'
    when 'pen.setActive' then 'setActive'
    when 'sheep.add' then 'add'
    when 'sheep.patchProfile' then 'patchProfile'
    when 'sheepAvatar.set' then 'setAvatar'
    when 'sheepAvatar.clear' then 'clearAvatar'
    when 'weight.record' then 'recordWeight'
    when 'weight.correct' then 'correctWeight'
    when 'weaning.record' then 'recordWeaning'
    when 'transfer.record' then 'transferSheep'
    when 'transfer.correct' then 'correctTransfer'
    when 'removal.record' then 'removeSheep'
    when 'removal.correct' then 'correctRemoval'
    when 'removal.restore' then 'restoreSheep'
    when 'breedingProgram.create' then 'createBreedingProgram'
    when 'productionBatch.create' then 'createBatch'
    when 'batchMembership.assign' then 'assignSheepToBatch'
    when 'batchMembership.leave' then 'leaveBatch'
    when 'batchMembership.restore' then 'restoreBatchMembership'
    when 'feedIngredient.add' then 'addIngredient'
    when 'feedRecipe.create' then 'createRecipe'
    when 'feedRecipe.member.add' then 'addRecipeComponent'
    when 'feed.recordLegacy' then 'recordLegacy'
    when 'feedIngredient.save' then 'saveIngredient'
    when 'feedBatch.save' then 'saveBatch'
    when 'feedStock.adjust' then 'adjustStock'
    when 'feedStock.count' then 'countStock'
    when 'feedRecipe.save' then 'saveRecipe'
    when 'feed.record' then 'record'
    when 'feedTrough.record' then 'recordTroughObservation'
    when 'feed.importHistorical' then 'importHistorical'
    when 'health.record' then 'recordHealth'
    when 'inventory.receive' then 'receiveInventory'
    when 'semen.add' then 'addSemen'
    when 'reproduction.record' then 'recordReproduction'
    when 'note.add' then 'addNote'
    when 'record.revoke' then 'tombstone'
    when 'record.restore' then 'restore'
    when 'photoAsset.register' then 'register'
    when 'photoAsset.recycle' then 'moveToRecycleBin'
    when 'photoAsset.restore' then 'restore'
    when 'care.healthCatalog.upsert' then 'upsertHealthCatalog'
    when 'care.health.recordBatch' then 'recordHealth'
    when 'care.health.correct' then 'correctHealth'
    when 'care.inventory.receive' then 'receiveInventory'
    when 'care.inventory.adjust' then 'adjustInventory'
    when 'care.inventoryLot.setActive' then 'setInventoryLotActive'
    when 'care.semen.adjust' then 'adjustSemen'
    when 'care.semenDonor.upsert' then 'upsertSemenDonor'
    when 'care.semen.setDonor' then 'setSemenDonor'
    when 'care.sheepPedigree.update' then 'updateSheepPedigree'
    when 'care.sheep.setBreedingRam' then 'setBreedingRam'
    when 'care.sheep.setPurpose' then 'setSheepPurpose'
    when 'care.sheepPedigree.restoreAudit' then 'restorePedigreeAudit'
    when 'care.reproduction.recordBatch' then 'recordReproductionBatch'
    when 'care.lambing.record' then 'recordLambing'
    when 'care.reproduction.correct' then 'correctReproduction'
    when 'care.lambing.correct' then 'correctLambing'
    when 'care.lambing.revoke' then 'revokeLambing'
    when 'care.lambing.restore' then 'restoreLambing'
    when 'care.careRules.update' then 'updateRules'
    when 'care.operationalAlertRules.update' then 'updateOperationalAlertRules'
    when 'care.operationalAlert.defer' then 'deferOperationalAlert'
    when 'care.careReminder.setStatus' then 'setReminderStatus'
    when 'tmr.saveTMRFormula' then 'saveFormula'
    when 'tmr.saveTMRMonitoringRule' then 'saveMonitoringRule'
    when 'tmr.saveTMRFeedingPlan' then 'saveFeedingPlan'
    when 'tmr.produceTMRBatch' then 'produceBatch'
    when 'tmr.recordTMRFeeding' then 'recordFeeding'
    when 'tmr.correctTMRFeedingRun' then 'correctFeedingRun'
    when 'tmr.reverseTMRFeedingRun' then 'reverseFeedingRun'
    when 'tmr.completeTMRMeal' then 'completeMeal'
    when 'tmr.reopenTMRMeal' then 'reopenMeal'
    when 'tmr.adjustTMRBatch' then 'adjustBatch'
    when 'tmr.closeTMRBatch' then 'closeBatch'
    when 'tmr.deleteUnusedTMRBatch' then 'deleteUnusedBatch'
    when 'tmr.acknowledgeTMRDeviation' then 'acknowledgeDeviation'
    else null
  end;
$$;

create or replace function esheep_cloud.validate_payload_contract_v2(
  p_kind text,
  p_payload jsonb
)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_expected_case text := esheep_cloud.expected_payload_case_v2(p_kind);
  v_body jsonb := p_payload -> 'body';
begin
  if jsonb_typeof(p_payload) <> 'object'
     or p_payload ->> 'kind' <> p_kind
     or jsonb_typeof(v_body) <> 'object'
     or v_expected_case is null then
    raise exception using errcode = '22023', message = 'esheep_cloud_payload_kind_mismatch';
  end if;

  if p_kind = 'farm.updateLocation' then
    if jsonb_typeof(v_body -> 'action') <> 'object'
       or not ((v_body -> 'action') ? v_expected_case)
       or (select count(*) from jsonb_object_keys(v_body -> 'action')) <> 1 then
      raise exception using errcode = '22023', message = 'esheep_cloud_payload_case_mismatch';
    end if;
  elsif not (v_body ? v_expected_case)
        or (select count(*) from jsonb_object_keys(v_body)) <> 1 then
    raise exception using errcode = '22023', message = 'esheep_cloud_payload_case_mismatch';
  end if;
end;
$$;

-- The discriminator check above proves only that a payload is shaped like one
-- of the typed Swift enums.  This second gate protects the durable command
-- ledger from semantically empty envelopes (for example a weight command
-- with no stream, a batch command pointing at a photo stream, or a command
-- that quietly carries a field patch while its catalogue mode is append-only).
-- It deliberately validates transport-independent invariants here; business
-- eligibility and cross-record rules remain in the transactional handler.
create or replace function esheep_cloud.validate_command_semantics_v2(
  p_kind text,
  p_payload jsonb,
  p_merge_mode text,
  p_affected_streams jsonb,
  p_affected_fields jsonb,
  p_field_changes jsonb
)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_body jsonb := p_payload -> 'body';
  v_expected_case text := esheep_cloud.expected_payload_case_v2(p_kind);
  v_case_body jsonb;
  v_expected_stream_type text;
begin
  if p_kind = 'attention.resolve' then
    -- Resolution has its own signed, transactional RPC and never enters the
    -- generic command processor.
    return;
  end if;
  if p_merge_mode is null
     or v_expected_case is null
     or jsonb_typeof(p_affected_streams) <> 'array'
     or jsonb_array_length(p_affected_streams) = 0
     or jsonb_typeof(p_affected_fields) <> 'array'
     or jsonb_typeof(p_field_changes) <> 'array' then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_semantics_invalid';
  end if;

  -- A stream is a stable business lane, never an arbitrary string. Validate
  -- every stream before the transaction mutates anything. Non-field commands
  -- may touch more than one lane; the event writer below advances every lane
  -- in the same transaction so a secondary semantic stream cannot diverge.
  if (select count(*) from jsonb_array_elements(p_affected_streams)) = 0
     or (select count(distinct (value ->> 'type') || ':' || lower(value ->> 'id'))
         from jsonb_array_elements(p_affected_streams)) <>
        jsonb_array_length(p_affected_streams)
     or exists (
       select 1
       from jsonb_array_elements(p_affected_streams) stream
       where jsonb_typeof(stream.value) <> 'object'
          or nullif(btrim(stream.value ->> 'type'), '') is null
          or (stream.value ->> 'id') is null
          or (stream.value ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     ) then
    raise exception using errcode = '22023', message = 'esheep_cloud_stream_contract_invalid';
  end if;

  -- Observations are part of the signed command contract, not an opaque
  -- hint. A malformed observation must fail before the command ledger is
  -- touched; otherwise a missing version/digest could be interpreted as a
  -- stale value and manufacture a false confirmation item.
  if exists (
       select 1
       from jsonb_array_elements(p_affected_fields) observation
       where jsonb_typeof(observation.value) <> 'object'
          or jsonb_typeof(observation.value -> 'stream') <> 'object'
          or nullif(btrim(observation.value -> 'stream' ->> 'type'), '') is null
          or coalesce(observation.value -> 'stream' ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          or nullif(btrim(observation.value ->> 'field'), '') is null
          or coalesce(observation.value ->> 'observedVersion', '') !~ '^[0-9]+$'
          or coalesce(lower(observation.value ->> 'baseValueDigest'), '') !~ '^[0-9a-f]{64}$'
     )
     or exists (
       select 1
       from jsonb_array_elements(p_affected_fields) observation
       where not exists (
         select 1
         from jsonb_array_elements(p_affected_streams) stream
         where stream.value ->> 'type' = observation.value -> 'stream' ->> 'type'
           and lower(stream.value ->> 'id') = lower(observation.value -> 'stream' ->> 'id')
       )
     )
     or (
       select count(*) from jsonb_array_elements(p_affected_fields)
     ) <> (
       select count(distinct
         (value -> 'stream' ->> 'type') || ':' ||
         lower(value -> 'stream' ->> 'id') || ':' ||
         (value ->> 'field')
       ) from jsonb_array_elements(p_affected_fields)
     ) then
    raise exception using errcode = '22023', message = 'esheep_cloud_field_observation_contract_invalid';
  end if;

  -- The value codec is deliberately small and closed. Enforcing its shape
  -- here keeps digest calculation and the Swift reducer deterministic across
  -- platforms; an unknown value type must not become a silently accepted
  -- business value.
  if exists (
       select 1
       from jsonb_array_elements(p_field_changes) change
       where jsonb_typeof(change.value) <> 'object'
          or nullif(btrim(change.value ->> 'field'), '') is null
          or jsonb_typeof(change.value -> 'mutation') <> 'object'
          or coalesce(change.value -> 'mutation' ->> 'action', '') not in ('set', 'clear')
          or (
            change.value -> 'mutation' ->> 'action' = 'clear'
            and (change.value -> 'mutation') ? 'value'
          )
          or (
            change.value -> 'mutation' ->> 'action' = 'set'
            and not (
              coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value'), '') = 'object'
              and coalesce(change.value -> 'mutation' -> 'value' ->> 'type', '') in (
                'null', 'string', 'integer', 'decimal', 'boolean',
                'date', 'identifier', 'strings', 'identifiers'
              )
              and case change.value -> 'mutation' -> 'value' ->> 'type'
                when 'null' then
                  not ((change.value -> 'mutation' -> 'value') ? 'value')
                  or jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value') = 'null'
                when 'string' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'string'
                when 'integer' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'number'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~ '^-?[0-9]+$'
                when 'decimal' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'string'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~ '^-?[0-9]+(\\.[0-9]+)?$'
                when 'boolean' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'boolean'
                when 'date' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'number'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~ '^-?[0-9]+$'
                when 'identifier' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'string'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                when 'strings' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'array'
                  and not exists (
                    select 1
                    from jsonb_array_elements(change.value -> 'mutation' -> 'value' -> 'value') item
                    where jsonb_typeof(item.value) <> 'string'
                  )
                when 'identifiers' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'array'
                  and not exists (
                    select 1
                    from jsonb_array_elements(change.value -> 'mutation' -> 'value' -> 'value') item
                    where coalesce(item.value #>> '{}', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  )
                else false
              end
            )
          )
     )
     or (
       select count(*) from jsonb_array_elements(p_field_changes)
     ) <> (
       select count(distinct value ->> 'field')
       from jsonb_array_elements(p_field_changes)
     ) then
    raise exception using errcode = '22023', message = 'esheep_cloud_field_mutation_contract_invalid';
  end if;

  -- Only scalar/field lanes may carry field changes.  Other commands are
  -- immutable facts, ledgers, OR-sets or state-machine transitions.  They may
  -- still carry observations as context (for example a care command records
  -- the field it was based on), but accepting a partially populated patch
  -- alongside them would make the event impossible to replay deterministically.
  if p_merge_mode <> 'field_patch'
     and jsonb_array_length(p_field_changes) <> 0 then
    raise exception using errcode = '22023', message = 'esheep_cloud_non_field_patch_invalid';
  end if;
  if p_merge_mode = 'field_patch'
     and (jsonb_array_length(p_affected_fields) = 0
          or jsonb_array_length(p_field_changes) = 0) then
    raise exception using errcode = '22023', message = 'esheep_cloud_field_patch_missing';
  end if;
  if p_merge_mode = 'field_patch'
     and jsonb_array_length(p_affected_streams) <> 1 then
    raise exception using errcode = '22023', message = 'esheep_cloud_field_stream_count_invalid';
  end if;

  v_case_body := v_body -> v_expected_case;
  if jsonb_typeof(v_case_body) <> 'object' then
    raise exception using errcode = '22023', message = 'esheep_cloud_payload_body_invalid';
  end if;

  -- For the concrete non-field lanes, bind the first stream to the record
  -- type implied by the command. Semantic streams (for example a sheep
  -- location lane accompanying a transfer) are additional atomic rows.
  v_expected_stream_type := case
    when p_kind like 'pen.%' then 'pen'
    when p_kind = 'sheep.add' then 'sheep'
    when p_kind like 'weight.%' then 'weight'
    when p_kind = 'weaning.record' then 'weaning'
    when p_kind like 'transfer.%' then 'transfer'
    when p_kind like 'removal.%' then 'removal'
    when p_kind = 'breedingProgram.create' then 'breedingProgram'
    when p_kind = 'productionBatch.create' then 'productionBatch'
    when p_kind like 'batchMembership.%' then 'batchMembership'
    when p_kind = 'feedIngredient.add' or p_kind = 'feedIngredient.save' then 'feedIngredient'
    when p_kind = 'feedBatch.save' then 'feedIngredientBatch'
    when p_kind = 'feedRecipe.create' or p_kind = 'feedRecipe.save' then 'feedRecipe'
    when p_kind = 'feedRecipe.member.add' then 'feedRecipeComponent'
    when p_kind in ('feed.recordLegacy', 'feed.record', 'feed.importHistorical') then 'feed'
    when p_kind = 'feedTrough.record' then 'feedTroughObservation'
    when p_kind = 'feedStock.adjust' or p_kind = 'feedStock.count' then 'feedStockLedger'
    when p_kind = 'health.record' then 'health'
    when p_kind = 'inventory.receive' then 'inventoryLot'
    when p_kind = 'semen.add' then 'semen'
    when p_kind = 'reproduction.record' then 'reproduction'
    when p_kind = 'note.add' then 'note'
    when p_kind like 'photoAsset.%' then 'photoAsset'
    when p_kind = 'care.healthCatalog.upsert' then 'healthCatalogItem'
    when p_kind = 'care.health.recordBatch' then 'health'
    when p_kind = 'care.health.correct' then 'health'
    when p_kind = 'care.inventory.receive' then 'inventoryLot'
    when p_kind = 'care.inventory.adjust' then 'inventoryTransaction'
    when p_kind = 'care.inventoryLot.setActive' then 'inventoryLot'
    when p_kind = 'care.semen.adjust' then 'semenTransaction'
    when p_kind = 'care.semenDonor.upsert' then 'semenDonor'
    when p_kind = 'care.semen.setDonor' then 'semen'
    when p_kind = 'care.sheepPedigree.update' then 'sheep'
    when p_kind = 'care.sheep.setBreedingRam' then 'sheep'
    when p_kind = 'care.sheep.setPurpose' then 'sheep'
    when p_kind = 'care.sheepPedigree.restoreAudit' then 'pedigreeChange'
    when p_kind = 'care.reproduction.recordBatch' then 'careBatch'
    when p_kind = 'care.lambing.record' then 'reproduction'
    when p_kind = 'care.reproduction.correct' then 'careBatch'
    when p_kind = 'care.lambing.correct' then 'reproduction'
    when p_kind = 'care.lambing.revoke' then 'reproduction'
    when p_kind = 'care.lambing.restore' then 'reproduction'
    when p_kind = 'care.careRules.update' then 'careRule'
    when p_kind = 'care.operationalAlertRules.update' then 'careRule'
    when p_kind = 'care.operationalAlert.defer' then 'alertDeferral'
    when p_kind = 'care.careReminder.setStatus' then 'careReminder'
    when p_kind = 'tmr.saveTMRFormula' then 'tmrFormula'
    when p_kind = 'tmr.saveTMRMonitoringRule' then 'tmrMonitoringRule'
    when p_kind = 'tmr.saveTMRFeedingPlan' then 'tmrFeedingPlan'
    when p_kind = 'tmr.produceTMRBatch' then 'tmrBatch'
    when p_kind = 'tmr.recordTMRFeeding' then 'tmrBatch'
    when p_kind = 'tmr.correctTMRFeedingRun' then 'tmrBatch'
    when p_kind = 'tmr.reverseTMRFeedingRun' then 'tmrBatch'
    when p_kind = 'tmr.completeTMRMeal' then 'tmrMealCompletion'
    when p_kind = 'tmr.reopenTMRMeal' then 'tmrMealCompletion'
    when p_kind = 'tmr.adjustTMRBatch' then 'tmrBatch'
    when p_kind = 'tmr.closeTMRBatch' then 'tmrBatch'
    when p_kind = 'tmr.deleteUnusedTMRBatch' then 'tmrBatch'
    when p_kind = 'tmr.acknowledgeTMRDeviation' then 'tmrDeviationAcknowledgement'
    else null
  end;
  if v_expected_stream_type is not null
     and (p_affected_streams -> 0 ->> 'type') <> v_expected_stream_type then
    raise exception using errcode = '22023', message = 'esheep_cloud_stream_kind_invalid';
  end if;

  -- Deletion and photo lifecycle commands use a dynamic target, so their
  -- stream type cannot be represented by the static catalogue mapping above.
  -- Bind that target explicitly to the typed body before the generic event
  -- writer is allowed to advance a stream.
  if p_kind = 'record.revoke' then
    if coalesce(v_case_body ->> 'entityType', '') = ''
       or coalesce(v_case_body ->> 'entityID', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       or lower(p_affected_streams -> 0 ->> 'type') <> lower(v_case_body ->> 'entityType')
       or (p_affected_streams -> 0 ->> 'id')::uuid <> (v_case_body ->> 'entityID')::uuid then
      raise exception using errcode = '22023', message = 'esheep_cloud_deletion_target_invalid';
    end if;
  elsif p_kind = 'record.restore' then
    if coalesce(v_case_body ->> 'tombstoneID', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception using errcode = '22023', message = 'esheep_cloud_restore_target_invalid';
    end if;
  elsif p_kind in ('photoAsset.recycle', 'photoAsset.restore') then
    if lower(p_affected_streams -> 0 ->> 'type') <> 'photoasset'
       or coalesce(v_case_body ->> 'assetID', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       or (p_affected_streams -> 0 ->> 'id')::uuid <> (v_case_body ->> 'assetID')::uuid
       or jsonb_array_length(p_affected_fields) <> 0
       or jsonb_array_length(p_field_changes) <> 0 then
      raise exception using errcode = '22023', message = 'esheep_cloud_photo_lifecycle_target_invalid';
    end if;
  end if;

  -- Every typed body must carry at least one non-null member.  Required
  -- field-level and cross-record validation is performed by the handler, but
  -- rejecting an empty object here gives callers a stable fail-closed result
  -- before any command/stream row can be inserted.
  if (select count(*) from jsonb_object_keys(v_case_body)) = 0 then
    raise exception using errcode = '22023', message = 'esheep_cloud_payload_body_empty';
  end if;
end;
$$;

-- The transaction primitive is shared, but the business entry point is not
-- wildcarded.  Every command kind must select one named handler before a
-- command row can be written.  Keeping this dispatch table in the migration
-- makes an omitted command fail closed at the authority boundary instead of
-- silently becoming an ``eventCount``-only event.  The handler key is also
-- copied into the event body so a fresh device can audit which rule produced
-- the event without consulting client code.
create or replace function esheep_cloud.dispatch_command_v2(
  p_kind text,
  p_payload jsonb,
  p_merge_mode text,
  p_affected_streams jsonb
)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_handler text;
  v_expected_case text := esheep_cloud.expected_payload_case_v2(p_kind);
  v_body jsonb := p_payload -> 'body';
  v_case_body jsonb;
begin
  if p_kind = 'attention.resolve' then
    -- Attention resolutions use their own signed transaction and never enter
    -- process_command_v2.  Keeping the key here lets static tooling prove
    -- that the control-plane kind is intentionally accounted for.
    return 'attention.resolve';
  end if;

  v_handler := case p_kind
    when 'farm.updateLocation' then 'farm.updateLocation'
    when 'pen.create' then 'pen.create'
    when 'pen.update' then 'pen.update'
    when 'pen.setActive' then 'pen.setActive'
    when 'sheep.add' then 'sheep.add'
    when 'sheep.patchProfile' then 'sheep.patchProfile'
    when 'sheepAvatar.set' then 'sheepAvatar.set'
    when 'sheepAvatar.clear' then 'sheepAvatar.clear'
    when 'weight.record' then 'weight.record'
    when 'weight.correct' then 'weight.correct'
    when 'weaning.record' then 'weaning.record'
    when 'transfer.record' then 'transfer.record'
    when 'transfer.correct' then 'transfer.correct'
    when 'removal.record' then 'removal.record'
    when 'removal.correct' then 'removal.correct'
    when 'removal.restore' then 'removal.restore'
    when 'breedingProgram.create' then 'breedingProgram.create'
    when 'productionBatch.create' then 'productionBatch.create'
    when 'batchMembership.assign' then 'batchMembership.assign'
    when 'batchMembership.leave' then 'batchMembership.leave'
    when 'batchMembership.restore' then 'batchMembership.restore'
    when 'feedIngredient.add' then 'feedIngredient.add'
    when 'feedIngredient.save' then 'feedIngredient.save'
    when 'feedRecipe.create' then 'feedRecipe.create'
    when 'feedRecipe.member.add' then 'feedRecipe.member.add'
    when 'feedRecipe.save' then 'feedRecipe.save'
    when 'feed.record' then 'feed.record'
    when 'feed.recordLegacy' then 'feed.recordLegacy'
    when 'feed.importHistorical' then 'feed.importHistorical'
    when 'feedBatch.save' then 'feedBatch.save'
    when 'feedStock.adjust' then 'feedStock.adjust'
    when 'feedStock.count' then 'feedStock.count'
    when 'feedTrough.record' then 'feedTrough.record'
    when 'health.record' then 'health.record'
    when 'inventory.receive' then 'inventory.receive'
    when 'semen.add' then 'semen.add'
    when 'reproduction.record' then 'reproduction.record'
    when 'note.add' then 'note.add'
    when 'record.revoke' then 'record.revoke'
    when 'record.restore' then 'record.restore'
    when 'photoAsset.register' then 'photoAsset.register'
    when 'photoAsset.recycle' then 'photoAsset.recycle'
    when 'photoAsset.restore' then 'photoAsset.restore'
    when 'care.healthCatalog.upsert' then 'care.healthCatalog.upsert'
    when 'care.health.recordBatch' then 'care.health.recordBatch'
    when 'care.health.correct' then 'care.health.correct'
    when 'care.inventory.receive' then 'care.inventory.receive'
    when 'care.inventory.adjust' then 'care.inventory.adjust'
    when 'care.inventoryLot.setActive' then 'care.inventoryLot.setActive'
    when 'care.semen.adjust' then 'care.semen.adjust'
    when 'care.semenDonor.upsert' then 'care.semenDonor.upsert'
    when 'care.semen.setDonor' then 'care.semen.setDonor'
    when 'care.sheepPedigree.update' then 'care.sheepPedigree.update'
    when 'care.sheep.setBreedingRam' then 'care.sheep.setBreedingRam'
    when 'care.sheep.setPurpose' then 'care.sheep.setPurpose'
    when 'care.sheepPedigree.restoreAudit' then 'care.sheepPedigree.restoreAudit'
    when 'care.reproduction.recordBatch' then 'care.reproduction.recordBatch'
    when 'care.lambing.record' then 'care.lambing.record'
    when 'care.reproduction.correct' then 'care.reproduction.correct'
    when 'care.lambing.correct' then 'care.lambing.correct'
    when 'care.lambing.revoke' then 'care.lambing.revoke'
    when 'care.lambing.restore' then 'care.lambing.restore'
    when 'care.careRules.update' then 'care.careRules.update'
    when 'care.operationalAlertRules.update' then 'care.operationalAlertRules.update'
    when 'care.operationalAlert.defer' then 'care.operationalAlert.defer'
    when 'care.careReminder.setStatus' then 'care.careReminder.setStatus'
    when 'tmr.saveTMRFormula' then 'tmr.saveTMRFormula'
    when 'tmr.saveTMRMonitoringRule' then 'tmr.saveTMRMonitoringRule'
    when 'tmr.saveTMRFeedingPlan' then 'tmr.saveTMRFeedingPlan'
    when 'tmr.produceTMRBatch' then 'tmr.produceTMRBatch'
    when 'tmr.recordTMRFeeding' then 'tmr.recordTMRFeeding'
    when 'tmr.correctTMRFeedingRun' then 'tmr.correctTMRFeedingRun'
    when 'tmr.reverseTMRFeedingRun' then 'tmr.reverseTMRFeedingRun'
    when 'tmr.completeTMRMeal' then 'tmr.completeTMRMeal'
    when 'tmr.reopenTMRMeal' then 'tmr.reopenTMRMeal'
    when 'tmr.adjustTMRBatch' then 'tmr.adjustTMRBatch'
    when 'tmr.closeTMRBatch' then 'tmr.closeTMRBatch'
    when 'tmr.deleteUnusedTMRBatch' then 'tmr.deleteUnusedTMRBatch'
    when 'tmr.acknowledgeTMRDeviation' then 'tmr.acknowledgeTMRDeviation'
    else null
  end;

  if v_handler is null or v_expected_case is null
     or jsonb_typeof(p_payload) <> 'object'
     or p_payload ->> 'kind' <> p_kind
     or jsonb_typeof(v_body) <> 'object'
     or jsonb_typeof(p_affected_streams) <> 'array'
     or jsonb_array_length(p_affected_streams) = 0 then
    raise exception using errcode = '0A000',
      message = 'esheep_cloud_command_handler_unavailable';
  end if;

  v_case_body := case
    when p_kind = 'farm.updateLocation' then v_body -> 'action'
    else v_body -> v_expected_case
  end;
  if jsonb_typeof(v_case_body) <> 'object'
     or (select count(*) from jsonb_object_keys(v_case_body)) = 0 then
    raise exception using errcode = '22023',
      message = 'esheep_cloud_payload_body_empty';
  end if;
  return v_handler;
end;
$$;

-- Readiness must be derived from executable routes, never from a manually
-- edited catalogue flag.  This probe feeds a deliberately well-shaped body
-- into the same dispatcher used by the write transaction.  It does not touch
-- a farm, insert a command, or inspect business data; it only proves that the
-- named handler is present and rejects malformed/unknown kinds.
create or replace function esheep_cloud.server_handler_available_v2(
  p_kind text
)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_expected_case text;
  v_payload jsonb;
begin
  if p_kind is null then
    return false;
  end if;
  if p_kind = 'attention.resolve' then
    return true;
  end if;
  v_expected_case := esheep_cloud.expected_payload_case_v2(p_kind);
  if v_expected_case is null then
    return false;
  end if;
  v_payload := jsonb_build_object(
    'kind', p_kind,
    'body', case
      when p_kind = 'farm.updateLocation' then
        jsonb_build_object('action', jsonb_build_object('capability_probe', true))
      else
        jsonb_build_object(v_expected_case, jsonb_build_object('capability_probe', true))
    end
  );
  perform esheep_cloud.dispatch_command_v2(
    p_kind,
    v_payload,
    'append_fact',
    jsonb_build_array(jsonb_build_object(
      'type', 'capabilityProbe',
      'id', '00000000-0000-0000-0000-000000000001'
    ))
  );
  return true;
exception when others then
  return false;
end;
$$;

-- The client-side reducer registry is a separate capability from the server
-- transaction.  Keep one explicit arm per wire kind so a newly declared
-- command cannot inherit a generic event-count projection by accident.
create or replace function esheep_cloud.client_projection_route_v2(
  p_kind text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_kind
    when 'attention.resolve' then 'attention.resolve'
    when 'batchMembership.assign' then 'batchMembership.assign'
    when 'batchMembership.leave' then 'batchMembership.leave'
    when 'batchMembership.restore' then 'batchMembership.restore'
    when 'breedingProgram.create' then 'breedingProgram.create'
    when 'care.careReminder.setStatus' then 'care.careReminder.setStatus'
    when 'care.careRules.update' then 'care.careRules.update'
    when 'care.health.correct' then 'care.health.correct'
    when 'care.health.recordBatch' then 'care.health.recordBatch'
    when 'care.healthCatalog.upsert' then 'care.healthCatalog.upsert'
    when 'care.inventory.adjust' then 'care.inventory.adjust'
    when 'care.inventory.receive' then 'care.inventory.receive'
    when 'care.inventoryLot.setActive' then 'care.inventoryLot.setActive'
    when 'care.lambing.correct' then 'care.lambing.correct'
    when 'care.lambing.record' then 'care.lambing.record'
    when 'care.lambing.restore' then 'care.lambing.restore'
    when 'care.lambing.revoke' then 'care.lambing.revoke'
    when 'care.operationalAlert.defer' then 'care.operationalAlert.defer'
    when 'care.operationalAlertRules.update' then 'care.operationalAlertRules.update'
    when 'care.reproduction.correct' then 'care.reproduction.correct'
    when 'care.reproduction.recordBatch' then 'care.reproduction.recordBatch'
    when 'care.semen.adjust' then 'care.semen.adjust'
    when 'care.semen.setDonor' then 'care.semen.setDonor'
    when 'care.semenDonor.upsert' then 'care.semenDonor.upsert'
    when 'care.sheep.setBreedingRam' then 'care.sheep.setBreedingRam'
    when 'care.sheep.setPurpose' then 'care.sheep.setPurpose'
    when 'care.sheepPedigree.restoreAudit' then 'care.sheepPedigree.restoreAudit'
    when 'care.sheepPedigree.update' then 'care.sheepPedigree.update'
    when 'farm.updateLocation' then 'farm.updateLocation'
    when 'feed.importHistorical' then 'feed.importHistorical'
    when 'feed.record' then 'feed.record'
    when 'feed.recordLegacy' then 'feed.recordLegacy'
    when 'feedBatch.save' then 'feedBatch.save'
    when 'feedIngredient.add' then 'feedIngredient.add'
    when 'feedIngredient.save' then 'feedIngredient.save'
    when 'feedRecipe.create' then 'feedRecipe.create'
    when 'feedRecipe.member.add' then 'feedRecipe.member.add'
    when 'feedRecipe.save' then 'feedRecipe.save'
    when 'feedStock.adjust' then 'feedStock.adjust'
    when 'feedStock.count' then 'feedStock.count'
    when 'feedTrough.record' then 'feedTrough.record'
    when 'health.record' then 'health.record'
    when 'inventory.receive' then 'inventory.receive'
    when 'note.add' then 'note.add'
    when 'pen.create' then 'pen.create'
    when 'pen.setActive' then 'pen.setActive'
    when 'pen.update' then 'pen.update'
    when 'photoAsset.recycle' then 'photoAsset.recycle'
    when 'photoAsset.register' then 'photoAsset.register'
    when 'photoAsset.restore' then 'photoAsset.restore'
    when 'productionBatch.create' then 'productionBatch.create'
    when 'record.restore' then 'record.restore'
    when 'record.revoke' then 'record.revoke'
    when 'removal.correct' then 'removal.correct'
    when 'removal.record' then 'removal.record'
    when 'removal.restore' then 'removal.restore'
    when 'reproduction.record' then 'reproduction.record'
    when 'semen.add' then 'semen.add'
    when 'sheep.add' then 'sheep.add'
    when 'sheep.patchProfile' then 'sheep.patchProfile'
    when 'sheepAvatar.clear' then 'sheepAvatar.clear'
    when 'sheepAvatar.set' then 'sheepAvatar.set'
    when 'tmr.acknowledgeTMRDeviation' then 'tmr.acknowledgeTMRDeviation'
    when 'tmr.adjustTMRBatch' then 'tmr.adjustTMRBatch'
    when 'tmr.closeTMRBatch' then 'tmr.closeTMRBatch'
    when 'tmr.completeTMRMeal' then 'tmr.completeTMRMeal'
    when 'tmr.correctTMRFeedingRun' then 'tmr.correctTMRFeedingRun'
    when 'tmr.deleteUnusedTMRBatch' then 'tmr.deleteUnusedTMRBatch'
    when 'tmr.produceTMRBatch' then 'tmr.produceTMRBatch'
    when 'tmr.recordTMRFeeding' then 'tmr.recordTMRFeeding'
    when 'tmr.reopenTMRMeal' then 'tmr.reopenTMRMeal'
    when 'tmr.reverseTMRFeedingRun' then 'tmr.reverseTMRFeedingRun'
    when 'tmr.saveTMRFeedingPlan' then 'tmr.saveTMRFeedingPlan'
    when 'tmr.saveTMRFormula' then 'tmr.saveTMRFormula'
    when 'tmr.saveTMRMonitoringRule' then 'tmr.saveTMRMonitoringRule'
    when 'transfer.correct' then 'transfer.correct'
    when 'transfer.record' then 'transfer.record'
    when 'weaning.record' then 'weaning.record'
    when 'weight.correct' then 'weight.correct'
    when 'weight.record' then 'weight.record'
    else null
  end;
$$;

-- Replace the legacy marker-based report with the executable capability
-- report.  The version columns are retained for old migration readers, but a
-- bulk UPDATE of those columns can no longer open the V2 gate.
create or replace function esheep_cloud.protocol_readiness_report_v2()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with capability as (
    select
      catalog.command_kind,
      esheep_cloud.server_handler_available_v2(catalog.command_kind) as server_ready,
      esheep_cloud.client_projection_route_v2(catalog.command_kind) is not null as client_ready
    from esheep_cloud.command_catalog catalog
  )
  select jsonb_build_object(
    'protocol_version', 2,
    'schema_version', 1,
    'ready', count(*) > 0 and count(*) filter (where server_ready and client_ready) = count(*),
    'declared_command_count', count(*),
    'implemented_command_count', count(*) filter (where server_ready and client_ready),
    'server_implemented_command_count', count(*) filter (where server_ready),
    'client_projected_command_count', count(*) filter (where client_ready),
    'incomplete_command_kinds', coalesce(
      jsonb_agg(command_kind order by command_kind) filter (where not (server_ready and client_ready)),
      '[]'::jsonb
    ),
    'missing_server_handler_kinds', coalesce(
      jsonb_agg(command_kind order by command_kind) filter (where not server_ready),
      '[]'::jsonb
    ),
    'missing_client_projection_kinds', coalesce(
      jsonb_agg(command_kind order by command_kind) filter (where not client_ready),
      '[]'::jsonb
    ),
    'manual_catalog_markers', count(*) filter (
      where handler_schema_version is not null or client_projection_schema_version is not null
    )
  )
  from capability
  join esheep_cloud.command_catalog catalog using (command_kind);
$$;

create or replace function esheep_cloud.event_digest(
  p_farm_id uuid,
  p_farm_generation integer,
  p_event_sequence bigint,
  p_event_id uuid,
  p_command_id uuid,
  p_stream_type text,
  p_stream_id uuid,
  p_affected_fields text[],
  p_event_body_digest text,
  p_before_digest text,
  p_after_digest text,
  p_actor_account_id uuid,
  p_source_device_id uuid,
  p_source_device_sequence bigint,
  p_occurred_at_millis bigint,
  p_received_at_millis bigint,
  p_source_command_digest text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select esheep_cloud.sha256_hex(convert_to(
    'esheep-cloud-event-v2' || chr(10) ||
    lower(p_farm_id::text) || chr(10) ||
    p_farm_generation::text || chr(10) ||
    p_event_sequence::text || chr(10) ||
    lower(p_event_id::text) || chr(10) ||
    lower(p_command_id::text) || chr(10) ||
    p_stream_type || chr(10) ||
    lower(p_stream_id::text) || chr(10) ||
    coalesce(array_to_string(
      (select array_agg(value order by value) from unnest(p_affected_fields) value),
      ','
    ), '') || chr(10) ||
    p_event_body_digest || chr(10) ||
    p_before_digest || chr(10) ||
    p_after_digest || chr(10) ||
    lower(p_actor_account_id::text) || chr(10) ||
    lower(p_source_device_id::text) || chr(10) ||
    p_source_device_sequence::text || chr(10) ||
    p_occurred_at_millis::text || chr(10) ||
    p_received_at_millis::text || chr(10) ||
    p_source_command_digest,
    'utf8'
  ));
$$;

create or replace function esheep_cloud.command_result_for_client(p_command_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select command.result
  from esheep_cloud.commands command
  where command.command_id = p_command_id
    and esheep_private.is_active_farm_member(
      command.farm_id,
      array['owner', 'administrator', 'worker']
    );
$$;

create or replace function esheep_cloud.process_command_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_user_id uuid,
  p_item jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unsigned bytea;
  v_unsigned_json jsonb;
  v_digest text := lower(coalesce(p_item ->> 'content_digest', ''));
  v_signature bytea;
  v_command_id uuid;
  v_source_request_id uuid;
  v_bundle_id uuid;
  v_account_id uuid;
  v_device_id uuid;
  v_device_sequence bigint;
  v_protocol_version integer;
  v_schema_version integer;
  v_kind text;
  v_created_at timestamptz;
  v_occurred_at timestamptz;
  v_affected_streams jsonb;
  v_affected_fields jsonb;
  v_field_changes jsonb;
  v_prerequisites uuid[];
  v_required_assets uuid[];
  v_role text;
  v_merge_mode text;
  v_allowed_roles text[];
  v_handler_key text;
  v_blocked_prerequisite_id uuid;
  v_blocked_asset_id uuid;
  v_photo_asset esheep_cloud.assets%rowtype;
  v_existing esheep_cloud.commands%rowtype;
  v_farm_state esheep_cloud.farm_state%rowtype;
  v_stream_type text;
  v_stream_id uuid;
  v_stream esheep_cloud.streams%rowtype;
  v_before_digest text;
  v_after_digest text;
  v_change jsonb;
  v_observation jsonb;
  v_field text;
  v_mutation jsonb;
  v_desired_value jsonb;
  v_desired_digest text;
  v_base_digest text;
  v_observed_version bigint;
  v_current_field jsonb;
  v_current_value jsonb;
  v_current_digest text;
  v_current_version bigint;
  v_current_device_id text;
  v_current_device_sequence bigint;
  v_device_field_watermark bigint;
  v_applied_changes jsonb := '[]'::jsonb;
  v_conflict_count integer := 0;
  v_attention_id uuid;
  v_first_attention_id uuid;
  v_affected_field_names text[] := '{}'::text[];
  v_event_sequence bigint;
  v_event_id uuid;
  v_event_sequences bigint[] := '{}'::bigint[];
  v_event_ids uuid[] := '{}'::uuid[];
  v_event_kind text;
  v_event_body jsonb;
  v_event_body_digest text;
  v_secondary_ref jsonb;
  v_secondary_stream_type text;
  v_secondary_stream_id uuid;
  v_secondary_stream esheep_cloud.streams%rowtype;
  v_secondary_before_digest text;
  v_secondary_after_digest text;
  v_secondary_event_sequence bigint;
  v_secondary_event_id uuid;
  v_secondary_event_digest text;
  v_received_at timestamptz := clock_timestamp();
  v_received_at_millis bigint;
  v_occurred_at_millis bigint;
  v_event_digest text;
  v_result jsonb;
  v_null_value jsonb := jsonb_build_object('type', 'null');
begin
  if p_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if jsonb_typeof(p_item) <> 'object' then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_wrapper_invalid';
  end if;

  begin
    v_unsigned := decode(p_item ->> 'unsigned_command_base64', 'base64');
    v_signature := decode(p_item ->> 'device_signature_base64', 'base64');
    v_unsigned_json := convert_from(v_unsigned, 'utf8')::jsonb;
  exception when others then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_encoding_invalid';
  end;
  if octet_length(v_signature) <> 64 then
    raise exception using errcode = '22023', message = 'esheep_cloud_device_signature_invalid';
  end if;
  if v_digest !~ '^[0-9a-f]{64}$' or esheep_cloud.sha256_hex(v_unsigned) <> v_digest then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_digest_mismatch';
  end if;

  begin
    v_command_id := (v_unsigned_json ->> 'commandID')::uuid;
    v_source_request_id := (v_unsigned_json ->> 'sourceRequestID')::uuid;
    v_bundle_id := nullif(v_unsigned_json ->> 'bundleID', '')::uuid;
    v_account_id := (v_unsigned_json ->> 'accountID')::uuid;
    v_device_id := (v_unsigned_json ->> 'deviceID')::uuid;
    v_device_sequence := (v_unsigned_json ->> 'deviceSequence')::bigint;
    v_protocol_version := (v_unsigned_json ->> 'protocolVersion')::integer;
    v_schema_version := (v_unsigned_json ->> 'schemaVersion')::integer;
    v_kind := v_unsigned_json ->> 'commandKind';
    v_created_at := to_timestamp((v_unsigned_json ->> 'createdAt')::numeric / 1000.0);
    v_occurred_at := to_timestamp((v_unsigned_json ->> 'occurredAt')::numeric / 1000.0);
    v_affected_streams := coalesce(v_unsigned_json -> 'affectedStreams', '[]'::jsonb);
    v_affected_fields := coalesce(v_unsigned_json -> 'affectedFields', '[]'::jsonb);
    v_field_changes := coalesce(v_unsigned_json -> 'fieldChanges', '[]'::jsonb);
    select coalesce(array_agg(value::uuid order by ordinality), '{}')
      into v_prerequisites
      from jsonb_array_elements_text(coalesce(v_unsigned_json -> 'prerequisiteCommandIDs', '[]'::jsonb)) with ordinality item(value, ordinality);
    select coalesce(array_agg(value::uuid order by ordinality), '{}')
      into v_required_assets
      from jsonb_array_elements_text(coalesce(v_unsigned_json -> 'requiredAssetIDs', '[]'::jsonb)) with ordinality item(value, ordinality);
  exception when others then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_contract_invalid';
  end;

  if v_protocol_version <> 2 or v_schema_version <> 1 then
    raise exception using errcode = '0A000', message = 'esheep_cloud_client_upgrade_required';
  end if;
  if (v_unsigned_json ->> 'farmID')::uuid <> p_farm_id or
     (v_unsigned_json ->> 'farmGeneration')::integer <> p_farm_generation then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_scope_mismatch';
  end if;
  perform esheep_cloud.validate_payload_contract_v2(
    v_kind,
    v_unsigned_json -> 'payload'
  );

  select member.role
  into v_role
  from public.farm_members member
  where member.farm_id = p_farm_id
    and member.user_id = p_user_id
    and member.app_account_id = v_account_id
    and member.status = 'active';
  if not found then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_write_denied';
  end if;
  if not exists (
    select 1
    from public.devices device
    where device.device_id = v_device_id
      and device.user_id = p_user_id
      and device.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_device_identity_mismatch';
  end if;

  select catalog.merge_mode, catalog.allowed_roles
  into v_merge_mode, v_allowed_roles
  from esheep_cloud.command_catalog catalog
  where catalog.command_kind = v_kind
    and catalog.current_schema_version = v_schema_version;
  if not found then
    raise exception using errcode = '0A000', message = 'esheep_cloud_command_kind_unknown';
  end if;
  perform esheep_cloud.validate_command_semantics_v2(
    v_kind,
    v_unsigned_json -> 'payload',
    v_merge_mode,
    v_affected_streams,
    v_affected_fields,
    v_field_changes
  );
  v_handler_key := esheep_cloud.dispatch_command_v2(
    v_kind,
    v_unsigned_json -> 'payload',
    v_merge_mode,
    v_affected_streams
  );
  if esheep_cloud.client_projection_route_v2(v_kind) is null then
    raise exception using errcode = '0A000', message = 'esheep_cloud_client_projection_unavailable';
  end if;
  if not (v_role = any(v_allowed_roles)) then
    raise exception using errcode = '42501', message = 'esheep_cloud_command_permission_denied';
  end if;

  select * into v_existing
  from esheep_cloud.commands command
  where command.command_id = v_command_id
  for update;
  if found then
    if v_existing.content_digest <> v_digest or
       v_existing.farm_id <> p_farm_id or
       v_existing.farm_generation <> p_farm_generation or
       v_existing.source_request_id <> v_source_request_id or
       v_existing.bundle_id is distinct from v_bundle_id or
       v_existing.account_id <> v_account_id or
       v_existing.device_id <> v_device_id or
       v_existing.device_sequence <> v_device_sequence or
       v_existing.protocol_version <> v_protocol_version or
       v_existing.schema_version <> v_schema_version or
       v_existing.command_kind <> v_kind then
      return jsonb_build_object(
        'command_id', v_command_id,
        'type', 'rejected',
        'reason', jsonb_build_object(
          'code', 'command_id_digest_mismatch',
          'message', '同一操作标识对应了不同内容或范围，已停止保存。'
        )
      );
    end if;
    return jsonb_build_object(
      'command_id', v_command_id,
      'type', 'duplicate',
      'original', v_existing.result
    );
  end if;

  select * into v_farm_state
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id
  for update;
  if not found or v_farm_state.farm_generation <> p_farm_generation or
     v_farm_state.status <> 'active' or not v_farm_state.v2_ready then
    raise exception using errcode = '55000', message = 'esheep_cloud_farm_not_writable';
  end if;
  if v_farm_state.write_frozen then
    raise exception using errcode = '55000', message = 'esheep_cloud_integrity_hold';
  end if;

  -- Two retries for the same command can pass the initial lookup before
  -- either transaction commits.  The farm lock is the serialization point;
  -- re-read the command after acquiring it so the loser returns the original
  -- result instead of colliding with the primary-key constraint and being
  -- misreported as a malformed request.
  select * into v_existing
  from esheep_cloud.commands command
  where command.command_id = v_command_id
  for update;
  if found then
    if v_existing.content_digest <> v_digest or
       v_existing.farm_id <> p_farm_id or
       v_existing.farm_generation <> p_farm_generation or
       v_existing.source_request_id <> v_source_request_id or
       v_existing.bundle_id is distinct from v_bundle_id or
       v_existing.account_id <> v_account_id or
       v_existing.device_id <> v_device_id or
       v_existing.device_sequence <> v_device_sequence or
       v_existing.protocol_version <> v_protocol_version or
       v_existing.schema_version <> v_schema_version or
       v_existing.command_kind <> v_kind then
      return jsonb_build_object(
        'command_id', v_command_id,
        'type', 'rejected',
        'reason', jsonb_build_object(
          'code', 'command_id_digest_mismatch',
          'message', '同一操作标识对应了不同内容或范围，已停止保存。'
        )
      );
    end if;
    return jsonb_build_object(
      'command_id', v_command_id,
      'type', 'duplicate',
      'original', v_existing.result
    );
  end if;

  -- sourceRequestID is also immutable within a farm.  A different command
  -- reusing it is a client ledger error, not a second business operation.
  select * into v_existing
  from esheep_cloud.commands command
  where command.farm_id = p_farm_id
    and command.source_request_id = v_source_request_id
  for update;
  if found then
    return jsonb_build_object(
      'command_id', v_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'source_request_reused',
        'message', '这项操作的来源编号已经用于另一项保存请求。'
      )
    );
  end if;

  if exists (
    select 1 from esheep_cloud.commands command
    where command.farm_id = p_farm_id
      and command.farm_generation = p_farm_generation
      and command.device_id = v_device_id
      and command.device_sequence = v_device_sequence
  ) then
    raise exception using errcode = '23505', message = 'esheep_cloud_device_sequence_reused';
  end if;
  select prerequisite.command_id
  into v_blocked_prerequisite_id
  from unnest(v_prerequisites) prerequisite(command_id)
    left join esheep_cloud.commands command on command.command_id = prerequisite.command_id
    where command.command_id is null
       or command.status <> 'accepted'
       or command.farm_id <> p_farm_id
       or command.farm_generation <> p_farm_generation
       or command.account_id <> v_account_id
  order by prerequisite.command_id
  limit 1;
  if found then
    return jsonb_build_object(
      'command_id', v_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'prerequisite_not_ready',
        'command_id', v_blocked_prerequisite_id,
        'message', '前一步操作尚未完成。'
      )
    );
  end if;
  select required.asset_id
  into v_blocked_asset_id
  from unnest(v_required_assets) required(asset_id)
    left join esheep_cloud.assets asset
      on asset.asset_id = required.asset_id
     and asset.farm_id = p_farm_id
     and asset.farm_generation = p_farm_generation
    where asset.asset_id is null
       or (asset.avatar_state <> 'verified' and asset.original_state <> 'verified')
  order by required.asset_id
  limit 1;
  if found then
    return jsonb_build_object(
      'command_id', v_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'asset_not_ready',
        'asset_id', v_blocked_asset_id,
        'message', '照片仍在安全保存中。'
      )
    );
  end if;

  if jsonb_array_length(v_affected_streams) = 0 then
    raise exception using errcode = '22023', message = 'esheep_cloud_affected_stream_missing';
  end if;
  v_stream_type := v_affected_streams -> 0 ->> 'type';
  v_stream_id := (v_affected_streams -> 0 ->> 'id')::uuid;

  if v_kind = 'photoAsset.register' then
    if jsonb_array_length(v_affected_streams) <> 1
      or v_stream_type <> 'photoAsset'
      or (v_unsigned_json #>> '{payload,body,register,assetID}')::uuid <> v_stream_id
      or jsonb_array_length(v_affected_fields) <> 0
      or jsonb_array_length(v_field_changes) <> 0
      or cardinality(v_required_assets) <> 1
      or v_required_assets[1] <> v_stream_id
      or lower(v_unsigned_json #>> '{payload,body,register,contentSHA256}') !~ '^[0-9a-f]{64}$'
      or lower(v_unsigned_json #>> '{payload,body,register,metadataDigest}') !~ '^[0-9a-f]{64}$'
      or lower(v_unsigned_json #>> '{payload,body,register,thumbnailSHA256}') !~ '^[0-9a-f]{64}$'
      or lower(v_unsigned_json #>> '{payload,body,register,avatarSHA256}') !~ '^[0-9a-f]{64}$'
      or lower(v_unsigned_json #>> '{payload,body,register,originalSHA256}') <>
        lower(v_unsigned_json #>> '{payload,body,register,contentSHA256}')
      or (v_unsigned_json #>> '{payload,body,register,mimeType}')
        not in ('image/heic', 'image/jpeg')
      or jsonb_typeof(v_unsigned_json #> '{payload,body,register,metadata}') <> 'object'
      or esheep_cloud.json_digest(v_unsigned_json #> '{payload,body,register,metadata}') <>
        lower(v_unsigned_json #>> '{payload,body,register,metadataDigest}')
      or (v_unsigned_json #>> '{payload,body,register,metadata,mimeType}') <>
        (v_unsigned_json #>> '{payload,body,register,mimeType}')
      or lower(v_unsigned_json #>> '{payload,body,register,metadata,sourceSHA256}')
        !~ '^[0-9a-f]{64}$'
      or (v_unsigned_json #>> '{payload,body,register,metadata,sourcePixelWidth}')
        !~ '^[1-9][0-9]*$'
      or (v_unsigned_json #>> '{payload,body,register,metadata,sourcePixelHeight}')
        !~ '^[1-9][0-9]*$'
      or (v_unsigned_json #>> '{payload,body,register,metadata,cloudPixelWidth}')
        !~ '^[1-9][0-9]*$'
      or (v_unsigned_json #>> '{payload,body,register,metadata,cloudPixelHeight}')
        !~ '^[1-9][0-9]*$'
      or (v_unsigned_json #>> '{payload,body,register,metadata,capturedAtMillis}')
        is distinct from (v_unsigned_json #>> '{payload,body,register,capturedAt}')
      or (v_unsigned_json #>> '{payload,body,register,thumbnailByteCount}')::bigint <= 0
      or (v_unsigned_json #>> '{payload,body,register,avatarByteCount}')::bigint <= 0
      or (v_unsigned_json #>> '{payload,body,register,originalByteCount}')::bigint <= 0 then
      raise exception using errcode = '22023', message = 'esheep_cloud_photo_contract_invalid';
    end if;
    select * into v_photo_asset
    from esheep_cloud.assets asset
    where asset.asset_id = v_stream_id
      and asset.farm_id = p_farm_id
      and asset.farm_generation = p_farm_generation
    for update;
    if not found
      or v_photo_asset.content_sha256 <>
        lower(v_unsigned_json #>> '{payload,body,register,contentSHA256}')
      or v_photo_asset.original_byte_count <>
        (v_unsigned_json #>> '{payload,body,register,originalByteCount}')::bigint
      or v_photo_asset.thumbnail_byte_count <>
        (v_unsigned_json #>> '{payload,body,register,thumbnailByteCount}')::bigint
      or v_photo_asset.avatar_byte_count <>
        (v_unsigned_json #>> '{payload,body,register,avatarByteCount}')::bigint
      or v_photo_asset.thumbnail_sha256 <>
        lower(v_unsigned_json #>> '{payload,body,register,thumbnailSHA256}')
      or v_photo_asset.avatar_sha256 <>
        lower(v_unsigned_json #>> '{payload,body,register,avatarSHA256}')
      or v_photo_asset.original_sha256 <>
        lower(v_unsigned_json #>> '{payload,body,register,originalSHA256}')
      or v_photo_asset.sheep_id is distinct from
        nullif(v_unsigned_json #>> '{payload,body,register,sheepID}', '')::uuid
      or v_photo_asset.metadata <>
        (v_unsigned_json #> '{payload,body,register,metadata}')
      or v_photo_asset.metadata_digest <>
        lower(v_unsigned_json #>> '{payload,body,register,metadataDigest}')
      or coalesce(v_photo_asset.metadata ->> 'mimeType', '') <>
        (v_unsigned_json #>> '{payload,body,register,mimeType}')
      or v_photo_asset.thumbnail_state <> 'verified'
      or v_photo_asset.avatar_state <> 'verified'
      or v_photo_asset.original_state <> 'verified' then
      raise exception using errcode = '55000', message = 'esheep_cloud_photo_asset_not_verified';
    end if;
    if v_photo_asset.sheep_id is not null and not exists (
      select 1 from esheep_cloud.streams sheep_stream
      where sheep_stream.farm_id = p_farm_id
        and sheep_stream.farm_generation = p_farm_generation
        and sheep_stream.stream_id = v_photo_asset.sheep_id
        and sheep_stream.stream_type in ('sheep', 'sheepProfile')
    ) then
      raise exception using errcode = '23503', message = 'esheep_cloud_photo_sheep_missing';
    end if;
  end if;

  if v_kind in ('photoAsset.recycle', 'photoAsset.restore') then
    if cardinality(v_required_assets) <> 0 then
      raise exception using errcode = '22023', message = 'esheep_cloud_photo_lifecycle_assets_invalid';
    end if;
    select * into v_photo_asset
    from esheep_cloud.assets asset
    where asset.asset_id = v_stream_id
      and asset.farm_id = p_farm_id
      and asset.farm_generation = p_farm_generation
    for update;
    if not found then
      raise exception using errcode = '23503', message = 'esheep_cloud_photo_asset_missing';
    end if;
    if v_kind = 'photoAsset.recycle' then
      -- A photo that is still the selected avatar cannot disappear behind the
      -- asset lifecycle. The caller must first submit an explicit avatar
      -- clear/replace command, which leaves a visible business event.
      if exists (
        select 1
        from esheep_cloud.streams avatar_stream
        where avatar_stream.farm_id = p_farm_id
          and avatar_stream.farm_generation = p_farm_generation
          and avatar_stream.stream_type = 'sheepAvatar'
          and lower(avatar_stream.canonical_state #>> '{avatar,value}') = lower(v_stream_id::text)
      ) then
        raise exception using errcode = '23514', message = 'esheep_cloud_photo_avatar_reference_exists';
      end if;
      if v_photo_asset.thumbnail_state = 'deleted'
         or v_photo_asset.avatar_state = 'deleted'
         or v_photo_asset.original_state = 'deleted' then
        raise exception using errcode = '55000', message = 'esheep_cloud_photo_asset_permanently_deleted';
      end if;
      update esheep_cloud.assets
      set thumbnail_state = 'recycle_bin',
          avatar_state = 'recycle_bin',
          original_state = 'recycle_bin',
          recycle_expires_at = v_received_at + interval '30 days',
          updated_at = v_received_at
      where asset_id = v_stream_id
        and farm_id = p_farm_id
        and farm_generation = p_farm_generation;
    else
      if v_photo_asset.thumbnail_state <> 'recycle_bin'
         and v_photo_asset.avatar_state <> 'recycle_bin'
         and v_photo_asset.original_state <> 'recycle_bin' then
        raise exception using errcode = '55000', message = 'esheep_cloud_photo_asset_not_recyclable';
      end if;
      update esheep_cloud.assets
      set thumbnail_state = 'verified',
          avatar_state = 'verified',
          original_state = 'verified',
          recycle_expires_at = null,
          updated_at = v_received_at
      where asset_id = v_stream_id
        and farm_id = p_farm_id
        and farm_generation = p_farm_generation;
    end if;
  end if;

  insert into esheep_cloud.commands (
    command_id, farm_id, farm_generation, source_request_id, bundle_id,
    actor_user_id, account_id, device_id, device_sequence,
    protocol_version, schema_version, command_kind, occurred_at,
    client_created_at, unsigned_command, content_digest, device_signature,
    affected_streams, affected_fields, field_changes,
    prerequisite_command_ids, required_asset_ids, status, result,
    server_received_at, completed_at
  ) values (
    v_command_id, p_farm_id, p_farm_generation, v_source_request_id, v_bundle_id,
    p_user_id, v_account_id, v_device_id, v_device_sequence,
    v_protocol_version, v_schema_version, v_kind, v_occurred_at,
    v_created_at, v_unsigned, v_digest, v_signature,
    v_affected_streams, v_affected_fields, v_field_changes,
    v_prerequisites, v_required_assets, 'processing', jsonb_build_object('type', 'processing'),
    v_received_at, v_received_at
  );

  insert into esheep_cloud.streams (
    farm_id, farm_generation, stream_type, stream_id, content_digest
  ) values (
    p_farm_id, p_farm_generation, v_stream_type, v_stream_id,
    esheep_cloud.json_digest('{}'::jsonb)
  ) on conflict do nothing;
  select * into v_stream
  from esheep_cloud.streams stream
  where stream.farm_id = p_farm_id
    and stream.farm_generation = p_farm_generation
    and stream.stream_type = v_stream_type
    and stream.stream_id = v_stream_id
  for update;
  v_before_digest := v_stream.content_digest;

  if v_merge_mode = 'field_patch' then
    if jsonb_array_length(v_field_changes) = 0 or
       jsonb_array_length(v_affected_fields) = 0 then
      raise exception using errcode = '22023', message = 'esheep_cloud_field_patch_missing';
    end if;
    if (select count(*) from jsonb_array_elements(v_field_changes)) <>
       (select count(distinct value ->> 'field') from jsonb_array_elements(v_field_changes)) then
      raise exception using errcode = '22023', message = 'esheep_cloud_field_patch_duplicate';
    end if;
    if (select count(*) from jsonb_array_elements(v_affected_fields)
        where value -> 'stream' ->> 'type' = v_stream_type
          and (value -> 'stream' ->> 'id')::uuid = v_stream_id) <>
       jsonb_array_length(v_field_changes)
       or exists (
         select 1
         from jsonb_array_elements(v_field_changes) change
         where not exists (
           select 1
           from jsonb_array_elements(v_affected_fields) observation
           where observation.value ->> 'field' = change.value ->> 'field'
             and observation.value -> 'stream' ->> 'type' = v_stream_type
             and (observation.value -> 'stream' ->> 'id')::uuid = v_stream_id
         )
       ) then
      raise exception using errcode = '22023', message = 'esheep_cloud_field_observation_set_mismatch';
    end if;

    if v_kind = 'farm.updateLocation' then
      if v_stream_type <> 'farm' or v_stream_id <> p_farm_id
         or exists (
           select 1 from jsonb_array_elements(v_field_changes) change
           where change.value ->> 'field' <> all(array[
             'displayName', 'latitude', 'longitude', 'addressSnapshot',
             'timeZoneIdentifier', 'locationSource', 'horizontalAccuracyMeters'
           ])
         ) then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_scope_invalid';
      end if;
    elsif v_kind = 'pen.update' then
      if v_stream_type <> 'pen'
         or (v_unsigned_json #>> '{payload,body,update,penID}')::uuid <> v_stream_id
         or exists (
           select 1 from jsonb_array_elements(v_field_changes) change
           where change.value ->> 'field' <> all(array['name', 'note'])
         ) then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_scope_invalid';
      end if;
    elsif v_kind = 'pen.setActive' then
      if v_stream_type <> 'pen'
         or (v_unsigned_json #>> '{payload,body,setActive,penID}')::uuid <> v_stream_id
         or jsonb_array_length(v_field_changes) <> 1
         or v_field_changes -> 0 ->> 'field' <> 'isActive' then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_scope_invalid';
      end if;
    elsif v_kind = 'sheep.patchProfile' then
      if v_stream_type <> 'sheepProfile'
         or (v_unsigned_json #>> '{payload,body,patchProfile,sheepID}')::uuid <> v_stream_id
         or not ((v_unsigned_json #> '{payload,body,patchProfile,fields}') @> v_field_changes)
         or not (v_field_changes @> (v_unsigned_json #> '{payload,body,patchProfile,fields}'))
         or exists (
           select 1 from jsonb_array_elements(v_field_changes) change
           where change.value ->> 'field' <> all(array[
             'earTag', 'breed', 'sex', 'birthAt', 'currentParity',
             'parityRecordedAt', 'note'
           ])
         ) then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_scope_invalid';
      end if;
    elsif v_kind = 'sheepAvatar.set' then
      if v_stream_type <> 'sheepAvatar'
         or (v_unsigned_json #>> '{payload,body,setAvatar,sheepID}')::uuid <> v_stream_id
         or jsonb_array_length(v_field_changes) <> 1
         or v_field_changes -> 0 ->> 'field' <> 'avatar'
         or v_field_changes #>> '{0,mutation,action}' <> 'set'
         or v_field_changes #>> '{0,mutation,value,type}' <> 'identifier'
         or (v_field_changes #>> '{0,mutation,value,value}')::uuid <>
            (v_unsigned_json #>> '{payload,body,setAvatar,photoAssetID}')::uuid
         or cardinality(v_required_assets) <> 1
         or v_required_assets[1] <>
            (v_unsigned_json #>> '{payload,body,setAvatar,photoAssetID}')::uuid then
        raise exception using errcode = '22023', message = 'esheep_cloud_avatar_contract_invalid';
      end if;
    elsif v_kind = 'sheepAvatar.clear' then
      if v_stream_type <> 'sheepAvatar'
         or (v_unsigned_json #>> '{payload,body,clearAvatar,sheepID}')::uuid <> v_stream_id
         or jsonb_array_length(v_field_changes) <> 1
         or v_field_changes -> 0 ->> 'field' <> 'avatar'
         or v_field_changes #>> '{0,mutation,action}' <> 'clear'
         or cardinality(v_required_assets) <> 0 then
        raise exception using errcode = '22023', message = 'esheep_cloud_avatar_contract_invalid';
      end if;
    else
      raise exception using errcode = '0A000', message = 'esheep_cloud_field_handler_missing';
    end if;

    for v_change in select value from jsonb_array_elements(v_field_changes)
    loop
      v_field := v_change ->> 'field';
      v_mutation := v_change -> 'mutation';
      if v_mutation ->> 'action' = 'clear' then
        v_desired_value := v_null_value;
      elsif v_mutation ->> 'action' = 'set' then
        v_desired_value := v_mutation -> 'value';
      else
        raise exception using errcode = '22023', message = 'esheep_cloud_field_mutation_invalid';
      end if;
      v_desired_digest := esheep_cloud.value_digest(v_desired_value);

      select value into v_observation
      from jsonb_array_elements(v_affected_fields)
      where value ->> 'field' = v_field
        and value -> 'stream' ->> 'type' = v_stream_type
        and (value -> 'stream' ->> 'id')::uuid = v_stream_id
      limit 1;
      if v_observation is null then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_observation_missing';
      end if;
      v_observed_version := (v_observation ->> 'observedVersion')::bigint;
      if v_observed_version < 0 then
        raise exception using errcode = '22023', message = 'esheep_cloud_observed_version_invalid';
      end if;
      v_base_digest := lower(v_observation ->> 'baseValueDigest');
      if v_base_digest !~ '^[0-9a-f]{64}$' then
        raise exception using errcode = '22023', message = 'esheep_cloud_base_value_digest_invalid';
      end if;

      select watermark.highest_device_sequence
      into v_device_field_watermark
      from esheep_cloud.field_device_watermarks watermark
      where watermark.farm_id = p_farm_id
        and watermark.farm_generation = p_farm_generation
        and watermark.stream_type = v_stream_type
        and watermark.stream_id = v_stream_id
        and watermark.field_key = v_field
        and watermark.device_id = v_device_id
      for update;
      if found and v_device_sequence < v_device_field_watermark then
        -- This device has already expressed a causally later intent for this
        -- exact field. Other devices may have edited the field since then,
        -- but that cannot make this older device intent current again.
        continue;
      elsif found and v_device_sequence = v_device_field_watermark then
        -- An identical command would have returned from the command ledger
        -- above. Reaching this branch means immutable device sequencing was
        -- violated or the watermark ledger is inconsistent.
        raise exception using errcode = '23505', message = 'esheep_cloud_field_device_sequence_reused';
      end if;

      -- A later intent from one device supersedes that device's older open
      -- proposal for the same field. Decisions from other devices remain
      -- visible; no user choice is discarded across device boundaries.
      update esheep_cloud.attention_items item
      set status = 'obsolete',
          resolved_at = v_received_at,
          updated_at = v_received_at
      where item.farm_id = p_farm_id
        and item.farm_generation = p_farm_generation
        and item.stream_type = v_stream_type
        and item.stream_id = v_stream_id
        and item.field_key = v_field
        and item.device_id = v_device_id
        and item.status = 'open';

      v_current_field := v_stream.field_versions -> v_field;
      v_current_version := coalesce((v_current_field ->> 'version')::bigint, 0);
      v_current_value := coalesce(v_current_field -> 'value', v_null_value);
      v_current_digest := coalesce(v_current_field ->> 'value_digest', esheep_cloud.value_digest(v_null_value));
      v_current_device_id := lower(coalesce(v_current_field ->> 'device_id', ''));
      begin
        v_current_device_sequence := nullif(
          v_current_field ->> 'device_sequence',
          ''
        )::bigint;
      exception when others then
        raise exception using errcode = '22023', message = 'esheep_cloud_field_version_invalid';
      end;

      if v_desired_digest = v_current_digest or v_desired_digest = v_base_digest then
        -- Same value converges. A full-profile command that did not actually
        -- change this field also leaves a newer cloud value untouched.
        null;
      elsif (
        v_observed_version = v_current_version and v_base_digest = v_current_digest
      ) or (
        v_current_device_id = lower(v_device_id::text)
        and v_current_device_sequence is not null
        and v_device_sequence > v_current_device_sequence
      ) then
        -- Commands from one registered device are causally ordered by their
        -- immutable device sequence. This lets an already-sent
        -- set -> clear -> restore chain converge even when its earlier event
        -- acknowledgement was delayed. It never merges two devices this way.
        v_stream.canonical_state := jsonb_set(
          v_stream.canonical_state,
          array[v_field],
          v_desired_value,
          true
        );
        v_stream.field_versions := jsonb_set(
          v_stream.field_versions,
          array[v_field],
          jsonb_build_object(
            'version', v_current_version + 1,
            'value_digest', v_desired_digest,
            'value', v_desired_value,
            'account_id', v_account_id,
            'device_id', v_device_id,
            'device_sequence', v_device_sequence,
            'occurred_at', v_occurred_at,
            'received_at', v_received_at
          ),
          true
        );
        v_applied_changes := v_applied_changes || jsonb_build_array(jsonb_build_object(
          'field', v_field,
          'value', v_desired_value,
          'value_digest', v_desired_digest,
          'field_version', v_current_version + 1
        ));
        v_affected_field_names := array_append(v_affected_field_names, v_field);

        -- An open decision must always show the current standard value. If a
        -- later accepted command already reaches the waiting device value,
        -- the old decision becomes obsolete without asking the user to choose
        -- between two identical outcomes.
        update esheep_cloud.attention_items item
        set status = 'obsolete',
            resolved_at = v_received_at,
            updated_at = v_received_at
        where item.farm_id = p_farm_id
          and item.farm_generation = p_farm_generation
          and item.stream_type = v_stream_type
          and item.stream_id = v_stream_id
          and item.field_key = v_field
          and item.status = 'open'
          and item.device_value = v_desired_value;
        update esheep_cloud.attention_items item
        set cloud_value = v_desired_value,
            cloud_account_id = v_account_id,
            cloud_device_id = v_device_id,
            cloud_received_at = v_received_at,
            updated_at = v_received_at
        where item.farm_id = p_farm_id
          and item.farm_generation = p_farm_generation
          and item.stream_type = v_stream_type
          and item.stream_id = v_stream_id
          and item.field_key = v_field
          and item.status = 'open';
      elsif v_current_device_id = lower(v_device_id::text)
        and v_current_device_sequence is not null
        and v_device_sequence < v_current_device_sequence then
        -- A delayed older command from this same device is already superseded
        -- by a causally later field value. Record the immutable command result
        -- below, but do not append an event or ask the user to decide again.
        null;
      else
        insert into esheep_cloud.attention_items (
          farm_id, farm_generation, command_id, stream_type, stream_id,
          record_type, record_id, record_display_name, field_key,
          field_display_name, base_value_digest, device_value, cloud_value,
          device_account_id, device_id, device_occurred_at,
          cloud_account_id, cloud_device_id, cloud_received_at, explanation
        ) values (
          p_farm_id, p_farm_generation, v_command_id, v_stream_type, v_stream_id,
          v_stream_type, v_stream_id,
          esheep_cloud.record_display_name_v2(
            p_farm_id, p_farm_generation, v_stream_type, v_stream_id
          ),
          v_field,
          esheep_cloud.field_display_name(v_field), v_base_digest,
          v_desired_value, v_current_value,
          v_account_id, v_device_id, v_occurred_at,
          nullif(v_current_field ->> 'account_id', '')::uuid,
          nullif(v_current_field ->> 'device_id', '')::uuid,
          nullif(v_current_field ->> 'received_at', '')::timestamptz,
          '这台设备和 eSheep+ 云都修改了同一个字段，无法在不替你做决定的情况下自动合并。'
        ) returning attention_id into v_attention_id;
        v_first_attention_id := coalesce(v_first_attention_id, v_attention_id);
        v_conflict_count := v_conflict_count + 1;
      end if;

      insert into esheep_cloud.field_device_watermarks (
        farm_id, farm_generation, stream_type, stream_id, field_key,
        device_id, highest_device_sequence, command_id,
        desired_value_digest, updated_at
      ) values (
        p_farm_id, p_farm_generation, v_stream_type, v_stream_id, v_field,
        v_device_id, v_device_sequence, v_command_id,
        v_desired_digest, v_received_at
      ) on conflict (
        farm_id, farm_generation, stream_type, stream_id, field_key, device_id
      ) do update set
        highest_device_sequence = excluded.highest_device_sequence,
        command_id = excluded.command_id,
        desired_value_digest = excluded.desired_value_digest,
        updated_at = excluded.updated_at
      where esheep_cloud.field_device_watermarks.highest_device_sequence <
        excluded.highest_device_sequence;
    end loop;

    if jsonb_array_length(v_applied_changes) > 0 then
      v_stream.stream_version := v_stream.stream_version + 1;
      v_stream.content_digest := esheep_cloud.json_digest(v_stream.canonical_state);
      v_stream.updated_at := v_received_at;
      v_after_digest := v_stream.content_digest;
      v_event_kind := 'fields_patched';
      v_event_body := jsonb_build_object(
        'command_kind', v_kind,
        'handler_key', v_handler_key,
        'command_payload', v_unsigned_json -> 'payload',
        'affected_streams', v_affected_streams,
        'changes', v_applied_changes
      );
    else
      v_after_digest := v_before_digest;
    end if;
  else
    -- Facts, ledgers, OR-sets and state-machine commands are represented by
    -- immutable events. Their command kind is fail-closed by command_catalog;
    -- prerequisite, resource, role and generation checks have already run.
    v_stream.canonical_state := jsonb_build_object(
      'eventCount', v_stream.stream_version + 1,
      'lastCommandDigest', v_digest,
      'lastCommandID', lower(v_command_id::text),
      'lastCommandKind', v_kind
    );
    v_stream.stream_version := v_stream.stream_version + 1;
    v_stream.content_digest := esheep_cloud.json_digest(v_stream.canonical_state);
    v_stream.updated_at := v_received_at;
    v_after_digest := v_stream.content_digest;
    v_event_kind := v_merge_mode;
    v_event_body := jsonb_build_object(
      'command_kind', v_kind,
      'handler_key', v_handler_key,
      'command_digest', v_digest,
      'command_payload', v_unsigned_json -> 'payload',
      'affected_streams', v_affected_streams
    );
  end if;

  if v_after_digest <> v_before_digest then
    update esheep_cloud.farm_state
    set event_head = event_head + 1,
        updated_at = v_received_at
    where farm_id = p_farm_id
    returning event_head into v_event_sequence;
    v_event_id := gen_random_uuid();
    v_received_at_millis := round(extract(epoch from v_received_at) * 1000)::bigint;
    v_occurred_at_millis := round(extract(epoch from v_occurred_at) * 1000)::bigint;
    v_event_body_digest := esheep_cloud.json_digest(v_event_body);
    v_event_digest := esheep_cloud.event_digest(
      p_farm_id, p_farm_generation, v_event_sequence, v_event_id,
      v_command_id, v_stream_type, v_stream_id, v_affected_field_names,
      v_event_body_digest, v_before_digest, v_after_digest,
      v_account_id, v_device_id,
      v_device_sequence,
      v_occurred_at_millis, v_received_at_millis, v_digest
    );
    insert into esheep_cloud.events (
      farm_id, farm_generation, event_sequence, event_id, command_id,
      source_command_digest, stream_type, stream_id, event_kind, event_body,
      event_body_digest, affected_fields, before_digest, after_digest, actor_account_id,
      source_device_id, source_device_sequence,
      occurred_at, received_at, event_digest
    ) values (
      p_farm_id, p_farm_generation, v_event_sequence, v_event_id, v_command_id,
      v_digest, v_stream_type, v_stream_id, v_event_kind, v_event_body,
      v_event_body_digest, v_affected_field_names,
      v_before_digest, v_after_digest, v_account_id,
      v_device_id, v_device_sequence,
      v_occurred_at, v_received_at, v_event_digest
    );
    v_event_sequences := array_append(v_event_sequences, v_event_sequence);
    v_event_ids := array_append(v_event_ids, v_event_id);
    update esheep_cloud.farm_state
    set projection_digest = esheep_cloud.sha256_hex(convert_to(
          projection_digest || chr(10) || v_event_digest,
          'utf8'
        )),
        updated_at = v_received_at
    where farm_id = p_farm_id
      and farm_generation = p_farm_generation;
    v_stream.last_event_sequence := v_event_sequence;
    update esheep_cloud.streams
    set stream_version = v_stream.stream_version,
        field_versions = v_stream.field_versions,
        canonical_state = v_stream.canonical_state,
        content_digest = v_stream.content_digest,
        last_event_sequence = v_stream.last_event_sequence,
        updated_at = v_received_at
    where farm_id = p_farm_id
      and farm_generation = p_farm_generation
      and stream_type = v_stream_type
      and stream_id = v_stream_id;

    -- A command may carry semantic lanes in addition to its concrete record
    -- lane (for example transfer + sheepLocation, or removal + sheepPresence).
    -- They are not extra commands: every lane is advanced here under the same
    -- farm lock and receives its own contiguous event. A device can therefore
    -- replay the complete command in event-sequence order without guessing
    -- which secondary projection was implied by the payload.
    if v_merge_mode <> 'field_patch'
       and jsonb_array_length(v_affected_streams) > 1 then
      for v_secondary_ref in
        select stream.value
        from jsonb_array_elements(v_affected_streams) with ordinality as stream(value, ordinality)
        where stream.ordinality > 1
      loop
        v_secondary_stream_type := v_secondary_ref ->> 'type';
        v_secondary_stream_id := (v_secondary_ref ->> 'id')::uuid;
        insert into esheep_cloud.streams (
          farm_id, farm_generation, stream_type, stream_id, content_digest
        ) values (
          p_farm_id, p_farm_generation, v_secondary_stream_type, v_secondary_stream_id,
          esheep_cloud.json_digest('{}'::jsonb)
        ) on conflict do nothing;
        select * into v_secondary_stream
        from esheep_cloud.streams stream
        where stream.farm_id = p_farm_id
          and stream.farm_generation = p_farm_generation
          and stream.stream_type = v_secondary_stream_type
          and stream.stream_id = v_secondary_stream_id
        for update;
        if not found then
          raise exception using errcode = '55000', message = 'esheep_cloud_secondary_stream_missing';
        end if;
        v_secondary_before_digest := v_secondary_stream.content_digest;
        v_secondary_stream.canonical_state := jsonb_build_object(
          'eventCount', v_secondary_stream.stream_version + 1,
          'lastCommandDigest', v_digest,
          'lastCommandID', lower(v_command_id::text),
          'lastCommandKind', v_kind
        );
        v_secondary_stream.stream_version := v_secondary_stream.stream_version + 1;
        v_secondary_stream.content_digest := esheep_cloud.json_digest(
          v_secondary_stream.canonical_state
        );
        v_secondary_stream.updated_at := v_received_at;
        v_secondary_after_digest := v_secondary_stream.content_digest;

        update esheep_cloud.farm_state
        set event_head = event_head + 1,
            updated_at = v_received_at
        where farm_id = p_farm_id
        returning event_head into v_secondary_event_sequence;
        v_secondary_event_id := gen_random_uuid();
        v_secondary_event_digest := esheep_cloud.event_digest(
          p_farm_id, p_farm_generation, v_secondary_event_sequence,
          v_secondary_event_id, v_command_id, v_secondary_stream_type,
          v_secondary_stream_id, v_affected_field_names, v_event_body_digest,
          v_secondary_before_digest, v_secondary_after_digest, v_account_id,
          v_device_id, v_device_sequence, v_occurred_at_millis,
          v_received_at_millis, v_digest
        );
        insert into esheep_cloud.events (
          farm_id, farm_generation, event_sequence, event_id, command_id,
          source_command_digest, stream_type, stream_id, event_kind, event_body,
          event_body_digest, affected_fields, before_digest, after_digest,
          actor_account_id, source_device_id, source_device_sequence,
          occurred_at, received_at, event_digest
        ) values (
          p_farm_id, p_farm_generation, v_secondary_event_sequence,
          v_secondary_event_id, v_command_id, v_digest,
          v_secondary_stream_type, v_secondary_stream_id, v_event_kind,
          v_event_body, v_event_body_digest, v_affected_field_names,
          v_secondary_before_digest, v_secondary_after_digest, v_account_id,
          v_device_id, v_device_sequence, v_occurred_at, v_received_at,
          v_secondary_event_digest
        );
        update esheep_cloud.farm_state
        set projection_digest = esheep_cloud.sha256_hex(convert_to(
              projection_digest || chr(10) || v_secondary_event_digest,
              'utf8'
            )),
            updated_at = v_received_at
        where farm_id = p_farm_id
          and farm_generation = p_farm_generation;
        v_secondary_stream.last_event_sequence := v_secondary_event_sequence;
        update esheep_cloud.streams
        set stream_version = v_secondary_stream.stream_version,
            field_versions = v_secondary_stream.field_versions,
            canonical_state = v_secondary_stream.canonical_state,
            content_digest = v_secondary_stream.content_digest,
            last_event_sequence = v_secondary_stream.last_event_sequence,
            updated_at = v_received_at
        where farm_id = p_farm_id
          and farm_generation = p_farm_generation
          and stream_type = v_secondary_stream_type
          and stream_id = v_secondary_stream_id;
        v_event_sequences := array_append(v_event_sequences, v_secondary_event_sequence);
        v_event_ids := array_append(v_event_ids, v_secondary_event_id);
      end loop;
    end if;

    -- A command whose decisions all converged through later accepted events is
    -- complete even though it did not need to append its own duplicate event.
    update esheep_cloud.commands command
    set status = 'accepted',
        result = jsonb_build_object(
          'type', 'accepted',
          'command_id', command.command_id,
          'cloud_head', v_event_sequence
        ),
        completed_at = v_received_at
    where command.farm_id = p_farm_id
      and command.farm_generation = p_farm_generation
      and command.status = 'needs_confirmation'
      and exists (
        select 1 from esheep_cloud.attention_items item
        where item.command_id = command.command_id
          and item.status = 'obsolete'
      )
      and not exists (
        select 1 from esheep_cloud.attention_items item
        where item.command_id = command.command_id
          and item.status in ('open', 'resolving')
      );
  end if;

  if v_conflict_count > 0 then
    v_result := jsonb_build_object(
      'type', 'needs_confirmation',
      'command_id', v_command_id,
      'attention_id', v_first_attention_id,
      'attention_count', v_conflict_count,
      'merged_event_sequence', v_event_sequence,
      'merged_event_sequences', to_jsonb(v_event_sequences),
      'cloud_head', (select event_head from esheep_cloud.farm_state where farm_id = p_farm_id)
    );
    update esheep_cloud.commands
    set status = 'needs_confirmation', result = v_result, completed_at = v_received_at
    where command_id = v_command_id;
  else
    v_result := jsonb_build_object(
      'type', 'accepted',
      'command_id', v_command_id,
      'event_sequence', v_event_sequence,
      'event_id', v_event_id,
      'event_sequences', to_jsonb(v_event_sequences),
      'event_ids', to_jsonb(v_event_ids),
      'cloud_head', (select event_head from esheep_cloud.farm_state where farm_id = p_farm_id)
    );
    update esheep_cloud.commands
    set status = 'accepted', result = v_result, completed_at = v_received_at
    where command_id = v_command_id;
  end if;
  return v_result;
end;
$$;

insert into esheep_cloud.command_catalog (
  command_kind, merge_mode, allowed_roles, requires_online,
  current_schema_version
) values (
  'attention.resolve', 'lifecycle', array['owner', 'administrator', 'worker'], true,
  1
) on conflict (command_kind) do update set
  merge_mode = excluded.merge_mode,
  allowed_roles = excluded.allowed_roles,
  requires_online = excluded.requires_online,
  current_schema_version = excluded.current_schema_version;

create or replace function public.esheep_cloud_submit_verified_commands_v2(
  p_user_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_commands jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_command_id text;
  v_unsigned_json jsonb;
  v_contains_bundle boolean := false;
  v_bundle_id uuid;
  v_bundle_invalid boolean := false;
begin
  if p_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if jsonb_typeof(p_commands) <> 'array' or jsonb_array_length(p_commands) = 0 or jsonb_array_length(p_commands) > 25 then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_batch_invalid';
  end if;

  -- Decode the complete batch before processing its first command.  A bundle
  -- is an all-or-nothing business package: all members must carry the same
  -- bundle ID, and a rejected/ambiguous member rolls back every earlier member
  -- in the package through the exception block below.  Ordinary batches keep
  -- their independent per-command results.
  for v_item in select value from jsonb_array_elements(p_commands)
  loop
    begin
      v_unsigned_json := convert_from(
        decode(v_item ->> 'unsigned_command_base64', 'base64'),
        'utf8'
      )::jsonb;
      v_contains_bundle := v_contains_bundle or
        nullif(v_unsigned_json ->> 'bundleID', '') is not null;
      if nullif(v_unsigned_json ->> 'bundleID', '') is not null then
        if v_bundle_id is null then
          v_bundle_id := (v_unsigned_json ->> 'bundleID')::uuid;
        elsif v_bundle_id <> (v_unsigned_json ->> 'bundleID')::uuid then
          v_bundle_invalid := true;
        end if;
      elsif v_contains_bundle then
        v_bundle_invalid := true;
      end if;
    exception when others then
      raise exception using errcode = '22023', message = 'esheep_cloud_command_batch_encoding_invalid';
    end;
  end loop;
  if v_contains_bundle then
    if v_bundle_invalid or v_bundle_id is null then
      for v_item in select value from jsonb_array_elements(p_commands)
      loop
        v_unsigned_json := convert_from(
          decode(v_item ->> 'unsigned_command_base64', 'base64'),
          'utf8'
        )::jsonb;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'command_id', v_unsigned_json ->> 'commandID',
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'bundle_contract_invalid',
            'message', '这组关联操作的标识不一致，未保存任何内容。'
          )
        ));
      end loop;
      return jsonb_build_object('results', v_results);
    end if;

    begin
      for v_item in select value from jsonb_array_elements(p_commands)
      loop
        v_result := esheep_cloud.process_command_v2(
          p_farm_id,
          p_farm_generation,
          p_user_id,
          v_item
        );
        if v_result ->> 'type' not in ('accepted', 'duplicate') then
          raise exception using
            errcode = 'P0001',
            message = 'esheep_cloud_bundle_member_rejected';
        end if;
        v_results := v_results || jsonb_build_array(v_result);
      end loop;
    exception when others then
      -- The block is a PostgreSQL subtransaction.  Any command/event rows
      -- inserted above are rolled back before the stable terminal result is
      -- returned to the caller, so a bundle can never leave half its facts in
      -- the cloud ledger.
      v_results := '[]'::jsonb;
      for v_item in select value from jsonb_array_elements(p_commands)
      loop
        v_unsigned_json := convert_from(
          decode(v_item ->> 'unsigned_command_base64', 'base64'),
          'utf8'
        )::jsonb;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'command_id', v_unsigned_json ->> 'commandID',
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'bundle_rejected',
            'message', '这组关联操作未完整保存，已保持原状，请稍后重试。'
          )
        ));
      end loop;
    end;
    return jsonb_build_object('results', v_results);
  end if;

  for v_item in select value from jsonb_array_elements(p_commands)
  loop
    begin
      v_result := esheep_cloud.process_command_v2(
        p_farm_id,
        p_farm_generation,
        p_user_id,
        v_item
      );
    exception
      when sqlstate '0A000' then
        v_command_id := null;
        begin
          v_command_id := convert_from(decode(v_item ->> 'unsigned_command_base64', 'base64'), 'utf8')::jsonb ->> 'commandID';
        exception when others then null;
        end;
        v_result := jsonb_build_object(
          'command_id', v_command_id,
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'application_update_required',
            'message', '需要更新 eSheep+ 后才能保存这项内容。'
          )
        );
      when sqlstate '42501' then
        v_command_id := null;
        begin
          v_command_id := convert_from(
            decode(v_item ->> 'unsigned_command_base64', 'base64'),
            'utf8'
          )::jsonb ->> 'commandID';
        exception when others then null;
        end;
        v_result := jsonb_build_object(
          'command_id', v_command_id,
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'permission_denied',
            'message', '当前账号没有保存这项内容的权限。'
          )
        );
      when sqlstate '55000' then
        v_command_id := null;
        begin
          v_command_id := convert_from(
            decode(v_item ->> 'unsigned_command_base64', 'base64'),
            'utf8'
          )::jsonb ->> 'commandID';
        exception when others then null;
        end;
        v_result := jsonb_build_object(
          'command_id', v_command_id,
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'farm_temporarily_read_only',
            'message', 'eSheep+ 云正在保护这座牧场的数据，请稍后再试。'
          )
        );
      when others then
        v_command_id := null;
        begin
          v_command_id := convert_from(
            decode(v_item ->> 'unsigned_command_base64', 'base64'),
            'utf8'
          )::jsonb ->> 'commandID';
        exception when others then null;
        end;
        v_result := jsonb_build_object(
          'command_id', v_command_id,
          'type', 'rejected',
          'reason', jsonb_build_object(
            'code', 'malformed_command',
            'message', '这项内容不完整，无法安全保存。'
          )
        );
    end;
    v_results := v_results || jsonb_build_array(v_result);
  end loop;
  return jsonb_build_object('results', v_results);
end;
$$;

create or replace function public.esheep_cloud_pull_events_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_after_event_sequence bigint,
  p_limit integer default 500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_head bigint;
  v_events jsonb;
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
begin
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;
  select state.event_head into v_head
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id
    and state.farm_generation = p_farm_generation;
  if not found then
    raise exception using errcode = '55000', message = 'esheep_cloud_generation_mismatch';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'protocol_version', 2,
    'schema_version', 1,
    'farm_id', event.farm_id,
    'farm_generation', event.farm_generation,
    'event_sequence', event.event_sequence,
    'event_id', event.event_id,
    'command_id', event.command_id,
    'source_command_digest', event.source_command_digest,
    'stream_type', event.stream_type,
    'stream_id', event.stream_id,
    'event_kind', event.event_kind,
    'event_body_canonical', esheep_cloud.canonical_json_text(event.event_body),
    'event_body_digest', event.event_body_digest,
    'affected_fields', event.affected_fields,
    'before_digest', event.before_digest,
    'after_digest', event.after_digest,
    'actor_account_id', event.actor_account_id,
    'source_device_id', event.source_device_id,
    'source_device_sequence', event.source_device_sequence,
    'occurred_at_millis', round(extract(epoch from event.occurred_at) * 1000)::bigint,
    'received_at_millis', round(extract(epoch from event.received_at) * 1000)::bigint,
    'event_digest', event.event_digest
  ) order by event.event_sequence), '[]'::jsonb)
  into v_events
  from (
    select * from esheep_cloud.events source
    where source.farm_id = p_farm_id
      and source.farm_generation = p_farm_generation
      and source.event_sequence > greatest(0, coalesce(p_after_event_sequence, 0))
    order by source.event_sequence
    limit v_limit
  ) event;

  return jsonb_build_object(
    'events', v_events,
    'cloud_head', v_head,
    'has_more', coalesce((v_events -> -1 ->> 'event_sequence')::bigint, p_after_event_sequence) < v_head
  );
end;
$$;

create or replace function public.esheep_cloud_query_command_status_v2(
  p_farm_id uuid,
  p_command_ids uuid[]
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_ids uuid[] := coalesce(p_command_ids, '{}');
  v_results jsonb;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;
  if cardinality(v_ids) > 100 or array_position(v_ids, null) is not null then
    raise exception using errcode = '22023', message = 'esheep_cloud_command_status_request_invalid';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'command_id', command.command_id,
    'result', command.result
  ) order by command.server_received_at), '[]'::jsonb)
  into v_results
  from esheep_cloud.commands command
  where command.farm_id = p_farm_id
    and command.command_id = any(v_ids);

  return jsonb_build_object('results', v_results);
end;
$$;

create or replace function public.esheep_cloud_fetch_status_v2(p_farm_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_state esheep_cloud.farm_state%rowtype;
  v_attention jsonb;
begin
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id;
  if not found then
    raise exception using errcode = '55000', message = 'esheep_cloud_farm_missing';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'attention_id', item.attention_id,
    'command_id', item.command_id,
    'stream_type', item.stream_type,
    'stream_id', item.stream_id,
    'record_type', item.record_type,
    'record_id', item.record_id,
    'record_display_name', item.record_display_name,
    'field_key', item.field_key,
    'field_display_name', item.field_display_name,
    'base_value_digest', item.base_value_digest,
    'device_value', item.device_value,
    'cloud_value', item.cloud_value,
    'device_account_id', item.device_account_id,
    'device_account_display_name', (
      select profile.display_name from public.profiles profile
      where profile.app_account_id = item.device_account_id
      limit 1
    ),
    'device_id', item.device_id,
    'device_display_name', (
      select device.display_name from public.devices device
      where device.device_id = item.device_id
      limit 1
    ),
    'device_occurred_at', item.device_occurred_at,
    'cloud_account_id', item.cloud_account_id,
    'cloud_account_display_name', (
      select profile.display_name from public.profiles profile
      where profile.app_account_id = item.cloud_account_id
      limit 1
    ),
    'cloud_device_id', item.cloud_device_id,
    'cloud_device_display_name', (
      select device.display_name from public.devices device
      where device.device_id = item.cloud_device_id
      limit 1
    ),
    'cloud_received_at', item.cloud_received_at,
    'explanation', item.explanation,
    'created_at', item.created_at
  ) order by item.created_at), '[]'::jsonb)
  into v_attention
  from esheep_cloud.attention_items item
  where item.farm_id = p_farm_id and item.status = 'open';

  return jsonb_build_object(
    'farm_id', v_state.farm_id,
    'farm_generation', v_state.farm_generation,
    'cloud_head', v_state.event_head,
    'latest_snapshot_id', v_state.latest_snapshot_id,
    'v2_ready', v_state.v2_ready,
    'write_frozen', v_state.write_frozen,
    'write_freeze_trace_id', v_state.write_freeze_trace_id,
    'attention_items', v_attention,
    'server_time', now()
  );
end;
$$;

create or replace function public.esheep_cloud_resolve_verified_attention_v2(
  p_user_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_attention_id uuid,
  p_resolution_command_id uuid,
  p_choice text,
  p_expected_cloud_value_digest text,
  p_account_id uuid,
  p_device_id uuid,
  p_device_sequence bigint,
  p_device_signature_base64 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := p_user_id;
  v_item esheep_cloud.attention_items%rowtype;
  v_stream esheep_cloud.streams%rowtype;
  v_field_entry jsonb;
  v_current_digest text;
  v_chosen_value jsonb;
  v_chosen_digest text;
  v_before_digest text;
  v_after_digest text;
  v_received_at timestamptz := clock_timestamp();
  v_event_sequence bigint;
  v_event_id uuid := gen_random_uuid();
  v_resolution_body jsonb;
  v_event_body_digest text;
  v_unsigned_resolution bytea;
  v_resolution_digest text;
  v_event_digest text;
  v_result jsonb;
  v_farm_state esheep_cloud.farm_state%rowtype;
  v_signature bytea;
  v_existing esheep_cloud.commands%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_choice not in ('use_this_device', 'keep_cloud', 'abandon_operation', 'resubmit') then
    raise exception using errcode = '22023', message = 'esheep_cloud_resolution_invalid';
  end if;
  if lower(p_expected_cloud_value_digest) !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'esheep_cloud_resolution_digest_invalid';
  end if;
  begin
    v_signature := decode(p_device_signature_base64, 'base64');
  exception when others then
    raise exception using errcode = '22023', message = 'esheep_cloud_device_signature_invalid';
  end;
  if octet_length(v_signature) <> 64 then
    raise exception using errcode = '22023', message = 'esheep_cloud_device_signature_invalid';
  end if;
  v_unsigned_resolution := convert_to(
    'esheep-cloud-attention-resolution-v2' || chr(10) ||
    lower(p_attention_id::text) || chr(10) ||
    lower(p_resolution_command_id::text) || chr(10) ||
    p_choice || chr(10) ||
    lower(p_expected_cloud_value_digest) || chr(10) ||
    p_farm_generation::text || chr(10) ||
    lower(p_account_id::text) || chr(10) ||
    lower(p_device_id::text) || chr(10) ||
    p_device_sequence::text,
    'utf8'
  );
  v_resolution_digest := esheep_cloud.sha256_hex(v_unsigned_resolution);
  if not exists (
    select 1
    from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = v_user_id
      and member.app_account_id = p_account_id
      and member.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_write_denied';
  end if;
  if not exists (select 1 from public.devices device where device.device_id = p_device_id and device.user_id = v_user_id and device.status = 'active') then
    raise exception using errcode = '42501', message = 'esheep_cloud_device_identity_mismatch';
  end if;

  select * into v_farm_state
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id
  for update;
  if not found or v_farm_state.farm_generation <> p_farm_generation or
     v_farm_state.status <> 'active' or not v_farm_state.v2_ready then
    raise exception using errcode = '55000', message = 'esheep_cloud_farm_not_writable';
  end if;
  if v_farm_state.write_frozen then
    raise exception using errcode = '55000', message = 'esheep_cloud_integrity_hold';
  end if;
  select * into v_existing
  from esheep_cloud.commands command
  where command.command_id = p_resolution_command_id
  for update;
  if found then
    if v_existing.content_digest <> v_resolution_digest
       or v_existing.farm_id <> p_farm_id
       or v_existing.farm_generation <> p_farm_generation
       or v_existing.account_id <> p_account_id
       or v_existing.device_id <> p_device_id
       or v_existing.command_kind <> 'attention.resolve' then
      return jsonb_build_object(
        'command_id', p_resolution_command_id,
        'type', 'rejected',
        'reason', jsonb_build_object(
          'code', 'command_id_digest_mismatch',
          'message', '同一处理标识对应了不同内容，已停止处理。'
        )
      );
    end if;
    return jsonb_build_object(
      'type', 'duplicate',
      'command_id', v_existing.command_id,
      'original', v_existing.result
    );
  end if;
  if exists (
    select 1 from esheep_cloud.commands command
    where command.farm_id = p_farm_id
      and command.farm_generation = p_farm_generation
      and command.device_id = p_device_id
      and command.device_sequence = p_device_sequence
  ) then
    raise exception using errcode = '23505', message = 'esheep_cloud_device_sequence_reused';
  end if;

  select * into v_item from esheep_cloud.attention_items item
  where item.attention_id = p_attention_id
    and item.farm_id = p_farm_id
    and item.farm_generation = p_farm_generation
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_attention_missing';
  end if;
  if v_item.status = 'resolved' then
    if v_item.resolution_command_id <> p_resolution_command_id then
      return jsonb_build_object(
        'command_id', p_resolution_command_id,
        'type', 'rejected',
        'reason', jsonb_build_object(
          'code', 'attention_already_resolved',
          'message', '这项内容已经在另一台设备上处理完成。',
          'allowed_actions', jsonb_build_array('refresh')
        )
      );
    end if;
    select jsonb_build_object(
      'type', 'duplicate',
      'command_id', command.command_id,
      'original', command.result
    ) into v_result from esheep_cloud.commands command
    where command.command_id = v_item.resolution_command_id;
    return v_result;
  end if;
  if v_item.status = 'obsolete' then
    return jsonb_build_object(
      'command_id', p_resolution_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'attention_no_longer_needed',
        'message', '两边内容已经一致，不再需要处理。',
        'allowed_actions', jsonb_build_array('refresh')
      )
    );
  end if;
  if v_item.status <> 'open' then
    return jsonb_build_object(
      'command_id', p_resolution_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'attention_busy',
        'message', '这项内容正在处理，请稍后查看。',
        'allowed_actions', jsonb_build_array('refresh')
      )
    );
  end if;

  select * into v_stream from esheep_cloud.streams stream
  where stream.farm_id = p_farm_id
    and stream.farm_generation = p_farm_generation
    and stream.stream_type = v_item.stream_type
    and stream.stream_id = v_item.stream_id
  for update;
  if not found then
    raise exception using errcode = '55000', message = 'esheep_cloud_stream_missing';
  end if;
  v_field_entry := v_stream.field_versions -> v_item.field_key;
  v_current_digest := coalesce(v_field_entry ->> 'value_digest', esheep_cloud.value_digest(jsonb_build_object('type', 'null')));
  if v_current_digest <> lower(p_expected_cloud_value_digest) then
    return jsonb_build_object(
      'command_id', p_resolution_command_id,
      'type', 'rejected',
      'reason', jsonb_build_object(
        'code', 'attention_cloud_changed',
        'message', 'eSheep+ 云中的内容刚刚发生变化，请查看最新内容后再决定。',
        'allowed_actions', jsonb_build_array('refresh')
      )
    );
  end if;

  if p_choice in ('use_this_device', 'resubmit') then
    v_chosen_value := v_item.device_value;
  else
    v_chosen_value := v_item.cloud_value;
  end if;
  v_chosen_digest := esheep_cloud.value_digest(v_chosen_value);
  v_before_digest := v_stream.content_digest;
  if p_choice in ('use_this_device', 'resubmit') and v_chosen_digest <> v_current_digest then
    v_stream.canonical_state := jsonb_set(v_stream.canonical_state, array[v_item.field_key], v_chosen_value, true);
    v_stream.field_versions := jsonb_set(v_stream.field_versions, array[v_item.field_key], jsonb_build_object(
      'version', coalesce((v_field_entry ->> 'version')::bigint, 0) + 1,
      'value_digest', v_chosen_digest,
      'value', v_chosen_value,
      'account_id', p_account_id,
      'device_id', p_device_id,
      'device_sequence', p_device_sequence,
      'occurred_at', v_received_at,
      'received_at', v_received_at
    ), true);
    v_stream.stream_version := v_stream.stream_version + 1;
    v_stream.content_digest := esheep_cloud.json_digest(v_stream.canonical_state);
  end if;
  v_after_digest := v_stream.content_digest;

  v_resolution_body := jsonb_build_object(
    'attention_id', p_attention_id,
    'choice', p_choice,
    'field', v_item.field_key,
    'chosen_value', v_chosen_value
  );
  insert into esheep_cloud.commands (
    command_id, farm_id, farm_generation, source_request_id, actor_user_id,
    account_id, device_id, device_sequence, protocol_version, schema_version,
    command_kind, occurred_at, client_created_at, unsigned_command,
    content_digest, device_signature, affected_streams, affected_fields,
    field_changes, status, result, server_received_at, completed_at
  ) values (
    p_resolution_command_id, p_farm_id, p_farm_generation, p_resolution_command_id, v_user_id,
    p_account_id, p_device_id, p_device_sequence, 2, 1,
    'attention.resolve', v_received_at, v_received_at, v_unsigned_resolution,
    v_resolution_digest, v_signature,
    jsonb_build_array(jsonb_build_object('type', v_item.stream_type, 'id', v_item.stream_id)),
    '[]'::jsonb, '[]'::jsonb, 'processing', jsonb_build_object('type', 'processing'),
    v_received_at, v_received_at
  );

  update esheep_cloud.farm_state
  set event_head = event_head + 1, updated_at = v_received_at
  where farm_id = p_farm_id and farm_generation = p_farm_generation
  returning event_head into v_event_sequence;
  v_event_body_digest := esheep_cloud.json_digest(v_resolution_body);
  v_event_digest := esheep_cloud.event_digest(
    p_farm_id, p_farm_generation, v_event_sequence, v_event_id,
    p_resolution_command_id, v_item.stream_type, v_item.stream_id,
    array[v_item.field_key], v_event_body_digest,
    v_before_digest, v_after_digest,
    p_account_id, p_device_id, p_device_sequence,
    round(extract(epoch from v_received_at) * 1000)::bigint,
    round(extract(epoch from v_received_at) * 1000)::bigint,
    v_resolution_digest
  );
  insert into esheep_cloud.events (
    farm_id, farm_generation, event_sequence, event_id, command_id,
    source_command_digest, stream_type, stream_id, event_kind, event_body,
    event_body_digest, affected_fields, before_digest, after_digest, actor_account_id,
    source_device_id, source_device_sequence,
    occurred_at, received_at, event_digest
  ) values (
    p_farm_id, p_farm_generation, v_event_sequence, v_event_id, p_resolution_command_id,
    v_resolution_digest, v_item.stream_type, v_item.stream_id, 'attention_resolved', v_resolution_body,
    v_event_body_digest, array[v_item.field_key],
    v_before_digest, v_after_digest, p_account_id,
    p_device_id, p_device_sequence,
    v_received_at, v_received_at, v_event_digest
  );
  update esheep_cloud.farm_state
  set projection_digest = esheep_cloud.sha256_hex(convert_to(
        projection_digest || chr(10) || v_event_digest,
        'utf8'
      )),
      updated_at = v_received_at
  where farm_id = p_farm_id
    and farm_generation = p_farm_generation;
  update esheep_cloud.streams
  set stream_version = v_stream.stream_version,
      field_versions = v_stream.field_versions,
      canonical_state = v_stream.canonical_state,
      content_digest = v_stream.content_digest,
      last_event_sequence = v_event_sequence,
      updated_at = v_received_at
  where farm_id = p_farm_id and farm_generation = p_farm_generation
    and stream_type = v_item.stream_type and stream_id = v_item.stream_id;

  update esheep_cloud.attention_items
  set status = 'resolved', resolution = p_choice,
      resolution_command_id = p_resolution_command_id,
      resolution_event_id = v_event_id, resolved_at = v_received_at,
      updated_at = v_received_at
  where attention_id = p_attention_id;
  update esheep_cloud.commands command
  set status = 'accepted',
      result = jsonb_build_object(
        'type', 'accepted',
        'command_id', command.command_id,
        'cloud_head', v_event_sequence
      ),
      completed_at = v_received_at
  where command.command_id = v_item.command_id
    and command.status = 'needs_confirmation'
    and not exists (
      select 1 from esheep_cloud.attention_items item
      where item.command_id = command.command_id
        and item.status in ('open', 'resolving')
    );
  v_result := jsonb_build_object(
    'type', 'accepted', 'command_id', p_resolution_command_id,
    'event_sequence', v_event_sequence, 'event_id', v_event_id,
    'cloud_head', v_event_sequence
  );
  update esheep_cloud.commands set status = 'accepted', result = v_result
  where command_id = p_resolution_command_id;
  return v_result;
end;
$$;

create or replace function public.esheep_cloud_create_invite_v2(
  p_farm_id uuid,
  p_role text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_code text;
  v_expires_at timestamptz := now() + interval '24 hours';
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_role not in ('administrator', 'worker') then
    raise exception using errcode = '22023', message = 'esheep_cloud_invite_role_invalid';
  end if;
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator']
  ) or not exists (
    select 1 from public.farm_registry registry
    join esheep_cloud.farm_state state on state.farm_id = registry.farm_id
    where registry.farm_id = p_farm_id
      and registry.provider = 'esheep_cloud'
      and registry.status in ('active', 'read_only')
      and state.farm_generation = registry.authority_generation
      and state.v2_ready
      and state.status in ('active', 'read_only')
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_invite_denied';
  end if;
  v_code := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  insert into public.farm_invites (
    farm_id, invited_by, role, code_digest, expires_at
  ) values (
    p_farm_id, v_user_id, p_role,
    extensions.digest(v_code, 'sha256'), v_expires_at
  );
  return jsonb_build_object(
    'code', v_code,
    'expires_at', v_expires_at
  );
end;
$$;

create or replace function public.esheep_cloud_list_my_farms_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  return jsonb_build_object(
    'farms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'farm_id', registry.farm_id,
        'farm_generation', registry.authority_generation,
        'member_account_id', member.app_account_id,
        'role', member.role,
        'initial_sync_ready', coalesce((
          registry.status in ('active', 'read_only')
          and state.farm_generation = registry.authority_generation
          and state.v2_ready
          and state.status in ('active', 'read_only')
          and snapshot.snapshot_id is not null
          and snapshot.status = 'verified'
        ), false)
      ) order by registry.created_at, registry.farm_id)
      from public.farm_members member
      join public.farm_registry registry
        on registry.farm_id = member.farm_id
       and registry.provider = 'esheep_cloud'
      left join esheep_cloud.farm_state state
        on state.farm_id = registry.farm_id
      left join esheep_cloud.snapshots snapshot
        on snapshot.snapshot_id = state.latest_snapshot_id
      where member.user_id = v_user_id
        and member.status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.esheep_cloud_redeem_invite_v2(
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_invite public.farm_invites%rowtype;
  v_registry public.farm_registry%rowtype;
  v_state esheep_cloud.farm_state%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  select profile.app_account_id into v_account_id
  from public.profiles profile where profile.user_id = v_user_id;
  if v_account_id is null then
    raise exception using errcode = '23503', message = 'profile_missing';
  end if;
  select * into v_invite
  from public.farm_invites invite
  where invite.code_digest = extensions.digest(btrim(p_code), 'sha256')
  for update;
  if not found or v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception using errcode = '22023', message = 'esheep_cloud_invite_invalid_or_expired';
  end if;
  select * into v_registry from public.farm_registry registry
  where registry.farm_id = v_invite.farm_id
    and registry.provider = 'esheep_cloud'
    and registry.status in ('active', 'read_only')
  for update;
  if not found then
    raise exception using errcode = '55000', message = 'esheep_cloud_inviter_update_required';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = v_registry.farm_id
    and state.farm_generation = v_registry.authority_generation
    and state.v2_ready
    and state.status in ('active', 'read_only');
  if not found then
    raise exception using errcode = '55000', message = 'esheep_cloud_initial_sync_unavailable';
  end if;
  insert into public.farm_members (
    farm_id, user_id, app_account_id, role, status, invited_by
  ) values (
    v_invite.farm_id, v_user_id, v_account_id,
    v_invite.role, 'active', v_invite.invited_by
  ) on conflict (farm_id, user_id) do update set
    app_account_id = excluded.app_account_id,
    role = excluded.role,
    status = 'active',
    invited_by = excluded.invited_by,
    updated_at = now();
  update public.farm_invites
  set status = 'redeemed', redeemed_by = v_user_id, redeemed_at = now()
  where invite_id = v_invite.invite_id;
  return jsonb_build_object(
    'farm_id', v_registry.farm_id,
    'farm_generation', v_state.farm_generation,
    'role', v_invite.role
  );
end;
$$;

create or replace function public.esheep_cloud_list_members_v2(
  p_farm_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_member_list_denied';
  end if;
  return jsonb_build_object(
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', member.user_id,
        'account_id', member.app_account_id,
        'display_name', profile.display_name,
        'role', member.role,
        'status', member.status
      ) order by
        case member.role when 'owner' then 0 when 'administrator' then 1 else 2 end,
        member.created_at,
        member.user_id
      )
      from public.farm_members member
      left join public.profiles profile on profile.user_id = member.user_id
      where member.farm_id = p_farm_id
        and member.status in ('active', 'revoked')
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.esheep_cloud_revoke_member_v2(
  p_farm_id uuid,
  p_member_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.farm_members%rowtype;
begin
  if not esheep_private.is_active_farm_member(p_farm_id, array['owner']) then
    raise exception using errcode = '42501', message = 'esheep_cloud_owner_required';
  end if;
  select * into v_member from public.farm_members member
  where member.farm_id = p_farm_id and member.user_id = p_member_id
  for update;
  if not found or v_member.role = 'owner' then
    raise exception using errcode = '22023', message = 'esheep_cloud_member_revoke_invalid';
  end if;
  update public.farm_members
  set status = 'revoked', updated_at = now()
  where farm_id = p_farm_id and user_id = p_member_id;
  return jsonb_build_object(
    'member_id', p_member_id,
    'status', 'revoked'
  );
end;
$$;

create or replace function public.esheep_cloud_open_initial_sync_v2(
  p_farm_id uuid,
  p_farm_generation integer default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_state esheep_cloud.farm_state%rowtype;
  v_snapshot esheep_cloud.snapshots%rowtype;
  v_member public.farm_members%rowtype;
begin
  if not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id;
  if not found or not v_state.v2_ready or
     v_state.status not in ('active', 'read_only') or
     (p_farm_generation is not null and v_state.farm_generation <> p_farm_generation) then
    raise exception using errcode = '55000', message = 'esheep_cloud_initial_sync_unavailable';
  end if;
  select * into v_snapshot from esheep_cloud.snapshots snapshot
  where snapshot.snapshot_id = v_state.latest_snapshot_id
    and snapshot.status = 'verified';
  if not found or v_snapshot.farm_profile_data is null
     or v_snapshot.farm_profile_digest is null then
    raise exception using errcode = '55000', message = 'esheep_cloud_snapshot_unavailable';
  end if;
  select * into v_member
  from public.farm_members member
  where member.farm_id = p_farm_id
    and member.user_id = (select auth.uid())
    and member.status = 'active';
  if not found then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;
  return jsonb_build_object(
    'snapshot_id', v_snapshot.snapshot_id,
    'farm_id', v_snapshot.farm_id,
    'farm_generation', v_snapshot.farm_generation,
    'boundary_event_sequence', v_snapshot.boundary_event_sequence,
    'schema_version', v_snapshot.schema_version,
    'manifest', v_snapshot.manifest,
    'total_digest', v_snapshot.total_digest,
    'total_byte_count', v_snapshot.total_byte_count,
    'chunk_count', v_snapshot.chunk_count,
    'farm_profile_base64', encode(v_snapshot.farm_profile_data, 'base64'),
    'member_account_id', v_member.app_account_id,
    'member_role', v_member.role,
    'membership_status', v_member.status,
    'expires_at', now() + interval '30 minutes'
  );
end;
$$;

create or replace function public.esheep_cloud_download_snapshot_chunk_v2(
  p_snapshot_id uuid,
  p_chunk_index integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot esheep_cloud.snapshots%rowtype;
  v_chunk esheep_cloud.snapshot_chunks%rowtype;
begin
  select * into v_snapshot from esheep_cloud.snapshots snapshot
  where snapshot.snapshot_id = p_snapshot_id and snapshot.status = 'verified';
  if not found or not esheep_private.is_active_farm_member(
    v_snapshot.farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_snapshot_read_denied';
  end if;
  select * into v_chunk from esheep_cloud.snapshot_chunks chunk
  where chunk.snapshot_id = p_snapshot_id and chunk.chunk_index = p_chunk_index;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_snapshot_chunk_missing';
  end if;
  return jsonb_build_object(
    'snapshot_id', p_snapshot_id,
    'chunk_index', p_chunk_index,
    'content_base64', encode(v_chunk.content_data, 'base64'),
    'content_sha256', v_chunk.content_sha256,
    'byte_count', v_chunk.byte_count
  );
end;
$$;

create or replace function public.esheep_cloud_prepare_asset_transfer_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_asset_id uuid,
  p_sheep_id uuid,
  p_content_sha256 text,
  p_variant_sha256 text,
  p_metadata jsonb,
  p_metadata_digest text,
  p_variant text,
  p_direction text,
  p_byte_count bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_state esheep_cloud.farm_state%rowtype;
  v_extension text;
  v_path text;
  v_asset esheep_cloud.assets%rowtype;
  v_already_verified boolean := false;
begin
  if v_user_id is null or not esheep_private.is_active_farm_member(
    p_farm_id,
    array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_asset_denied';
  end if;
  if p_variant not in ('thumbnail', 'avatar', 'original') or p_direction not in ('upload', 'download') then
    raise exception using errcode = '22023', message = 'esheep_cloud_asset_request_invalid';
  end if;
  if lower(p_content_sha256) !~ '^[0-9a-f]{64}$'
    or lower(p_variant_sha256) !~ '^[0-9a-f]{64}$'
    or lower(p_metadata_digest) !~ '^[0-9a-f]{64}$'
    or coalesce(jsonb_typeof(p_metadata), 'null') <> 'object'
    or esheep_cloud.json_digest(p_metadata) <> lower(p_metadata_digest)
    or p_byte_count <= 0
    or (p_variant = 'original' and lower(p_variant_sha256) <> lower(p_content_sha256)) then
    raise exception using errcode = '22023', message = 'esheep_cloud_asset_digest_invalid';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id and state.farm_generation = p_farm_generation;
  if not found
    or (p_direction = 'upload' and (v_state.status <> 'active' or v_state.write_frozen))
    or (p_direction = 'download' and v_state.status not in ('active', 'read_only')) then
    raise exception using errcode = '55000', message = 'esheep_cloud_asset_farm_not_writable';
  end if;

  v_extension := case p_variant when 'original' then 'bin' else 'jpg' end;
  v_path := lower(p_farm_id::text) || '/' || p_farm_generation::text || '/' ||
    lower(p_asset_id::text) || '/' || lower(p_variant_sha256) || '/' || p_variant || '.' || v_extension;
  if p_direction = 'upload' then
    insert into esheep_cloud.assets (
      asset_id, farm_id, farm_generation, sheep_id, content_sha256, original_sha256,
      metadata, metadata_digest, original_byte_count, uploaded_by
    ) values (
      p_asset_id, p_farm_id, p_farm_generation, p_sheep_id, lower(p_content_sha256),
      case when p_variant = 'original' then lower(p_variant_sha256) else null end,
      coalesce(p_metadata, '{}'::jsonb), lower(p_metadata_digest),
      case when p_variant = 'original' then greatest(0, p_byte_count) else 0 end, v_user_id
    ) on conflict (asset_id) do update
    set updated_at = now()
    where esheep_cloud.assets.farm_id = excluded.farm_id
      and esheep_cloud.assets.farm_generation = excluded.farm_generation
      and esheep_cloud.assets.content_sha256 = excluded.content_sha256
      and esheep_cloud.assets.sheep_id is not distinct from excluded.sheep_id
      and esheep_cloud.assets.metadata_digest = excluded.metadata_digest
      and esheep_cloud.assets.metadata = excluded.metadata;
    if not found then
      raise exception using errcode = '23505', message = 'esheep_cloud_asset_identity_changed';
    end if;
    select * into v_asset from esheep_cloud.assets asset
    where asset.asset_id = p_asset_id
      and asset.farm_id = p_farm_id
      and asset.farm_generation = p_farm_generation
    for update;
    v_already_verified := case p_variant
      when 'thumbnail' then v_asset.thumbnail_state = 'verified'
        and v_asset.thumbnail_sha256 = lower(p_variant_sha256)
        and v_asset.thumbnail_byte_count = p_byte_count
      when 'avatar' then v_asset.avatar_state = 'verified'
        and v_asset.avatar_sha256 = lower(p_variant_sha256)
        and v_asset.avatar_byte_count = p_byte_count
      when 'original' then v_asset.original_state = 'verified'
        and v_asset.original_sha256 = lower(p_variant_sha256)
        and v_asset.original_byte_count = p_byte_count
    end;
    update esheep_cloud.assets
    set thumbnail_path = case when p_variant = 'thumbnail' then v_path else thumbnail_path end,
        avatar_path = case when p_variant = 'avatar' then v_path else avatar_path end,
        original_path = case when p_variant = 'original' then v_path else original_path end,
        thumbnail_sha256 = case when p_variant = 'thumbnail' then lower(p_variant_sha256) else thumbnail_sha256 end,
        avatar_sha256 = case when p_variant = 'avatar' then lower(p_variant_sha256) else avatar_sha256 end,
        original_sha256 = case when p_variant = 'original' then lower(p_variant_sha256) else original_sha256 end,
        thumbnail_state = case when p_variant = 'thumbnail' then 'transferring' else thumbnail_state end,
        avatar_state = case when p_variant = 'avatar' then 'transferring' else avatar_state end,
        original_state = case when p_variant = 'original' then 'transferring' else original_state end,
        thumbnail_byte_count = case when p_variant = 'thumbnail' then greatest(0, p_byte_count) else thumbnail_byte_count end,
        avatar_byte_count = case when p_variant = 'avatar' then greatest(0, p_byte_count) else avatar_byte_count end,
        original_byte_count = case when p_variant = 'original' then greatest(0, p_byte_count) else original_byte_count end,
        updated_at = now()
    where asset_id = p_asset_id
      and not v_already_verified;
  else
    select * into v_asset from esheep_cloud.assets asset
    where asset.asset_id = p_asset_id and asset.farm_id = p_farm_id
      and asset.farm_generation = p_farm_generation
      and asset.content_sha256 = lower(p_content_sha256)
      and case p_variant
        when 'thumbnail' then asset.thumbnail_state = 'verified' and asset.thumbnail_sha256 = lower(p_variant_sha256)
        when 'avatar' then asset.avatar_state = 'verified' and asset.avatar_sha256 = lower(p_variant_sha256)
        when 'original' then asset.original_state = 'verified' and asset.original_sha256 = lower(p_variant_sha256)
      end;
    if not found then
      raise exception using errcode = '55000', message = 'esheep_cloud_asset_not_ready';
    end if;
    v_path := case p_variant
      when 'thumbnail' then v_asset.thumbnail_path
      when 'avatar' then v_asset.avatar_path
      when 'original' then v_asset.original_path
    end;
  end if;
  return jsonb_build_object(
    'asset_id', p_asset_id,
    'variant', p_variant,
    'object_key', v_path,
    'bucket', 'esheep-cloud-assets',
    'already_verified', v_already_verified,
    'expires_at', now() + interval '10 minutes'
  );
end;
$$;

create or replace function public.esheep_cloud_asset_verification_target_v2(
  p_user_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_asset_id uuid,
  p_variant text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset esheep_cloud.assets%rowtype;
  v_state esheep_cloud.farm_state%rowtype;
  v_path text;
  v_expected_sha256 text;
  v_expected_byte_count bigint;
begin
  if (select auth.role()) <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if not exists (
    select 1 from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = p_user_id
      and member.status = 'active'
      and member.role = any(array['owner', 'administrator', 'worker'])
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_asset_denied';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id and state.farm_generation = p_farm_generation;
  if not found or v_state.status <> 'active' or v_state.write_frozen then
    raise exception using errcode = '55000', message = 'esheep_cloud_asset_farm_not_writable';
  end if;
  select * into v_asset from esheep_cloud.assets asset
  where asset.asset_id = p_asset_id and asset.farm_id = p_farm_id
    and asset.farm_generation = p_farm_generation
  ;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_asset_missing';
  end if;
  v_path := case p_variant
    when 'thumbnail' then v_asset.thumbnail_path
    when 'avatar' then v_asset.avatar_path
    when 'original' then v_asset.original_path
    else null
  end;
  v_expected_sha256 := case p_variant
    when 'thumbnail' then v_asset.thumbnail_sha256
    when 'avatar' then v_asset.avatar_sha256
    when 'original' then v_asset.original_sha256
    else null
  end;
  v_expected_byte_count := case p_variant
    when 'thumbnail' then v_asset.thumbnail_byte_count
    when 'avatar' then v_asset.avatar_byte_count
    when 'original' then v_asset.original_byte_count
    else null
  end;
  if v_path is null or v_expected_sha256 is null then
    raise exception using errcode = '22023', message = 'esheep_cloud_asset_variant_invalid';
  end if;
  return jsonb_build_object(
    'asset_id', p_asset_id,
    'variant', p_variant,
    'bucket', 'esheep-cloud-assets',
    'object_key', v_path,
    'expected_sha256', v_expected_sha256,
    'expected_byte_count', v_expected_byte_count
  );
end;
$$;

create or replace function public.esheep_cloud_confirm_verified_asset_v2(
  p_user_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_asset_id uuid,
  p_variant text,
  p_actual_sha256 text,
  p_actual_byte_count bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset esheep_cloud.assets%rowtype;
  v_state esheep_cloud.farm_state%rowtype;
  v_path text;
  v_expected_sha256 text;
  v_expected_byte_count bigint;
begin
  if (select auth.role()) <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if not exists (
    select 1 from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = p_user_id
      and member.status = 'active'
      and member.role = any(array['owner', 'administrator', 'worker'])
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_asset_denied';
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id and state.farm_generation = p_farm_generation
  for update;
  if not found or v_state.status <> 'active' or v_state.write_frozen then
    raise exception using errcode = '55000', message = 'esheep_cloud_asset_farm_not_writable';
  end if;
  select * into v_asset from esheep_cloud.assets asset
  where asset.asset_id = p_asset_id and asset.farm_id = p_farm_id
    and asset.farm_generation = p_farm_generation
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_asset_missing';
  end if;
  v_path := case p_variant
    when 'thumbnail' then v_asset.thumbnail_path
    when 'avatar' then v_asset.avatar_path
    when 'original' then v_asset.original_path
    else null
  end;
  v_expected_sha256 := case p_variant
    when 'thumbnail' then v_asset.thumbnail_sha256
    when 'avatar' then v_asset.avatar_sha256
    when 'original' then v_asset.original_sha256
    else null
  end;
  v_expected_byte_count := case p_variant
    when 'thumbnail' then v_asset.thumbnail_byte_count
    when 'avatar' then v_asset.avatar_byte_count
    when 'original' then v_asset.original_byte_count
    else null
  end;
  if v_path is null or v_expected_sha256 is null or v_expected_byte_count <= 0 then
    raise exception using errcode = '22023', message = 'esheep_cloud_asset_variant_invalid';
  end if;
  if lower(p_actual_sha256) <> v_expected_sha256
    or p_actual_byte_count <> v_expected_byte_count then
    raise exception using errcode = '55000', message = 'esheep_cloud_asset_hash_unverified';
  end if;
  if not exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'esheep-cloud-assets'
      and object.name = v_path
  ) then
    raise exception using errcode = '55000', message = 'esheep_cloud_asset_object_missing';
  end if;
  update esheep_cloud.assets
  set thumbnail_state = case when p_variant = 'thumbnail' then 'verified' else thumbnail_state end,
      avatar_state = case when p_variant = 'avatar' then 'verified' else avatar_state end,
      original_state = case when p_variant = 'original' then 'verified' else original_state end,
      verified_at = now(), updated_at = now()
  where asset_id = p_asset_id;
  return jsonb_build_object(
    'asset_id', p_asset_id,
    'variant', p_variant,
    'content_sha256', v_asset.content_sha256,
    'variant_sha256', v_expected_sha256,
    'byte_count', v_expected_byte_count,
    'verified', true
  );
end;
$$;

-- Integrity checks are deliberately separate from the write transaction's
-- business validation. They recompute authority from immutable bytes and
-- events instead of trusting the mutable farm_state summary. The safe
-- helpers turn malformed persisted bytes into an audit failure so an audit
-- can still commit the write freeze instead of aborting before it is saved.
create or replace function esheep_cloud.safe_jsonb_from_utf8_v2(p_data bytea)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return convert_from(p_data, 'utf8')::jsonb;
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.safe_value_digest_v2(p_value jsonb)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return esheep_cloud.value_digest(p_value);
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.safe_uuid_v2(p_value text)
returns uuid
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return p_value::uuid;
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.safe_integer_v2(p_value text)
returns integer
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return p_value::integer;
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.safe_bigint_v2(p_value text)
returns bigint
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return p_value::bigint;
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.safe_jsonb_array_length_v2(p_value jsonb)
returns integer
language plpgsql
immutable
security invoker
set search_path = ''
as $$
begin
  return jsonb_array_length(p_value);
exception when others then
  return null;
end;
$$;

create or replace function esheep_cloud.farm_integrity_report_v2(
  p_farm_id uuid,
  p_farm_generation integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_state esheep_cloud.farm_state%rowtype;
  v_event_count bigint := 0;
  v_event_min bigint;
  v_event_max bigint;
  v_event_sequence_valid boolean := false;
  v_event_digest_mismatches bigint := 0;
  v_event_body_digest_mismatches bigint := 0;
  v_event_command_mismatches bigint := 0;
  v_event_body_mismatches bigint := 0;
  v_command_digest_mismatches bigint := 0;
  v_stream_digest_mismatches bigint := 0;
  v_stream_event_head_mismatches bigint := 0;
  v_stream_event_chain_mismatches bigint := 0;
  v_field_version_mismatches bigint := 0;
  v_field_device_watermark_mismatches bigint := 0;
  v_asset_mismatches bigint := 0;
  v_snapshot_mismatches bigint := 0;
  v_computed_projection_digest text := repeat('0', 64);
  v_projection_matches boolean := false;
  v_event record;
  v_passed boolean := false;
begin
  select * into v_state
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id;

  if not found or v_state.farm_generation <> p_farm_generation then
    return jsonb_build_object(
      'passed', false,
      'farm_id', p_farm_id,
      'farm_generation', p_farm_generation,
      'reason', 'farm_state_missing_or_generation_changed',
      'checked_at', now()
    );
  end if;

  select count(*), min(event.event_sequence), max(event.event_sequence)
  into v_event_count, v_event_min, v_event_max
  from esheep_cloud.events event
  where event.farm_id = p_farm_id
    and event.farm_generation = p_farm_generation;

  v_event_sequence_valid := case
    when v_state.event_head = 0 then v_event_count = 0
    else v_event_count = v_state.event_head
      and v_event_min = 1
      and v_event_max = v_state.event_head
  end;

  select count(*) into v_event_digest_mismatches
  from esheep_cloud.events event
  where event.farm_id = p_farm_id
    and event.farm_generation = p_farm_generation
    and event.event_digest <> esheep_cloud.event_digest(
      event.farm_id,
      event.farm_generation,
      event.event_sequence,
      event.event_id,
      event.command_id,
      event.stream_type,
      event.stream_id,
      event.affected_fields,
      event.event_body_digest,
      event.before_digest,
      event.after_digest,
      event.actor_account_id,
      event.source_device_id,
      event.source_device_sequence,
      round(extract(epoch from event.occurred_at) * 1000)::bigint,
      round(extract(epoch from event.received_at) * 1000)::bigint,
      event.source_command_digest
    );

  select count(*) into v_event_body_digest_mismatches
  from esheep_cloud.events event
  where event.farm_id = p_farm_id
    and event.farm_generation = p_farm_generation
    and event.event_body_digest <> esheep_cloud.json_digest(event.event_body);

  select count(*) into v_command_digest_mismatches
  from esheep_cloud.commands command
  where command.farm_id = p_farm_id
    and command.farm_generation = p_farm_generation
    and command.content_digest <> esheep_cloud.sha256_hex(command.unsigned_command);

  select count(*) into v_event_command_mismatches
  from esheep_cloud.events event
  left join esheep_cloud.commands command on command.command_id = event.command_id
  where event.farm_id = p_farm_id
    and event.farm_generation = p_farm_generation
    and (
      command.command_id is null
      or command.farm_id <> event.farm_id
      or command.farm_generation <> event.farm_generation
      or command.content_digest <> event.source_command_digest
      or command.account_id <> event.actor_account_id
      or command.device_id <> event.source_device_id
      or command.device_sequence <> event.source_device_sequence
      or round(extract(epoch from command.occurred_at) * 1000)::bigint <>
         round(extract(epoch from event.occurred_at) * 1000)::bigint
    );

  -- Normal events must carry the exact strongly typed payload whose immutable
  -- command bytes were accepted. Resolution events are cross-bound to the
  -- durable attention record instead of pretending their signing bytes are
  -- JSON. This catches event-body substitution that the receipt chain alone
  -- cannot explain.
  select count(*) into v_event_body_mismatches
  from esheep_cloud.events event
  join esheep_cloud.commands command on command.command_id = event.command_id
  where event.farm_id = p_farm_id
    and event.farm_generation = p_farm_generation
    and case
      when command.command_kind = 'attention.resolve' then
        event.event_kind <> 'attention_resolved'
        or not exists (
          select 1
          from esheep_cloud.attention_items item
          where item.resolution_command_id = command.command_id
            and item.resolution_event_id = event.event_id
            and item.attention_id = esheep_cloud.safe_uuid_v2(
              event.event_body ->> 'attention_id'
            )
            and item.field_key = event.event_body ->> 'field'
            and item.resolution = event.event_body ->> 'choice'
            and item.status = 'resolved'
        )
      else
        esheep_cloud.safe_jsonb_from_utf8_v2(command.unsigned_command) is null
        or event.event_body ->> 'command_kind' is distinct from command.command_kind
        or event.event_body -> 'command_payload' is distinct from
          esheep_cloud.safe_jsonb_from_utf8_v2(command.unsigned_command) -> 'payload'
    end;

  for v_event in
    select event.event_digest
    from esheep_cloud.events event
    where event.farm_id = p_farm_id
      and event.farm_generation = p_farm_generation
    order by event.event_sequence
  loop
    v_computed_projection_digest := esheep_cloud.sha256_hex(convert_to(
      v_computed_projection_digest || chr(10) || v_event.event_digest,
      'utf8'
    ));
  end loop;
  v_projection_matches := v_computed_projection_digest = v_state.projection_digest;

  select count(*) into v_stream_digest_mismatches
  from esheep_cloud.streams stream
  where stream.farm_id = p_farm_id
    and stream.farm_generation = p_farm_generation
    and stream.content_digest <> esheep_cloud.json_digest(stream.canonical_state);

  select count(*) into v_stream_event_head_mismatches
  from esheep_cloud.streams stream
  where stream.farm_id = p_farm_id
    and stream.farm_generation = p_farm_generation
    and (
      stream.last_event_sequence <> coalesce((
        select max(event.event_sequence)
        from esheep_cloud.events event
        where event.farm_id = stream.farm_id
          and event.farm_generation = stream.farm_generation
          and event.stream_type = stream.stream_type
          and event.stream_id = stream.stream_id
      ), 0)
      or stream.last_event_sequence > v_state.event_head
      or (
        stream.last_event_sequence > 0
        and not exists (
          select 1
          from esheep_cloud.events event
          where event.farm_id = stream.farm_id
            and event.farm_generation = stream.farm_generation
            and event.stream_type = stream.stream_type
            and event.stream_id = stream.stream_id
            and event.event_sequence = stream.last_event_sequence
            and event.after_digest = stream.content_digest
        )
      )
    );

  select count(*) into v_stream_event_chain_mismatches
  from (
    select event.before_digest,
      lag(event.after_digest) over (
        partition by event.stream_type, event.stream_id
        order by event.event_sequence
      ) as previous_after_digest
    from esheep_cloud.events event
    where event.farm_id = p_farm_id
      and event.farm_generation = p_farm_generation
  ) chain
  where chain.previous_after_digest is not null
    and chain.before_digest <> chain.previous_after_digest;

  select count(*) into v_field_version_mismatches
  from esheep_cloud.streams stream
  cross join lateral jsonb_each(stream.field_versions) field_version(field_key, entry)
  where stream.farm_id = p_farm_id
    and stream.farm_generation = p_farm_generation
    and (
      jsonb_typeof(field_version.entry) <> 'object'
      or coalesce(field_version.entry ->> 'version', '') !~ '^[1-9][0-9]*$'
      or coalesce(field_version.entry ->> 'value_digest', '') !~ '^[0-9a-f]{64}$'
      or esheep_cloud.safe_uuid_v2(field_version.entry ->> 'account_id') is null
      or esheep_cloud.safe_uuid_v2(field_version.entry ->> 'device_id') is null
      or coalesce(field_version.entry ->> 'device_sequence', '') !~ '^[1-9][0-9]*$'
      or not (field_version.entry ? 'value')
      or esheep_cloud.safe_value_digest_v2(field_version.entry -> 'value')
        is distinct from field_version.entry ->> 'value_digest'
      or not (stream.canonical_state ? field_version.field_key)
      or stream.canonical_state -> field_version.field_key
        is distinct from field_version.entry -> 'value'
    );

  select count(*) into v_field_device_watermark_mismatches
  from esheep_cloud.field_device_watermarks watermark
  left join esheep_cloud.commands command
    on command.command_id = watermark.command_id
  where watermark.farm_id = p_farm_id
    and watermark.farm_generation = p_farm_generation
    and (
      command.command_id is null
      or command.farm_id <> watermark.farm_id
      or command.farm_generation <> watermark.farm_generation
      or command.device_id <> watermark.device_id
      or command.device_sequence <> watermark.highest_device_sequence
      or command.status not in ('accepted', 'needs_confirmation')
      or not exists (
        select 1
        from jsonb_array_elements(command.field_changes) change(value)
        where change.value ->> 'field' = watermark.field_key
          and esheep_cloud.safe_value_digest_v2(
            case change.value #>> '{mutation,action}'
              when 'clear' then jsonb_build_object('type', 'null')
              when 'set' then change.value #> '{mutation,value}'
              else null
            end
          ) = watermark.desired_value_digest
      )
    );

  v_field_device_watermark_mismatches :=
    v_field_device_watermark_mismatches + (
      select count(*)
      from esheep_cloud.commands command
      cross join lateral jsonb_array_elements(command.field_changes) change(value)
      left join esheep_cloud.field_device_watermarks watermark
        on watermark.farm_id = command.farm_id
       and watermark.farm_generation = command.farm_generation
       and watermark.stream_type = command.affected_streams -> 0 ->> 'type'
       and watermark.stream_id = esheep_cloud.safe_uuid_v2(
         command.affected_streams -> 0 ->> 'id'
       )
       and watermark.field_key = change.value ->> 'field'
       and watermark.device_id = command.device_id
      where command.farm_id = p_farm_id
        and command.farm_generation = p_farm_generation
        and command.status in ('accepted', 'needs_confirmation')
        and jsonb_array_length(command.field_changes) > 0
        and (
          watermark.device_id is null
          or watermark.highest_device_sequence < command.device_sequence
        )
    );

  select count(*) into v_asset_mismatches
  from esheep_cloud.assets asset
  where asset.farm_id = p_farm_id
    and asset.farm_generation = p_farm_generation
    and (
      asset.metadata_digest <> esheep_cloud.json_digest(asset.metadata)
      or (
        asset.thumbnail_state = 'verified'
        and (
          asset.thumbnail_sha256 is null
          or asset.thumbnail_byte_count <= 0
          or asset.thumbnail_path is distinct from
            lower(asset.farm_id::text) || '/' || asset.farm_generation::text || '/' ||
            lower(asset.asset_id::text) || '/' || asset.thumbnail_sha256 || '/thumbnail.jpg'
        )
      )
      or (
        asset.avatar_state = 'verified'
        and (
          asset.avatar_sha256 is null
          or asset.avatar_byte_count <= 0
          or asset.avatar_path is distinct from
            lower(asset.farm_id::text) || '/' || asset.farm_generation::text || '/' ||
            lower(asset.asset_id::text) || '/' || asset.avatar_sha256 || '/avatar.jpg'
        )
      )
      or (
        asset.original_state = 'verified'
        and (
          asset.original_sha256 is null
          or asset.original_byte_count <= 0
          or asset.original_path is distinct from
            lower(asset.farm_id::text) || '/' || asset.farm_generation::text || '/' ||
            lower(asset.asset_id::text) || '/' || asset.original_sha256 || '/original.bin'
        )
      )
    );

  with snapshot_totals as (
    select snapshot.snapshot_id,
      snapshot.boundary_event_sequence,
      snapshot.farm_profile_data,
      snapshot.farm_profile_digest,
      snapshot.manifest,
      snapshot.total_digest,
      snapshot.total_byte_count,
      snapshot.chunk_count,
      count(chunk.chunk_index)::integer as actual_chunk_count,
      coalesce(sum(chunk.byte_count), 0)::bigint as actual_total_bytes,
      min(chunk.chunk_index) as minimum_chunk_index,
      max(chunk.chunk_index) as maximum_chunk_index,
      coalesce(bool_and(
        chunk.content_sha256 = esheep_cloud.sha256_hex(chunk.content_data)
        and chunk.byte_count = octet_length(chunk.content_data)
      ), true) as chunks_valid,
      coalesce(string_agg(chunk.content_sha256, '' order by chunk.chunk_index), '')
        as chunk_digest_chain
    from esheep_cloud.snapshots snapshot
    left join esheep_cloud.snapshot_chunks chunk
      on chunk.snapshot_id = snapshot.snapshot_id
    where snapshot.farm_id = p_farm_id
      and snapshot.farm_generation = p_farm_generation
      and snapshot.status = 'verified'
    group by snapshot.snapshot_id
  )
  select count(*) into v_snapshot_mismatches
  from snapshot_totals snapshot
  where snapshot.farm_profile_data is null
    or snapshot.farm_profile_digest is distinct from
      esheep_cloud.sha256_hex(snapshot.farm_profile_data)
    or not snapshot.chunks_valid
    or snapshot.actual_chunk_count <> snapshot.chunk_count
    or snapshot.actual_total_bytes <> snapshot.total_byte_count
    or (
      snapshot.actual_chunk_count > 0
      and (
        snapshot.minimum_chunk_index <> 0
        or snapshot.maximum_chunk_index <> snapshot.actual_chunk_count - 1
      )
    )
    or snapshot.total_digest is distinct from esheep_cloud.sha256_hex(convert_to(
      snapshot.farm_profile_digest || snapshot.chunk_digest_chain,
      'utf8'
    ))
    or snapshot.manifest ->> 'snapshot_id' is distinct from lower(snapshot.snapshot_id::text)
    or snapshot.manifest ->> 'farm_id' is distinct from lower(p_farm_id::text)
    or esheep_cloud.safe_integer_v2(snapshot.manifest ->> 'farm_generation')
      is distinct from p_farm_generation
    or esheep_cloud.safe_bigint_v2(snapshot.manifest ->> 'boundary_event_sequence')
      is distinct from snapshot.boundary_event_sequence
    or snapshot.manifest ->> 'farm_profile_digest' is distinct from
      snapshot.farm_profile_digest
    or snapshot.manifest ->> 'total_digest' is distinct from snapshot.total_digest
    or esheep_cloud.safe_jsonb_array_length_v2(snapshot.manifest -> 'chunks')
      is distinct from snapshot.actual_chunk_count
    or snapshot.boundary_event_sequence > v_state.event_head;

  if v_state.latest_snapshot_id is not null and not exists (
    select 1
    from esheep_cloud.snapshots snapshot
    where snapshot.snapshot_id = v_state.latest_snapshot_id
      and snapshot.farm_id = p_farm_id
      and snapshot.farm_generation = p_farm_generation
      and snapshot.status = 'verified'
  ) then
    v_snapshot_mismatches := v_snapshot_mismatches + 1;
  end if;

  v_passed := v_event_sequence_valid
    and v_event_digest_mismatches = 0
    and v_event_body_digest_mismatches = 0
    and v_event_command_mismatches = 0
    and v_event_body_mismatches = 0
    and v_command_digest_mismatches = 0
    and v_projection_matches
    and v_stream_digest_mismatches = 0
    and v_stream_event_head_mismatches = 0
    and v_stream_event_chain_mismatches = 0
    and v_field_version_mismatches = 0
    and v_field_device_watermark_mismatches = 0
    and v_asset_mismatches = 0
    and v_snapshot_mismatches = 0;

  return jsonb_build_object(
    'passed', v_passed,
    'farm_id', p_farm_id,
    'farm_generation', p_farm_generation,
    'event_head', v_state.event_head,
    'event_count', v_event_count,
    'event_sequence_valid', v_event_sequence_valid,
    'stored_projection_digest', v_state.projection_digest,
    'computed_projection_digest', v_computed_projection_digest,
    'checks', jsonb_build_object(
      'event_digest_mismatches', v_event_digest_mismatches,
      'event_body_digest_mismatches', v_event_body_digest_mismatches,
      'event_command_mismatches', v_event_command_mismatches,
      'event_body_mismatches', v_event_body_mismatches,
      'command_digest_mismatches', v_command_digest_mismatches,
      'projection_digest_mismatches', case when v_projection_matches then 0 else 1 end,
      'stream_digest_mismatches', v_stream_digest_mismatches,
      'stream_event_head_mismatches', v_stream_event_head_mismatches,
      'stream_event_chain_mismatches', v_stream_event_chain_mismatches,
      'field_version_mismatches', v_field_version_mismatches,
      'field_device_watermark_mismatches', v_field_device_watermark_mismatches,
      'asset_mismatches', v_asset_mismatches,
      'snapshot_mismatches', v_snapshot_mismatches
    ),
    'checked_at', now()
  );
end;
$$;

create or replace function esheep_cloud.audit_farm_integrity_v2(
  p_farm_id uuid,
  p_farm_generation integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state esheep_cloud.farm_state%rowtype;
  v_report jsonb;
  v_trace_id uuid;
begin
  if (select auth.role()) <> 'service_role'
     and current_user not in ('postgres', 'supabase_admin') then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select * into v_state
  from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id
  for update;
  if not found or v_state.farm_generation <> p_farm_generation then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_farm_missing';
  end if;

  v_report := esheep_cloud.farm_integrity_report_v2(
    p_farm_id,
    p_farm_generation
  );
  if coalesce((v_report ->> 'passed')::boolean, false) then
    update esheep_cloud.farm_state
    set last_integrity_check_at = now(),
        last_integrity_report = v_report,
        updated_at = now()
    where farm_id = p_farm_id
      and farm_generation = p_farm_generation;
    return v_report;
  end if;

  v_trace_id := coalesce(v_state.write_freeze_trace_id, gen_random_uuid());
  v_report := v_report || jsonb_build_object('trace_id', v_trace_id);
  update esheep_cloud.farm_state
  set status = 'integrity_hold',
      write_frozen = true,
      write_freeze_trace_id = v_trace_id,
      last_integrity_check_at = now(),
      last_integrity_report = v_report,
      updated_at = now()
  where farm_id = p_farm_id
    and farm_generation = p_farm_generation;
  return v_report;
end;
$$;

create or replace function esheep_cloud.build_snapshot_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_chunk_record_limit integer default 500
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state esheep_cloud.farm_state%rowtype;
  v_profile esheep_cloud.farm_profiles%rowtype;
  v_snapshot_id uuid := gen_random_uuid();
  v_limit integer := greatest(100, least(coalesce(p_chunk_record_limit, 500), 1000));
  v_chunk record;
  v_manifest jsonb;
  v_total_digest text;
  v_total_bytes bigint;
  v_chunk_count integer;
  v_profile_data bytea;
  v_profile_digest text;
  v_integrity_report jsonb;
begin
  if (select auth.role()) <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  v_integrity_report := esheep_cloud.audit_farm_integrity_v2(
    p_farm_id,
    p_farm_generation
  );
  -- Returning NULL is intentional: raising here would roll back the durable
  -- integrity hold that the audit just recorded.
  if not coalesce((v_integrity_report ->> 'passed')::boolean, false) then
    return null;
  end if;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id and state.farm_generation = p_farm_generation
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_farm_missing';
  end if;
  if v_state.write_frozen then
    return null;
  end if;
  select * into v_profile
  from esheep_cloud.farm_profiles profile
  where profile.farm_id = p_farm_id
    and profile.farm_generation = p_farm_generation;
  if not found then
    raise exception using errcode = 'P0002', message = 'esheep_cloud_farm_profile_missing';
  end if;
  v_profile_data := convert_to(
    esheep_cloud.canonical_json_text(
      esheep_cloud.farm_profile_json_v2(v_profile)
    ),
    'utf8'
  );
  v_profile_digest := esheep_cloud.sha256_hex(v_profile_data);
  insert into esheep_cloud.snapshots (
    snapshot_id, farm_id, farm_generation, boundary_event_sequence,
    schema_version, farm_profile_data, farm_profile_digest
  ) values (
    v_snapshot_id, p_farm_id, p_farm_generation, v_state.event_head,
    v_state.schema_version, v_profile_data, v_profile_digest
  );

  for v_chunk in
    with records as (
      select 1 as kind_order, 0::bigint as sort_sequence,
        stream.stream_type as sort_type, stream.stream_id as sort_id,
        jsonb_build_object(
          'record_kind', 'stream',
          'stream_type', stream.stream_type,
          'stream_id', stream.stream_id,
          'stream_version', stream.stream_version,
          'field_versions', stream.field_versions,
          'canonical_state', stream.canonical_state,
          'content_digest', stream.content_digest,
          'last_event_sequence', stream.last_event_sequence
        ) as body
      from esheep_cloud.streams stream
      where stream.farm_id = p_farm_id and stream.farm_generation = p_farm_generation
      union all
      select 2, event.event_sequence, event.stream_type, event.event_id,
        jsonb_build_object(
          'record_kind', 'event',
          'event_sequence', event.event_sequence,
          'event_id', event.event_id,
          'command_id', event.command_id,
          'source_command_digest', event.source_command_digest,
          'stream_type', event.stream_type,
          'stream_id', event.stream_id,
          'event_kind', event.event_kind,
          'event_body_canonical', esheep_cloud.canonical_json_text(event.event_body),
          'event_body_digest', event.event_body_digest,
          'affected_fields', event.affected_fields,
          'before_digest', event.before_digest,
          'after_digest', event.after_digest,
          'actor_account_id', event.actor_account_id,
          'source_device_id', event.source_device_id,
          'source_device_sequence', event.source_device_sequence,
          'occurred_at_millis', round(extract(epoch from event.occurred_at) * 1000)::bigint,
          'received_at_millis', round(extract(epoch from event.received_at) * 1000)::bigint,
          'event_digest', event.event_digest
        )
      from esheep_cloud.events event
      where event.farm_id = p_farm_id and event.farm_generation = p_farm_generation
        and event.event_sequence <= v_state.event_head
      union all
      select 3, 0::bigint, 'photoAsset', asset.asset_id,
        jsonb_build_object(
          'record_kind', 'asset',
          'asset_id', asset.asset_id,
          'sheep_id', asset.sheep_id,
          'content_sha256', asset.content_sha256,
          'thumbnail_sha256', asset.thumbnail_sha256,
          'avatar_sha256', asset.avatar_sha256,
          'original_sha256', coalesce(asset.original_sha256, asset.content_sha256),
          'metadata', asset.metadata,
          'metadata_digest', asset.metadata_digest,
          'thumbnail_state', asset.thumbnail_state,
          'avatar_state', asset.avatar_state,
          'original_state', asset.original_state,
          'thumbnail_byte_count', asset.thumbnail_byte_count,
          'avatar_byte_count', asset.avatar_byte_count,
          'original_byte_count', asset.original_byte_count
        )
      from esheep_cloud.assets asset
      where asset.farm_id = p_farm_id and asset.farm_generation = p_farm_generation
    ), ordered as (
      select body, row_number() over (
        order by kind_order, sort_sequence, sort_type, sort_id
      ) as record_index
      from records
    ), numbered as (
      select body, record_index,
        (record_index - 1) / v_limit as chunk_index
      from ordered
    )
    select chunk_index::integer,
      convert_to(jsonb_agg(body order by record_index)::text, 'utf8') as content_data
    from numbered group by chunk_index order by chunk_index
  loop
    insert into esheep_cloud.snapshot_chunks (
      snapshot_id, chunk_index, content_data, content_sha256, byte_count
    ) values (
      v_snapshot_id, v_chunk.chunk_index, v_chunk.content_data,
      esheep_cloud.sha256_hex(v_chunk.content_data), octet_length(v_chunk.content_data)
    );
  end loop;

  select count(*), coalesce(sum(byte_count), 0),
    esheep_cloud.sha256_hex(convert_to(
      v_profile_digest || coalesce(string_agg(content_sha256, '' order by chunk_index), ''),
      'utf8'
    ))
  into v_chunk_count, v_total_bytes, v_total_digest
  from esheep_cloud.snapshot_chunks chunk where chunk.snapshot_id = v_snapshot_id;
  select jsonb_build_object(
    'snapshot_id', v_snapshot_id,
    'farm_id', p_farm_id,
    'schema_version', v_state.schema_version,
    'farm_generation', p_farm_generation,
    'boundary_event_sequence', v_state.event_head,
    'event_head_at_creation', v_state.event_head,
    'created_at', now(),
    'business_history_started_at', (
      select min(event.occurred_at)
      from esheep_cloud.events event
      where event.farm_id = p_farm_id
        and event.farm_generation = p_farm_generation
        and event.event_sequence <= v_state.event_head
    ),
    'business_history_ended_at', (
      select max(event.occurred_at)
      from esheep_cloud.events event
      where event.farm_id = p_farm_id
        and event.farm_generation = p_farm_generation
        and event.event_sequence <= v_state.event_head
    ),
    'record_counts', jsonb_build_object(
      'streams', (select count(*) from esheep_cloud.streams stream where stream.farm_id = p_farm_id and stream.farm_generation = p_farm_generation),
      'events', (select count(*) from esheep_cloud.events event where event.farm_id = p_farm_id and event.farm_generation = p_farm_generation and event.event_sequence <= v_state.event_head),
      'assets', (select count(*) from esheep_cloud.assets asset where asset.farm_id = p_farm_id and asset.farm_generation = p_farm_generation)
    ),
    'chunks', coalesce((select jsonb_agg(jsonb_build_object(
      'index', chunk.chunk_index, 'byte_count', chunk.byte_count,
      'content_sha256', chunk.content_sha256
    ) order by chunk.chunk_index) from esheep_cloud.snapshot_chunks chunk where chunk.snapshot_id = v_snapshot_id), '[]'::jsonb),
    'relationship_digest', v_state.projection_digest,
    'field_version_digest', esheep_cloud.json_digest(coalesce((select jsonb_agg(stream.field_versions order by stream.stream_type, stream.stream_id) from esheep_cloud.streams stream where stream.farm_id = p_farm_id and stream.farm_generation = p_farm_generation), '[]'::jsonb)),
    'farm_profile_digest', v_profile_digest,
    'assets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'asset_id', asset.asset_id,
        'sheep_id', asset.sheep_id,
        'content_sha256', asset.content_sha256,
        'thumbnail_sha256', asset.thumbnail_sha256,
        'avatar_sha256', asset.avatar_sha256,
        'original_sha256', coalesce(asset.original_sha256, asset.content_sha256),
        'thumbnail_byte_count', asset.thumbnail_byte_count,
        'avatar_byte_count', asset.avatar_byte_count,
        'original_byte_count', asset.original_byte_count,
        'is_current_avatar', exists (
          select 1
          from esheep_cloud.streams avatar_stream
          where avatar_stream.farm_id = asset.farm_id
            and avatar_stream.farm_generation = asset.farm_generation
            and avatar_stream.stream_type = 'sheepAvatar'
            and avatar_stream.canonical_state #>> '{avatar,value}' = lower(asset.asset_id::text)
        )
      ) order by asset.asset_id)
      from esheep_cloud.assets asset
      where asset.farm_id = p_farm_id
        and asset.farm_generation = p_farm_generation
    ), '[]'::jsonb),
    'total_digest', v_total_digest
  ) into v_manifest;
  update esheep_cloud.snapshots
  set manifest = v_manifest, total_digest = v_total_digest,
      total_byte_count = v_total_bytes, chunk_count = v_chunk_count,
      status = 'verified', verified_at = now()
  where snapshot_id = v_snapshot_id;
  update esheep_cloud.farm_state
  set latest_snapshot_id = v_snapshot_id, updated_at = now()
  where farm_id = p_farm_id;
  return v_snapshot_id;
end;
$$;

create or replace function esheep_cloud.mark_migration_ready_v2(
  p_farm_id uuid,
  p_source_generation integer,
  p_target_generation integer,
  p_source_manifest_digest text,
  p_target_manifest_digest text,
  p_parity_report jsonb,
  p_parity_digest text,
  p_projection_digest text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_computed_parity_digest text;
  v_integrity_report jsonb;
begin
  if (select auth.role()) <> 'service_role' and current_user not in ('postgres', 'supabase_admin') then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  perform esheep_cloud.assert_protocol_ready_v2();
  if lower(p_source_manifest_digest) !~ '^[0-9a-f]{64}$'
     or lower(p_target_manifest_digest) !~ '^[0-9a-f]{64}$'
     or lower(p_parity_digest) !~ '^[0-9a-f]{64}$'
     or lower(p_projection_digest) !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'esheep_cloud_migration_digest_invalid';
  end if;
  if p_farm_id is null
     or p_source_generation < 0
     or p_target_generation <> p_source_generation + 1 then
    raise exception using errcode = '22023', message = 'esheep_cloud_migration_generation_invalid';
  end if;
  v_computed_parity_digest := esheep_cloud.json_digest(p_parity_report);
  if lower(p_source_manifest_digest) <> lower(p_target_manifest_digest) or
     lower(p_parity_digest) <> v_computed_parity_digest or
     coalesce((p_parity_report ->> 'all_checks_passed')::boolean, false) is not true then
    insert into esheep_cloud.migration_reconciliations (
      farm_id, source_generation, target_generation, status,
      source_manifest_digest, target_manifest_digest, parity_report, parity_digest
    ) values (
      p_farm_id, p_source_generation, p_target_generation, 'parity_failed',
      lower(p_source_manifest_digest), lower(p_target_manifest_digest),
      p_parity_report, v_computed_parity_digest
    ) on conflict (farm_id) do update set
      status = 'parity_failed', parity_report = excluded.parity_report,
      parity_digest = excluded.parity_digest,
      source_manifest_digest = excluded.source_manifest_digest,
      target_manifest_digest = excluded.target_manifest_digest, updated_at = now();
    -- A failed retry must not leave a previous preparing generation looking
    -- ready in the status endpoint.  Keep an existing integrity hold intact;
    -- it carries the durable trace explaining why writes are frozen.
    update esheep_cloud.farm_state
    set v2_ready = false, status = 'preparing', updated_at = now()
    where farm_id = p_farm_id
      and farm_generation = p_target_generation
      and status in ('preparing', 'read_only');
    return;
  end if;
  insert into esheep_cloud.farm_state (
    farm_id, farm_generation, status, v2_ready, projection_digest
  ) values (
    p_farm_id, p_target_generation, 'preparing', false, lower(p_projection_digest)
  ) on conflict (farm_id) do update set
    farm_generation = excluded.farm_generation, status = 'preparing',
    v2_ready = false, projection_digest = excluded.projection_digest,
    updated_at = now();
  v_integrity_report := esheep_cloud.audit_farm_integrity_v2(
    p_farm_id,
    p_target_generation
  );
  if not coalesce((v_integrity_report ->> 'passed')::boolean, false) then
    insert into esheep_cloud.migration_reconciliations (
      farm_id, source_generation, target_generation, status,
      source_manifest_digest, target_manifest_digest, parity_report, parity_digest
    ) values (
      p_farm_id, p_source_generation, p_target_generation, 'parity_failed',
      lower(p_source_manifest_digest), lower(p_target_manifest_digest),
      p_parity_report, v_computed_parity_digest
    ) on conflict (farm_id) do update set
      status = 'parity_failed', parity_report = excluded.parity_report,
      parity_digest = excluded.parity_digest,
      source_manifest_digest = excluded.source_manifest_digest,
      target_manifest_digest = excluded.target_manifest_digest, updated_at = now();
    return;
  end if;
  update esheep_cloud.farm_state
  set v2_ready = true, status = 'preparing', updated_at = now()
  where farm_id = p_farm_id
    and farm_generation = p_target_generation;
  insert into esheep_cloud.migration_reconciliations (
    farm_id, source_generation, target_generation, status,
    source_manifest_digest, target_manifest_digest, parity_report, parity_digest
  ) values (
    p_farm_id, p_source_generation, p_target_generation, 'v2_ready',
    lower(p_source_manifest_digest), lower(p_target_manifest_digest),
    p_parity_report, v_computed_parity_digest
  ) on conflict (farm_id) do update set
    status = 'v2_ready', source_manifest_digest = excluded.source_manifest_digest,
    target_manifest_digest = excluded.target_manifest_digest,
    parity_report = excluded.parity_report,
    parity_digest = excluded.parity_digest, updated_at = now();
end;
$$;

create or replace function public.esheep_cloud_cut_over_farm_v2(
  p_farm_id uuid,
  p_expected_source_generation integer,
  p_expected_parity_digest text
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
begin
  if not esheep_private.is_active_farm_member(p_farm_id, array['owner']) then
    raise exception using errcode = '42501', message = 'esheep_cloud_owner_required';
  end if;
  perform esheep_cloud.assert_protocol_ready_v2();
  select * into v_registry from public.farm_registry registry
  where registry.farm_id = p_farm_id for update;
  select * into v_migration from esheep_cloud.migration_reconciliations migration
  where migration.farm_id = p_farm_id for update;
  select * into v_state from esheep_cloud.farm_state state
  where state.farm_id = p_farm_id for update;
  -- A cut-over is an authority change, not a UI transition. Validate every
  -- locked row and the immutable snapshot explicitly; relying on FOUND from
  -- the last SELECT would let a missing registry or migration row turn NULL
  -- comparisons into a false (and potentially unsafe) pass.
  if v_registry.farm_id is null
     or v_migration.farm_id is null
     or v_state.farm_id is null
     or p_expected_source_generation < 0
     or p_expected_parity_digest is null
     or lower(p_expected_parity_digest) !~ '^[0-9a-f]{64}$'
     or v_registry.provider <> 'supabase'
     or v_registry.status not in ('active', 'read_only')
     or v_registry.authority_generation <> p_expected_source_generation
     or v_migration.source_generation <> p_expected_source_generation
     or v_migration.target_generation <> p_expected_source_generation + 1
     or v_migration.status <> 'v2_ready'
     or not v_state.v2_ready
     or v_state.status not in ('preparing', 'read_only')
     or v_state.farm_generation <> v_migration.target_generation
     or v_migration.parity_digest <> lower(p_expected_parity_digest)
     or v_migration.source_manifest_digest <> v_migration.target_manifest_digest
     or coalesce((v_migration.parity_report ->> 'all_checks_passed')::boolean, false) is not true
     or v_state.latest_snapshot_id is null
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
         and (snapshot.manifest ->> 'total_digest') = snapshot.total_digest
     ) then
    raise exception using errcode = '40001', message = 'esheep_cloud_cutover_precondition_failed';
  end if;
  v_integrity_report := esheep_cloud.audit_farm_integrity_v2(
    p_farm_id,
    v_state.farm_generation
  );
  if not coalesce((v_integrity_report ->> 'passed')::boolean, false)
     or v_state.write_frozen then
    return jsonb_build_object(
      'farm_id', p_farm_id,
      'farm_generation', v_state.farm_generation,
      'status', 'integrity_hold',
      'trace_id', coalesce(
        v_integrity_report ->> 'trace_id',
        v_state.write_freeze_trace_id::text
      )
    );
  end if;
  update public.farm_registry
  set provider = 'esheep_cloud', status = 'active',
      authority_generation = v_migration.target_generation,
      updated_at = now()
  where farm_id = p_farm_id;
  update esheep_cloud.farm_state
  set status = 'active', v1_final_revision = v_registry.current_revision,
      updated_at = now()
  where farm_id = p_farm_id;
  update esheep_cloud.migration_reconciliations
  set status = 'cut_over', v1_final_event_boundary = v_registry.current_revision,
      cut_over_at = now(), updated_at = now()
  where farm_id = p_farm_id;
  return jsonb_build_object(
    'farm_id', p_farm_id,
    'farm_generation', v_migration.target_generation,
    'provider', 'eSheepCloud',
    'status', 'active'
  );
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit)
values ('esheep-cloud-assets', 'esheep-cloud-assets', false, 52428800)
on conflict (id) do update
set public = false, file_size_limit = excluded.file_size_limit;

create or replace function esheep_cloud.storage_path_is_authorized(
  p_name text,
  p_require_recycle_expired boolean default false,
  p_require_writable_upload boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and split_part(p_name, '/', 2) ~ '^[0-9]+$'
    and split_part(p_name, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and split_part(p_name, '/', 4) ~ '^[0-9a-f]{64}$'
    and split_part(p_name, '/', 5) ~ '^(thumbnail|avatar)\.jpg$|^original\.bin$'
    and esheep_private.is_active_farm_member(
      split_part(p_name, '/', 1)::uuid,
      case when p_require_recycle_expired
        then array['owner']::text[]
        else array['owner', 'administrator', 'worker']::text[]
      end
    )
    and exists (
      select 1
      from esheep_cloud.assets asset
      join esheep_cloud.farm_state state on state.farm_id = asset.farm_id
      where asset.farm_id = split_part(p_name, '/', 1)::uuid
        and asset.farm_generation = split_part(p_name, '/', 2)::integer
        and asset.asset_id = split_part(p_name, '/', 3)::uuid
        and case split_part(p_name, '/', 5)
          when 'thumbnail.jpg' then asset.thumbnail_sha256
          when 'avatar.jpg' then asset.avatar_sha256
          when 'original.bin' then asset.original_sha256
        end = split_part(p_name, '/', 4)
        and state.farm_generation = asset.farm_generation
        and case
          when p_require_recycle_expired or p_require_writable_upload
            then state.status = 'active' and not state.write_frozen
          else state.status in ('active', 'read_only')
        end
        and (
          not p_require_writable_upload
          or case split_part(p_name, '/', 5)
            when 'thumbnail.jpg' then asset.thumbnail_state
            when 'avatar.jpg' then asset.avatar_state
            when 'original.bin' then asset.original_state
          end = 'transferring'
        )
        and (not p_require_recycle_expired or asset.recycle_expires_at <= now())
    );
$$;

drop policy if exists esheep_cloud_assets_select_member on storage.objects;
create policy esheep_cloud_assets_select_member
on storage.objects for select to authenticated
using (
  bucket_id = 'esheep-cloud-assets'
  and esheep_cloud.storage_path_is_authorized(name, false, false)
);

drop policy if exists esheep_cloud_assets_insert_member on storage.objects;
create policy esheep_cloud_assets_insert_member
on storage.objects for insert to authenticated
with check (
  bucket_id = 'esheep-cloud-assets'
  and esheep_cloud.storage_path_is_authorized(name, false, true)
  and lower(coalesce(user_metadata ->> 'sha256', '')) = split_part(name, '/', 4)
);

drop policy if exists esheep_cloud_assets_update_member on storage.objects;
create policy esheep_cloud_assets_update_member
on storage.objects for update to authenticated
using (
  bucket_id = 'esheep-cloud-assets'
  and esheep_cloud.storage_path_is_authorized(name, false, true)
)
with check (
  bucket_id = 'esheep-cloud-assets'
  and esheep_cloud.storage_path_is_authorized(name, false, true)
  and lower(coalesce(user_metadata ->> 'sha256', '')) = split_part(name, '/', 4)
);

drop policy if exists esheep_cloud_assets_delete_owner_after_recycle on storage.objects;
create policy esheep_cloud_assets_delete_owner_after_recycle
on storage.objects for delete to authenticated
using (
  bucket_id = 'esheep-cloud-assets'
  and esheep_cloud.storage_path_is_authorized(name, true, false)
);

create or replace function esheep_cloud.broadcast_event_hint_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'farm_id', new.farm_id,
      'farm_generation', new.farm_generation,
      'event_head', new.event_sequence
    ),
    'event_head_changed',
    'farm:' || lower(new.farm_id::text),
    true
  );
  return new;
exception when others then
  -- Realtime is only a hint. A disabled or delayed broadcast must never roll
  -- back the authoritative event transaction; clients poll event_head too.
  return new;
end;
$$;

drop trigger if exists esheep_cloud_event_hint_after_insert on esheep_cloud.events;
create trigger esheep_cloud_event_hint_after_insert
after insert on esheep_cloud.events
for each row execute function esheep_cloud.broadcast_event_hint_v2();

alter table esheep_cloud.farm_state enable row level security;
alter table esheep_cloud.farm_profiles enable row level security;
alter table esheep_cloud.command_catalog enable row level security;
alter table esheep_cloud.commands enable row level security;
alter table esheep_cloud.streams enable row level security;
alter table esheep_cloud.events enable row level security;
alter table esheep_cloud.attention_items enable row level security;
alter table esheep_cloud.field_device_watermarks enable row level security;
alter table esheep_cloud.assets enable row level security;
alter table esheep_cloud.snapshots enable row level security;
alter table esheep_cloud.snapshot_chunks enable row level security;
alter table esheep_cloud.migration_reconciliations enable row level security;

revoke all privileges on all tables in schema esheep_cloud
  from public, anon, authenticated;
revoke all privileges on all sequences in schema esheep_cloud
  from public, anon, authenticated;
revoke execute on all functions in schema esheep_cloud
  from public, anon, authenticated;
alter default privileges for role postgres in schema esheep_cloud
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema esheep_cloud
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema esheep_cloud
  revoke execute on functions from public, anon, authenticated;

revoke all on function public.esheep_cloud_submit_verified_commands_v2(uuid, uuid, integer, jsonb)
  from public, anon, authenticated;
revoke all on function public.esheep_cloud_pull_events_v2(uuid, integer, bigint, integer)
  from public, anon;
revoke all on function public.esheep_cloud_query_command_status_v2(uuid, uuid[])
  from public, anon;
revoke all on function public.esheep_cloud_fetch_status_v2(uuid)
  from public, anon;
revoke all on function public.esheep_cloud_resolve_verified_attention_v2(uuid, uuid, integer, uuid, uuid, text, text, uuid, uuid, bigint, text)
  from public, anon, authenticated;
revoke all on function public.esheep_cloud_open_initial_sync_v2(uuid, integer)
  from public, anon;
revoke all on function public.esheep_cloud_create_invite_v2(uuid, text)
  from public, anon;
revoke all on function public.esheep_cloud_list_my_farms_v2()
  from public, anon;
revoke all on function public.esheep_cloud_redeem_invite_v2(text)
  from public, anon;
revoke all on function public.esheep_cloud_list_members_v2(uuid)
  from public, anon;
revoke all on function public.esheep_cloud_revoke_member_v2(uuid, uuid)
  from public, anon;
revoke all on function public.esheep_cloud_download_snapshot_chunk_v2(uuid, integer)
  from public, anon;
revoke all on function public.esheep_cloud_prepare_asset_transfer_v2(uuid, integer, uuid, uuid, text, text, jsonb, text, text, text, bigint)
  from public, anon;
revoke all on function public.esheep_cloud_asset_verification_target_v2(uuid, uuid, integer, uuid, text)
  from public, anon, authenticated;
revoke all on function public.esheep_cloud_confirm_verified_asset_v2(uuid, uuid, integer, uuid, text, text, bigint)
  from public, anon, authenticated;
revoke all on function public.esheep_cloud_cut_over_farm_v2(uuid, integer, text)
  from public, anon;

grant execute on function public.esheep_cloud_submit_verified_commands_v2(uuid, uuid, integer, jsonb)
  to service_role;
grant execute on function public.esheep_cloud_pull_events_v2(uuid, integer, bigint, integer)
  to authenticated;
grant execute on function public.esheep_cloud_query_command_status_v2(uuid, uuid[])
  to authenticated;
grant execute on function public.esheep_cloud_fetch_status_v2(uuid)
  to authenticated;
grant execute on function public.esheep_cloud_resolve_verified_attention_v2(uuid, uuid, integer, uuid, uuid, text, text, uuid, uuid, bigint, text)
  to service_role;
grant execute on function public.esheep_cloud_open_initial_sync_v2(uuid, integer)
  to authenticated;
grant execute on function public.esheep_cloud_create_invite_v2(uuid, text)
  to authenticated;
grant execute on function public.esheep_cloud_list_my_farms_v2()
  to authenticated;
grant execute on function public.esheep_cloud_redeem_invite_v2(text)
  to authenticated;
grant execute on function public.esheep_cloud_list_members_v2(uuid)
  to authenticated;
grant execute on function public.esheep_cloud_revoke_member_v2(uuid, uuid)
  to authenticated;
grant execute on function public.esheep_cloud_download_snapshot_chunk_v2(uuid, integer)
  to authenticated;
grant execute on function public.esheep_cloud_prepare_asset_transfer_v2(uuid, integer, uuid, uuid, text, text, jsonb, text, text, text, bigint)
  to authenticated;
grant execute on function public.esheep_cloud_asset_verification_target_v2(uuid, uuid, integer, uuid, text)
  to service_role;
grant execute on function public.esheep_cloud_confirm_verified_asset_v2(uuid, uuid, integer, uuid, text, text, bigint)
  to service_role;
grant execute on function public.esheep_cloud_cut_over_farm_v2(uuid, integer, text)
  to authenticated;

-- Storage policies execute this private predicate while evaluating an
-- authenticated request. Schema USAGE remains revoked, so clients still
-- cannot discover or invoke private business objects directly.
grant execute on function esheep_cloud.storage_path_is_authorized(text, boolean, boolean)
  to authenticated;

grant execute on function esheep_cloud.build_snapshot_v2(uuid, integer, integer)
  to service_role;
grant execute on function esheep_cloud.farm_integrity_report_v2(uuid, integer)
  to service_role;
grant execute on function esheep_cloud.audit_farm_integrity_v2(uuid, integer)
  to service_role;
grant execute on function esheep_cloud.upsert_farm_profile_v2(
  uuid, integer, uuid, text, timestamptz, timestamptz, text,
  double precision, double precision, text, text, text,
  double precision, timestamptz
) to service_role;
grant execute on function esheep_cloud.mark_migration_ready_v2(uuid, integer, integer, text, text, jsonb, text, text)
  to service_role;
grant execute on function esheep_cloud.protocol_readiness_report_v2()
  to service_role;
grant execute on function esheep_cloud.assert_protocol_ready_v2()
  to service_role;

notify pgrst, 'reload schema';
