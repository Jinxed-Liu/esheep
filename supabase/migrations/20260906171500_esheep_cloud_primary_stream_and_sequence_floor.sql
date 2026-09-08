-- Abort if another deployment changed any of the reviewed functions.
set local lock_timeout = '5s';
set local statement_timeout = '60s';
do $reviewed_functions$
begin
  if md5(pg_get_functiondef('esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure)) <> '364e24a98449f37fda1306cfd22738b7' then
    raise exception 'Reviewed function changed: esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb)';
  end if;
  if md5(pg_get_functiondef('esheep_cloud.process_command_v2(uuid,integer,uuid,jsonb)'::regprocedure)) <> 'fb9276c812c4c63bcb20defb233de66b' then
    raise exception 'Reviewed function changed: esheep_cloud.process_command_v2(uuid,integer,uuid,jsonb)';
  end if;
  if md5(pg_get_functiondef('esheep_cloud_submit_verified_commands_v2(uuid,uuid,integer,jsonb)'::regprocedure)) <> '2a06f3a28020cd3c2de58d9ae2f7d0bb' then
    raise exception 'Reviewed function changed: esheep_cloud_submit_verified_commands_v2(uuid,uuid,integer,jsonb)';
  end if;
  if md5(pg_get_functiondef('esheep_cloud_fetch_status_v2(uuid)'::regprocedure)) <> '333b73fe07de00e25fd4b859d266d912' then
    raise exception 'Reviewed function changed: esheep_cloud_fetch_status_v2(uuid)';
  end if;
end;
$reviewed_functions$;

-- Canonical array order is a signing contract, never business priority.
create or replace function esheep_cloud.primary_stream_v2(p_kind text, p_streams jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $function$
declare
  v_expected_stream_type text;
  v_stream jsonb;
begin
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

  if v_expected_stream_type is null then return p_streams -> 0; end if;
  select value into v_stream from jsonb_array_elements(p_streams)
  where value ->> 'type' = v_expected_stream_type;
  if v_stream is null or (select count(*) from jsonb_array_elements(p_streams)
      where value ->> 'type' = v_expected_stream_type) <> 1 then
    raise exception using errcode='22023', message='esheep_cloud_primary_stream_invalid';
  end if;
  return v_stream;
end;
$function$;
revoke all on function esheep_cloud.primary_stream_v2(text,jsonb) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION esheep_cloud.validate_command_semantics_v2(p_kind text, p_payload jsonb, p_merge_mode text, p_affected_streams jsonb, p_affected_fields jsonb, p_field_changes jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := esheep_cloud.normalize_contract_json_v2(p_payload);
  v_streams jsonb := esheep_cloud.normalize_contract_json_v2(p_affected_streams);
  v_fields jsonb := esheep_cloud.normalize_contract_json_v2(p_affected_fields);
  v_field_changes jsonb;
begin
  if p_kind = 'farm.updateLocation' then
    v_payload := jsonb_build_object(
      'kind', p_kind,
      'body', jsonb_build_object(
        'updateLocation', v_payload #> '{body,action,updateLocation}'
      )
    );
  end if;

  select coalesce(jsonb_agg(
    case
      when item.value #>> '{mutation,value,type}' = 'decimal' then
        jsonb_set(item.value, '{mutation,value,type}', '"string"'::jsonb)
      else item.value
    end
    order by item.ordinality
  ), '[]'::jsonb)
  into v_field_changes
  from jsonb_array_elements(coalesce(p_field_changes, '[]'::jsonb))
    with ordinality item(value, ordinality);
  v_field_changes := esheep_cloud.normalize_contract_json_v2(v_field_changes);

  -- Reorder only the validation view; signed bytes remain untouched.
  select coalesce(jsonb_agg(item.value order by
      (item.value = esheep_cloud.primary_stream_v2(p_kind, v_streams)) desc,
      item.ordinality), '[]'::jsonb)
  into v_streams from jsonb_array_elements(v_streams) with ordinality item(value, ordinality);

  perform esheep_cloud.validate_command_semantics_v2_legacy(
    p_kind,
    v_payload,
    p_merge_mode,
    v_streams,
    v_fields,
    v_field_changes
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION esheep_cloud.process_command_v2(p_farm_id uuid, p_farm_generation integer, p_user_id uuid, p_item jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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


  -- Executed after the farm row lock and after ordinary signature/role/scope
  -- checks and BOTH duplicate branches, before any new ledger mutation.
  -- Concurrent retries waiting on the farm lock must also remain idempotent.
  -- The earlier duplicate branch
  -- still returns the original receipt after expiry/head advancement.
  if v_kind in ('migration.restoreSheepBaseline','migration.restoreRemoval','migration.restoreBusinessBaseline') then
    if v_role <> 'owner' or not exists (
      select 1 from esheep_cloud.history_repair_approvals approval
      where approval.command_id=v_command_id and approval.farm_id=p_farm_id
        and approval.farm_generation=p_farm_generation
        and approval.approved_by_user_id=p_user_id
        and approval.command_kind=v_kind and approval.content_digest=v_digest
        and approval.expected_event_head=v_farm_state.event_head
        and approval.expires_at>clock_timestamp()
    ) or jsonb_array_length(v_affected_streams)<>1 then
      raise exception using errcode='42501',message='esheep_cloud_history_repair_not_approved';
    end if;
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
    return jsonb_build_object('command_id',v_command_id,'type','rejected','reason',jsonb_build_object('code','device_sequence_reused','message','设备操作编号与历史记录重复；已保留本机内容，需要校正编号后恢复保存。'));
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
  v_stream_type := esheep_cloud.primary_stream_v2(v_kind, v_affected_streams) ->> 'type';
  v_stream_id := (esheep_cloud.primary_stream_v2(v_kind, v_affected_streams) ->> 'id')::uuid;

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

  -- Legacy photo tombstones must honor the same avatar-reference protection
  -- as the dedicated photo lifecycle. A recovery bundle clears the exact
  -- observed avatar first, within the same transaction.
  if v_kind = 'record.revoke'
     and lower(v_unsigned_json #>> '{payload,body,tombstone,entityType}') = 'photoasset'
     and exists (
       select 1 from esheep_cloud.streams avatar_stream
       where avatar_stream.farm_id = p_farm_id
         and avatar_stream.farm_generation = p_farm_generation
         and avatar_stream.stream_type = 'sheepAvatar'
         and lower(avatar_stream.canonical_state #>> '{avatar,value}') = lower(v_stream_id::text)
     ) then
    return jsonb_build_object('command_id', v_command_id, 'type', 'rejected',
      'reason', jsonb_build_object('code', 'photo_avatar_reference_exists',
        'message', '这张照片仍被用作头像，需要先保存头像移除或更换，再删除照片。'));
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
             'parityRecordedAt', 'note', 'isHistoricalArchive'
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
        where stream.value <> esheep_cloud.primary_stream_v2(v_kind, v_affected_streams)
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
$function$
;
CREATE OR REPLACE FUNCTION public.esheep_cloud_fetch_status_v2(p_farm_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'device_sequence_floor', (select coalesce(max(command.device_sequence),0) from esheep_cloud.commands command where command.farm_id=p_farm_id),
    'latest_snapshot_id', v_state.latest_snapshot_id,
    'v2_ready', v_state.v2_ready,
    'write_frozen', v_state.write_frozen,
    'write_freeze_trace_id', v_state.write_freeze_trace_id,
    'attention_items', v_attention,
    'server_time', now()
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.esheep_cloud_submit_verified_commands_v2(p_user_id uuid, p_farm_id uuid, p_farm_generation integer, p_commands jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_item jsonb;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_command_id text;
  v_unsigned_json jsonb;
  v_contains_bundle boolean := false;
  v_bundle_id uuid;
  v_bundle_invalid boolean := false;
  v_bundle_commands jsonb := '[]'::jsonb;
  v_weaning jsonb;
  v_transfer jsonb;
  v_bundle_failure_reason jsonb;
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
      v_bundle_commands := v_bundle_commands || jsonb_build_array(v_unsigned_json);
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
    -- All members must be present in this request, including when an unbundled
    -- command appears before the first bundled member.
    v_bundle_invalid := v_bundle_invalid or exists (
      select 1 from jsonb_array_elements(v_bundle_commands) item
      where nullif(item ->> 'bundleID', '')::uuid is distinct from v_bundle_id
    );
    if exists (select 1 from jsonb_array_elements(v_bundle_commands) item
               where item ->> 'commandKind' = 'weaning.record' or
                 (item ->> 'commandKind' = 'transfer.record' and item #>> '{payload,body,transferSheep,note}' = '随断奶事件调舍')) then
      select item into v_weaning from jsonb_array_elements(v_bundle_commands) item
      where item ->> 'commandKind' = 'weaning.record';
      select item into v_transfer from jsonb_array_elements(v_bundle_commands) item
      where item ->> 'commandKind' = 'transfer.record';
      v_bundle_invalid := v_bundle_invalid or jsonb_array_length(v_bundle_commands) <> 2
        or v_transfer is null or v_weaning is null
        or (v_weaning #>> '{payload,body,recordWeaning,sheepID}') is distinct from
           (v_transfer #>> '{payload,body,transferSheep,sheepID}')
        or (v_weaning #> '{payload,body,recordWeaning,occurredAt}') is distinct from
           (v_transfer #> '{payload,body,transferSheep,occurredAt}')
        or (v_transfer #>> '{payload,body,transferSheep,toPenID}') is null;
    end if;
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
        if not coalesce(v_result ->> 'type' = 'accepted' or
                (v_result ->> 'type' = 'duplicate' and v_result #>> '{original,type}' = 'accepted'), false) then
          v_bundle_failure_reason := coalesce(v_result -> 'reason', v_result #> '{original,reason}');
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
            'message', '这组关联操作未保存，本机内容已保留。' ||
              coalesce(v_bundle_failure_reason ->> 'message', '请在核对信息中查看失败原因。'),
            'cause', v_bundle_failure_reason
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
$function$
;
