begin;

create extension if not exists pgtap with schema extensions;
select plan(147);

select set_config('esheep.test.user_a', gen_random_uuid()::text, false);
select set_config('esheep.test.user_b', gen_random_uuid()::text, false);
select set_config('esheep.test.user_c', gen_random_uuid()::text, false);
select set_config('esheep.test.account_a', gen_random_uuid()::text, false);
select set_config('esheep.test.account_b', gen_random_uuid()::text, false);
select set_config('esheep.test.account_c', gen_random_uuid()::text, false);
select set_config('esheep.test.farm', gen_random_uuid()::text, false);
select set_config('esheep.test.sheep', gen_random_uuid()::text, false);
select set_config('esheep.test.device_a', gen_random_uuid()::text, false);
select set_config('esheep.test.device_b', gen_random_uuid()::text, false);
select set_config('esheep.test.asset_a', gen_random_uuid()::text, false);
select set_config('esheep.test.asset_b', gen_random_uuid()::text, false);
select set_config('esheep.test.avatar_a_command', gen_random_uuid()::text, false);
select set_config('esheep.test.avatar_a_request', gen_random_uuid()::text, false);
select set_config('esheep.test.avatar_b_command', gen_random_uuid()::text, false);
select set_config('esheep.test.cross_account_dependency_command', gen_random_uuid()::text, false);
select set_config('esheep.test.profile_ear_tag_command', gen_random_uuid()::text, false);
select set_config('esheep.test.profile_breed_command', gen_random_uuid()::text, false);
select set_config('esheep.test.profile_converge_command', gen_random_uuid()::text, false);
select set_config('esheep.test.unknown_schema_command', gen_random_uuid()::text, false);
select set_config('esheep.test.sequence_reuse_command', gen_random_uuid()::text, false);
select set_config('esheep.test.source_request_reuse_command', gen_random_uuid()::text, false);
select set_config('esheep.test.unimplemented_command', gen_random_uuid()::text, false);
select set_config('esheep.test.missing_asset_command', gen_random_uuid()::text, false);
select set_config('esheep.test.missing_asset', gen_random_uuid()::text, false);
select set_config('esheep.test.blocked_prerequisite_command', gen_random_uuid()::text, false);
select set_config('esheep.test.missing_prerequisite', gen_random_uuid()::text, false);
select set_config('esheep.test.stale_resolution_command', gen_random_uuid()::text, false);
select set_config('esheep.test.attention_resolution_command', gen_random_uuid()::text, false);
select set_config('esheep.test.photo_register_command', gen_random_uuid()::text, false);
select set_config('esheep.test.photo_register_request', gen_random_uuid()::text, false);
select set_config('esheep.test.bundle_command', gen_random_uuid()::text, false);
select set_config('esheep.test.multistream_command', gen_random_uuid()::text, false);
select set_config('esheep.test.multistream_primary', gen_random_uuid()::text, false);
select set_config('esheep.test.same_device_first_command', gen_random_uuid()::text, false);
select set_config('esheep.test.same_device_newer_command', gen_random_uuid()::text, false);
select set_config('esheep.test.same_device_older_command', gen_random_uuid()::text, false);
select set_config('esheep.test.negative_observation_command', gen_random_uuid()::text, false);
select set_config('esheep.test.interleaved_a_new_command', gen_random_uuid()::text, false);
select set_config('esheep.test.interleaved_b_command', gen_random_uuid()::text, false);
select set_config('esheep.test.interleaved_a_old_command', gen_random_uuid()::text, false);
select set_config(
  'esheep.test.null_digest',
  esheep_cloud.value_digest('{"type":"null"}'::jsonb),
  false
);
select set_config(
  'esheep.test.device_a_value_digest',
  esheep_cloud.value_digest('{"type":"string","value":"设备A较新值"}'::jsonb),
  false
);

create or replace function pg_temp.esheep_cloud_test_command(
  p_command_id uuid,
  p_source_request_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_account_id uuid,
  p_device_id uuid,
  p_device_sequence bigint,
  p_command_kind text,
  p_stream_type text,
  p_stream_id uuid,
  p_field text,
  p_observed_version bigint,
  p_base_value_digest text,
  p_desired_value jsonb,
  p_required_asset_ids uuid[] default '{}',
  p_protocol_version integer default 2,
  p_schema_version integer default 1,
  p_prerequisite_command_ids uuid[] default '{}',
  p_bundle_id uuid default null,
  p_secondary_stream_type text default null,
  p_secondary_stream_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unsigned_json jsonb;
  v_unsigned bytea;
  v_mutation jsonb;
  v_payload jsonb;
begin
  v_mutation := case
    when p_desired_value ->> 'type' = 'null'
      then jsonb_build_object('action', 'clear')
    else jsonb_build_object('action', 'set', 'value', p_desired_value)
  end;
  v_payload := case p_command_kind
    when 'sheepAvatar.set' then jsonb_build_object(
      'kind', p_command_kind,
      'body', jsonb_build_object('setAvatar', jsonb_build_object(
        'sheepID', p_stream_id,
        'photoAssetID', (p_desired_value ->> 'value')::uuid
      ))
    )
    when 'sheepAvatar.clear' then jsonb_build_object(
      'kind', p_command_kind,
      'body', jsonb_build_object('clearAvatar', jsonb_build_object(
        'sheepID', p_stream_id
      ))
    )
    when 'sheep.patchProfile' then jsonb_build_object(
      'kind', p_command_kind,
      'body', jsonb_build_object('patchProfile', jsonb_build_object(
        'sheepID', p_stream_id,
        'fields', jsonb_build_array(jsonb_build_object(
          'field', p_field,
          'mutation', v_mutation
        ))
      ))
    )
    when 'transfer.record' then jsonb_build_object(
      'kind', p_command_kind,
      'body', jsonb_build_object('transferSheep', jsonb_build_object(
        'sheepID', p_stream_id,
        'toPenID', null,
        'occurredAt', 1800000000000,
        'note', '多流原子转群'
      ))
    )
    else jsonb_build_object(
      'kind', p_command_kind,
      'body', jsonb_build_object(
        esheep_cloud.expected_payload_case_v2(p_command_kind),
        '{}'::jsonb
      )
    )
  end;
  v_unsigned_json := jsonb_build_object(
    'protocolVersion', p_protocol_version,
    'schemaVersion', p_schema_version,
    'commandID', p_command_id,
    'sourceRequestID', p_source_request_id,
    'bundleID', p_bundle_id,
    'farmID', p_farm_id,
    'farmGeneration', p_farm_generation,
    'accountID', p_account_id,
    'deviceID', p_device_id,
    'deviceSequence', p_device_sequence,
    'createdAt', 1800000000000,
    'occurredAt', 1800000000000,
    'commandKind', p_command_kind,
    'payload', v_payload,
    'affectedStreams', jsonb_build_array(jsonb_build_object(
      'type', p_stream_type,
      'id', p_stream_id
    )) || case
      when p_secondary_stream_type is null or p_secondary_stream_id is null
        then '[]'::jsonb
      else jsonb_build_array(jsonb_build_object(
        'type', p_secondary_stream_type,
        'id', p_secondary_stream_id
      ))
    end,
    'affectedFields', case when p_field = '' then '[]'::jsonb else
      jsonb_build_array(jsonb_build_object(
        'stream', jsonb_build_object('type', p_stream_type, 'id', p_stream_id),
        'field', p_field,
        'observedVersion', p_observed_version,
        'baseValueDigest', p_base_value_digest
      )) end,
    'fieldChanges', case when p_field = '' then '[]'::jsonb else
      jsonb_build_array(jsonb_build_object(
        'field', p_field,
        'mutation', v_mutation
      )) end,
    'prerequisiteCommandIDs', to_jsonb(p_prerequisite_command_ids),
    'requiredAssetIDs', to_jsonb(p_required_asset_ids)
  );
  v_unsigned := convert_to(v_unsigned_json::text, 'utf8');
  return jsonb_build_object(
    'unsigned_command_base64', encode(v_unsigned, 'base64'),
    'content_digest', encode(extensions.digest(v_unsigned, 'sha256'), 'hex'),
    'device_signature_base64', encode(extensions.gen_random_bytes(64), 'base64')
  );
end;
$$;

-- The client cannot execute the write transaction directly. Tests enter
-- through this owner-only harness after treating the fixture signatures as
-- already verified by the Edge verifier.
create or replace function pg_temp.esheep_cloud_submit_commands_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_commands jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.esheep_cloud_submit_verified_commands_v2(
    (select auth.uid()),
    p_farm_id,
    p_farm_generation,
    p_commands
  );
$$;

create or replace function pg_temp.esheep_cloud_test_photo_registration(
  p_command_id uuid,
  p_source_request_id uuid,
  p_farm_id uuid,
  p_farm_generation integer,
  p_account_id uuid,
  p_device_id uuid,
  p_device_sequence bigint,
  p_asset_id uuid,
  p_sheep_id uuid,
  p_metadata jsonb,
  p_metadata_digest text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unsigned_json jsonb;
  v_unsigned bytea;
begin
  v_unsigned_json := jsonb_build_object(
    'protocolVersion', 2,
    'schemaVersion', 1,
    'commandID', p_command_id,
    'sourceRequestID', p_source_request_id,
    'bundleID', null,
    'farmID', p_farm_id,
    'farmGeneration', p_farm_generation,
    'accountID', p_account_id,
    'deviceID', p_device_id,
    'deviceSequence', p_device_sequence,
    'createdAt', 1800000000000,
    'occurredAt', 1800000000000,
    'commandKind', 'photoAsset.register',
    'payload', jsonb_build_object(
      'kind', 'photoAsset.register',
      'body', jsonb_build_object('register', jsonb_build_object(
        'assetID', p_asset_id,
        'sheepID', p_sheep_id,
        'capturedAt', 1800000000000,
        'mimeType', 'image/jpeg',
        'contentSHA256', repeat('a', 64),
        'metadata', p_metadata,
        'metadataDigest', p_metadata_digest,
        'thumbnailSHA256', repeat('e', 64),
        'avatarSHA256', repeat('f', 64),
        'originalSHA256', repeat('a', 64),
        'thumbnailByteCount', 11,
        'avatarByteCount', 22,
        'originalByteCount', 33
      ))
    ),
    'affectedStreams', jsonb_build_array(jsonb_build_object(
      'type', 'photoAsset', 'id', p_asset_id
    )),
    'affectedFields', '[]'::jsonb,
    'fieldChanges', '[]'::jsonb,
    'prerequisiteCommandIDs', '[]'::jsonb,
    'requiredAssetIDs', jsonb_build_array(p_asset_id)
  );
  v_unsigned := convert_to(v_unsigned_json::text, 'utf8');
  return jsonb_build_object(
    'unsigned_command_base64', encode(v_unsigned, 'base64'),
    'content_digest', encode(extensions.digest(v_unsigned, 'sha256'), 'hex'),
    'device_signature_base64', encode(extensions.gen_random_bytes(64), 'base64')
  );
end;
$$;

create or replace function pg_temp.esheep_cloud_storage_path_allowed(
  p_name text,
  p_require_recycle_expired boolean,
  p_require_writable_upload boolean
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select esheep_cloud.storage_path_is_authorized(
    p_name,
    p_require_recycle_expired,
    p_require_writable_upload
  );
$$;

create or replace function pg_temp.esheep_cloud_resolve_attention_v2(
  p_farm_id uuid,
  p_farm_generation integer,
  p_attention_id uuid,
  p_resolution_command_id uuid,
  p_choice text,
  p_expected_cloud_value_digest text,
  p_account_id uuid,
  p_device_id uuid,
  p_device_sequence bigint,
  p_signature_byte_count integer default 64
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.esheep_cloud_resolve_verified_attention_v2(
    (select auth.uid()),
    p_farm_id,
    p_farm_generation,
    p_attention_id,
    p_resolution_command_id,
    p_choice,
    p_expected_cloud_value_digest,
    p_account_id,
    p_device_id,
    p_device_sequence,
    encode(extensions.gen_random_bytes(p_signature_byte_count), 'base64')
  );
$$;

select ok(
  not has_schema_privilege('authenticated', 'esheep_cloud', 'USAGE'),
  'client roles cannot resolve the private eSheep Cloud schema'
);

select ok(
  not has_table_privilege('authenticated', 'esheep_cloud.commands', 'SELECT'),
  'client roles cannot read the private command ledger directly'
);

select ok(
  not has_table_privilege('authenticated', 'esheep_cloud.farm_profiles', 'SELECT'),
  'client roles cannot read immutable farm identity rows directly'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.esheep_cloud_submit_verified_commands_v2(uuid,uuid,integer,jsonb)',
    'EXECUTE'
  ),
  'authenticated clients cannot bypass the device-signature verifier'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.esheep_cloud_submit_verified_commands_v2(uuid,uuid,integer,jsonb)',
    'EXECUTE'
  ),
  'only the server verifier can enter the V2 write transaction'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.esheep_cloud_resolve_verified_attention_v2(uuid,uuid,integer,uuid,uuid,text,text,uuid,uuid,bigint,text)',
    'EXECUTE'
  ),
  'authenticated clients cannot bypass verification when resolving an attention item'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.esheep_cloud_resolve_verified_attention_v2(uuid,uuid,integer,uuid,uuid,text,text,uuid,uuid,bigint,text)',
    'EXECUTE'
  ),
  'only the server verifier can enter the attention-resolution transaction'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.esheep_cloud_asset_verification_target_v2(uuid,uuid,integer,uuid,text)',
    'EXECUTE'
  ),
  'authenticated clients cannot select their own asset-verification target'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.esheep_cloud_confirm_verified_asset_v2(uuid,uuid,integer,uuid,text,text,bigint)',
    'EXECUTE'
  ),
  'authenticated clients cannot mark their own uploaded bytes as verified'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.esheep_cloud_asset_verification_target_v2(uuid,uuid,integer,uuid,text)',
    'EXECUTE'
  ),
  'the trusted server verifier can resolve an immutable object target'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.esheep_cloud_confirm_verified_asset_v2(uuid,uuid,integer,uuid,text,text,bigint)',
    'EXECUTE'
  ),
  'the trusted server verifier can record a byte-verified asset result'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'esheep_cloud.protocol_readiness_report_v2()',
    'EXECUTE'
  ),
  'clients cannot inspect the private release-readiness inventory'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'esheep_cloud.audit_farm_integrity_v2(uuid,integer)',
    'EXECUTE'
  ),
  'clients cannot invoke or forge a private cloud-integrity audit'
);

select ok(
  has_function_privilege(
    'service_role',
    'esheep_cloud.audit_farm_integrity_v2(uuid,integer)',
    'EXECUTE'
  ),
  'the trusted maintenance service can persist a cloud-integrity hold'
);

select is(
  esheep_cloud.protocol_readiness_report_v2() ->> 'ready',
  'true',
  'the migration gate opens only when every declared command has a transaction and projection route'
);

select has_column(
  'esheep_cloud',
  'migration_reconciliations',
  'parity_digest',
  'migration reconciliation stores the report digest separately from both manifests'
);

select has_column(
  'esheep_cloud',
  'command_catalog',
  'client_projection_schema_version',
  'release readiness tracks deterministic client projection separately from server handling'
);

select is(
  (esheep_cloud.protocol_readiness_report_v2() ->> 'implemented_command_count')::integer,
  80,
  'the readiness report accounts for all 80 declared commands'
);

select is(
  (esheep_cloud.protocol_readiness_report_v2() ->> 'server_implemented_command_count')::integer,
  80,
  'server readiness is computed from the executable dispatcher, not a catalogue flag'
);

select is(
  (esheep_cloud.protocol_readiness_report_v2() ->> 'client_projected_command_count')::integer,
  80,
  'client readiness is computed from the explicit projection route inventory'
);

select is(
  (esheep_cloud.protocol_readiness_report_v2() ->> 'manual_catalog_markers')::integer,
  0,
  'no command is marked ready by a manual catalogue version update'
);

select is(
  (
    select count(*)::integer
    from esheep_cloud.command_catalog catalog
    where catalog.handler_schema_version is not null
       or catalog.client_projection_schema_version is not null
  ),
  0,
  'legacy readiness columns remain empty and cannot be used as implementation proof'
);

select lives_ok(
  $$select esheep_cloud.assert_protocol_ready_v2()$$,
  'the protocol completeness assertion passes at the 80/80 gate'
);

select is(
  (
    select count(*)::integer
    from pg_catalog.pg_class table_class
    join pg_catalog.pg_namespace namespace
      on namespace.oid = table_class.relnamespace
    where namespace.nspname = 'esheep_cloud'
      and table_class.relkind = 'r'
      and table_class.relrowsecurity
  ),
  12,
  'every V2 private table has row-level security enabled as defense in depth'
);

select is(
  esheep_cloud.value_digest('{"type":"null"}'::jsonb),
  '74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b',
  'the SQL null field digest matches the cross-platform canonical value digest'
);

select is(
  esheep_cloud.value_digest(
    '{"type":"identifier","value":"00000000-0000-0000-0000-000000000001"}'::jsonb
  ),
  '5d57c8344d8aa46ae848cdf160443345a6d4d087c3fdf30aabce335c7780133f',
  'the SQL identifier field digest matches the cross-platform canonical value digest'
);

select is(
  esheep_cloud.canonical_json_text(
    '{"lastCommandKind":"weight.record","eventCount":1,"lastCommandID":"00000000-0000-0000-0000-000000000001","lastCommandDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'::jsonb
  ),
  '{"eventCount":1,"lastCommandDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lastCommandID":"00000000-0000-0000-0000-000000000001","lastCommandKind":"weight.record"}',
  'canonical JSON uses the same sorted compact representation as the client codec'
);

select is(
  esheep_cloud.json_digest(
    '{"lastCommandKind":"weight.record","eventCount":1,"lastCommandID":"00000000-0000-0000-0000-000000000001","lastCommandDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'::jsonb
  ),
  '6157357f48a7288875724026f7e04d3d86067926605eaebdeffb34038acfd6e7',
  'canonical stream digests match CryptoKit output byte for byte'
);

select is(
  esheep_cloud.json_digest(
    '{"command_kind":"sheepAvatar.set","changes":[]}'::jsonb
  ),
  'e48d829e9c34c3bcdd1ce4af9724b7103f27ed28ff81f6d857409bf712a2e217',
  'canonical event-body bytes have a cross-platform golden digest'
);

select is(
  esheep_cloud.event_digest(
    '11111111-1111-1111-1111-111111111111'::uuid,
    7,
    42,
    '22222222-2222-2222-2222-222222222222'::uuid,
    '33333333-3333-3333-3333-333333333333'::uuid,
    'sheepAvatar',
    '44444444-4444-4444-4444-444444444444'::uuid,
    array['zeta', 'avatar'],
    'e48d829e9c34c3bcdd1ce4af9724b7103f27ed28ff81f6d857409bf712a2e217',
    repeat('a', 64),
    repeat('b', 64),
    '55555555-5555-5555-5555-555555555555'::uuid,
    '66666666-6666-6666-6666-666666666666'::uuid,
    99,
    1800000000123,
    1800000000456,
    repeat('c', 64)
  ),
  '1d830a1ad06c9c64a87f10cc17b2faf36c469e91c083f6071ba6bdfe59c58a22',
  'the SQL receipt digest matches the client golden vector including event-body integrity'
);

select is(
  esheep_cloud.expected_payload_case_v2('sheepAvatar.set'),
  'setAvatar',
  'the server maps each public command kind to one typed payload case'
);

select throws_ok(
  $$select esheep_cloud.validate_payload_contract_v2(
    'sheepAvatar.set',
    '{"kind":"sheepAvatar.clear","body":{"clearAvatar":{"sheepID":"00000000-0000-0000-0000-000000000001"}}}'::jsonb
  )$$,
  '22023',
  'esheep_cloud_payload_kind_mismatch',
  'a command discriminator and typed body mismatch fails closed'
);

select throws_ok(
  $$select esheep_cloud.validate_command_semantics_v2(
    'sheepAvatar.set',
    '{"kind":"sheepAvatar.set","body":{"setAvatar":{"sheepID":"00000000-0000-4000-8000-000000000001","photoAssetID":"00000000-0000-4000-8000-000000000002"}}}'::jsonb,
    'field_patch',
    '[{"type":"sheepAvatar","id":"00000000-0000-4000-8000-000000000001"}]'::jsonb,
    '[{"stream":{"type":"sheepAvatar","id":"00000000-0000-4000-8000-000000000001"},"field":"avatar","observedVersion":-1,"baseValueDigest":"0000000000000000000000000000000000000000000000000000000000000000"}]'::jsonb,
    '[{"field":"avatar","mutation":{"action":"set","value":{"type":"identifier","value":"00000000-0000-4000-8000-000000000002"}}}]'::jsonb
  )$$,
  '22023',
  'esheep_cloud_field_observation_contract_invalid',
  'a negative or malformed field observation fails before the command ledger'
);

select throws_ok(
  $$select esheep_cloud.validate_command_semantics_v2(
    'sheepAvatar.set',
    '{"kind":"sheepAvatar.set","body":{"setAvatar":{"sheepID":"00000000-0000-4000-8000-000000000001","photoAssetID":"00000000-0000-4000-8000-000000000002"}}}'::jsonb,
    'field_patch',
    '[{"type":"sheepAvatar","id":"00000000-0000-4000-8000-000000000001"}]'::jsonb,
    '[{"stream":{"type":"sheepAvatar","id":"00000000-0000-4000-8000-000000000001"},"field":"avatar","observedVersion":0,"baseValueDigest":"0000000000000000000000000000000000000000000000000000000000000000"}]'::jsonb,
    '[{"field":"avatar","mutation":{"action":"set","value":{"type":"unknown","value":"opaque"}}}]'::jsonb
  )$$,
  '22023',
  'esheep_cloud_field_mutation_contract_invalid',
  'an unknown field value type fails closed instead of entering the event log'
);

select throws_ok(
  $$select esheep_cloud.validate_command_semantics_v2(
    'care.healthCatalog.upsert',
    '{"kind":"care.healthCatalog.upsert","body":{"upsertHealthCatalog":{"id":"00000000-0000-4000-8000-000000000003","kindRawValue":"treatment","name":"消毒剂","category":"药品","unit":"毫升","isActive":true}}}'::jsonb,
    'state_machine',
    '[{"type":"sheep","id":"00000000-0000-4000-8000-000000000001"}]'::jsonb,
    '[]'::jsonb,
    '[]'::jsonb
  )$$,
  '22023',
  'esheep_cloud_stream_kind_invalid',
  'care commands must bind their primary stream to the result entity type'
);

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at
)
values
  (
    current_setting('esheep.test.user_a')::uuid,
    'authenticated', 'authenticated', 'esheep-cloud-v2-a@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.test.user_b')::uuid,
    'authenticated', 'authenticated', 'esheep-cloud-v2-b@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.test.user_c')::uuid,
    'authenticated', 'authenticated', 'esheep-cloud-v2-c@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  );

update public.profiles
set app_account_id = case user_id
  when current_setting('esheep.test.user_a')::uuid
    then current_setting('esheep.test.account_a')::uuid
  when current_setting('esheep.test.user_b')::uuid
    then current_setting('esheep.test.account_b')::uuid
  when current_setting('esheep.test.user_c')::uuid
    then current_setting('esheep.test.account_c')::uuid
  else app_account_id
end
where user_id in (
  current_setting('esheep.test.user_a')::uuid,
  current_setting('esheep.test.user_b')::uuid,
  current_setting('esheep.test.user_c')::uuid
);

insert into public.entitlements (
  owner_user_id, product_id, state, valid_until
)
values (
  current_setting('esheep.test.user_a')::uuid,
  'com.sheepfarm.ios.pro.monthly',
  'active',
  now() + interval '30 days'
);

insert into public.farm_registry (
  farm_id, owner_user_id, provider, status, authority_generation, current_revision
)
values (
  current_setting('esheep.test.farm')::uuid,
  current_setting('esheep.test.user_a')::uuid,
  'esheep_cloud',
  'active',
  2,
  0
);

insert into public.farm_members (
  farm_id, user_id, app_account_id, role, status
)
values
  (
    current_setting('esheep.test.farm')::uuid,
    current_setting('esheep.test.user_a')::uuid,
    current_setting('esheep.test.account_a')::uuid,
    'owner',
    'active'
  ),
  (
    current_setting('esheep.test.farm')::uuid,
    current_setting('esheep.test.user_b')::uuid,
    current_setting('esheep.test.account_b')::uuid,
    'worker',
    'active'
  );

insert into public.devices (
  device_id, user_id, public_key_jwk, display_name, status
)
values
  (
    current_setting('esheep.test.device_a')::uuid,
    current_setting('esheep.test.user_a')::uuid,
    '{"kty":"EC","crv":"P-256"}'::jsonb,
    'iPhone Air',
    'active'
  ),
  (
    current_setting('esheep.test.device_b')::uuid,
    current_setting('esheep.test.user_b')::uuid,
    '{"kty":"EC","crv":"P-256"}'::jsonb,
    'Second device',
    'active'
  );

insert into esheep_cloud.farm_state (
  farm_id, farm_generation, status, v2_ready, projection_digest,
  last_integrity_check_at
)
values (
  current_setting('esheep.test.farm')::uuid,
  2,
  'active',
  true,
  repeat('0', 64),
  now()
);

select throws_ok(
  format(
    $$select esheep_cloud.mark_migration_ready_v2(
      %L::uuid, 1, 3, repeat('a', 64), repeat('a', 64),
      '{"all_checks_passed":true}'::jsonb, repeat('b', 64), repeat('c', 64)
    )$$,
    current_setting('esheep.test.farm')
  ),
  '22023',
  'esheep_cloud_migration_generation_invalid',
  'a migration cannot skip a generation even when all supplied digests look valid'
);

select lives_ok(
  $$select esheep_cloud.mark_migration_ready_v2(
    current_setting('esheep.test.farm')::uuid, 1, 2, repeat('a', 64), repeat('a', 64),
    '{"all_checks_passed":true}'::jsonb, repeat('b', 64), repeat('c', 64)
  )$$,
  'a parity mismatch is recorded as a migration result after the protocol gate passes'
);

select set_config(
  'esheep.test.farm_profile_digest',
  esheep_cloud.upsert_farm_profile_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.account_a')::uuid,
    'V2 测试牧场',
    '2026-09-02 00:00:00+00'::timestamptz,
    '2026-09-02 00:00:00+00'::timestamptz,
    '测试地点', 39.9, 116.4, null, 'Asia/Shanghai',
    'legacyMigration', 10, '2026-09-02 00:00:00+00'::timestamptz
  ),
  false
);

select ok(
  current_setting('esheep.test.farm_profile_digest') ~ '^[0-9a-f]{64}$',
  'the migration worker stores a canonical generation-bound farm profile'
);

insert into esheep_cloud.assets (
  asset_id, farm_id, farm_generation, sheep_id, content_sha256,
  thumbnail_sha256, avatar_sha256, original_sha256,
  metadata, metadata_digest, thumbnail_path, avatar_path, original_path,
  thumbnail_state, avatar_state, original_state,
  thumbnail_byte_count, avatar_byte_count, original_byte_count,
  uploaded_by, verified_at
)
values
  (
    current_setting('esheep.test.asset_a')::uuid,
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.sheep')::uuid,
    repeat('a', 64),
    repeat('e', 64), repeat('f', 64), repeat('a', 64),
    '{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb,
    esheep_cloud.json_digest('{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb),
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_a')) || '/' || repeat('e', 64) || '/thumbnail.jpg',
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_a')) || '/' || repeat('f', 64) || '/avatar.jpg',
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_a')) || '/' || repeat('a', 64) || '/original.bin',
    'verified', 'verified', 'verified',
    11, 22, 33,
    current_setting('esheep.test.user_a')::uuid,
    now()
  ),
  (
    current_setting('esheep.test.asset_b')::uuid,
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.sheep')::uuid,
    repeat('c', 64),
    repeat('2', 64), repeat('3', 64), repeat('c', 64),
    '{"mimeType":"image/jpeg","sourceSHA256":"4444444444444444444444444444444444444444444444444444444444444444","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200"}'::jsonb,
    esheep_cloud.json_digest('{"mimeType":"image/jpeg","sourceSHA256":"4444444444444444444444444444444444444444444444444444444444444444","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200"}'::jsonb),
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_b')) || '/' || repeat('2', 64) || '/thumbnail.jpg',
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_b')) || '/' || repeat('3', 64) || '/avatar.jpg',
    lower(current_setting('esheep.test.farm')) || '/2/' || lower(current_setting('esheep.test.asset_b')) || '/' || repeat('c', 64) || '/original.bin',
    'verified', 'verified', 'verified',
    44, 55, 66,
    current_setting('esheep.test.user_b')::uuid,
    now()
  );

select set_config(
  'esheep.test.asset_a_metadata_digest',
  esheep_cloud.json_digest('{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb),
  false
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.unimplemented_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.unimplemented_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      100,
      'weight.record', 'weightFact', gen_random_uuid(),
      'value', 0, current_setting('esheep.test.null_digest'),
      '{"type":"decimal","value":"42.5"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.unimplemented_result')::jsonb #>> '{results,0,reason,code}',
  'malformed_command',
  'a semantically malformed command fails closed before any business transaction'
);

select is(
  current_setting('esheep.test.unimplemented_result')::jsonb #>> '{results,0,command_id}',
  current_setting('esheep.test.unimplemented_command'),
  'a malformed-command rejection still identifies the original command'
);

reset role;
select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.unimplemented_command')::uuid
  ),
  0,
  'a malformed command cannot manufacture a durable success result'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.missing_asset_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.missing_asset_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      101,
      'sheepAvatar.set', 'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar', 0, current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.missing_asset')),
      array[current_setting('esheep.test.missing_asset')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.missing_asset_result')::jsonb #>> '{results,0,reason,asset_id}',
  current_setting('esheep.test.missing_asset'),
  'a temporary asset rejection identifies the exact blocking asset'
);

reset role;
select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.missing_asset_command')::uuid
  ),
  0,
  'an asset-waiting command stays immutable outside the accepted command ledger'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.blocked_prerequisite_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.blocked_prerequisite_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      102,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"wait"}'::jsonb,
      '{}', 2, 1,
      array[current_setting('esheep.test.missing_prerequisite')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.blocked_prerequisite_result')::jsonb #>> '{results,0,reason,command_id}',
  current_setting('esheep.test.missing_prerequisite'),
  'a dependency rejection identifies the exact prerequisite command'
);

reset role;
select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.blocked_prerequisite_command')::uuid
  ),
  0,
  'a dependency-waiting command cannot run ahead or enter the accepted ledger'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.avatar_a_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.avatar_a_command')::uuid,
      current_setting('esheep.test.avatar_a_request')::uuid,
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      1,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      0,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_a')),
      array[current_setting('esheep.test.asset_a')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.avatar_a_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'the first avatar field command is accepted'
);

-- Submit the cross-account dependency as the account-B member.  The command
-- must reach the dependency gate (rather than being rejected first because
-- the JWT user does not own device B), so the assertion exercises the
-- account boundary itself.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.cross_account_dependency_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.cross_account_dependency_command')::uuid,
      gen_random_uuid(),
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_b')::uuid,
      current_setting('esheep.test.device_b')::uuid,
      5,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      0,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_b')),
      array[current_setting('esheep.test.asset_b')::uuid],
      2, 1,
      array[current_setting('esheep.test.avatar_a_command')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.cross_account_dependency_result')::jsonb #>> '{results,0,reason,code}',
  'prerequisite_not_ready',
  'a command cannot depend on an accepted command from another account'
);

select is(
  current_setting('esheep.test.cross_account_dependency_result')::jsonb #>> '{results,0,reason,command_id}',
  current_setting('esheep.test.avatar_a_command'),
  'a cross-account dependency rejection identifies the exact prerequisite'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

reset role;
select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.cross_account_dependency_command')::uuid
  ),
  0,
  'a cross-account dependency cannot enter the durable command ledger'
);

reset role;
select is(
  (select count(*)::integer from esheep_cloud.commands),
  1,
  'an accepted command is recorded exactly once'
);

select is(
  (select count(*)::integer from esheep_cloud.events),
  1,
  'an accepted avatar command produces exactly one event'
);

select is(
  (select event_head::integer from esheep_cloud.farm_state where farm_id = current_setting('esheep.test.farm')::uuid),
  1,
  'the authoritative event head advances with the accepted event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.negative_observation_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.negative_observation_command')::uuid,
      gen_random_uuid(),
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      2,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      -1,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_a')),
      array[current_setting('esheep.test.asset_a')::uuid]
    ))
  )::text,
  false
);

reset role;
select ok(
  current_setting('esheep.test.negative_observation_result')::jsonb
    #>> '{results,0,reason,code}' = 'malformed_command'
  and not exists (
    select 1 from esheep_cloud.commands
    where command_id = current_setting('esheep.test.negative_observation_command')::uuid
  )
  and (select count(*) from esheep_cloud.events) = 1,
  'a negative observed field version fails closed without a command receipt or event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.avatar_duplicate_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.avatar_a_command')::uuid,
      current_setting('esheep.test.avatar_a_request')::uuid,
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      1,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      0,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_a')),
      array[current_setting('esheep.test.asset_a')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.avatar_duplicate_result')::jsonb #>> '{results,0,type}',
  'duplicate',
  'an identical command can be retried without a second business result'
);

select set_config(
  'esheep.test.source_request_reuse_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.source_request_reuse_command')::uuid,
      current_setting('esheep.test.avatar_a_request')::uuid,
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      103,
      'sheep.patchProfile',
      'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note',
      0,
      current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"source request must remain unique"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.source_request_reuse_result')::jsonb #>> '{results,0,reason,code}',
  'source_request_reused',
  'a different command cannot reuse an existing source request ID'
);

reset role;
select is(
  (select count(*)::integer
   from esheep_cloud.commands
   where command_id = current_setting('esheep.test.source_request_reuse_command')::uuid),
  0,
  'a reused source request ID does not enter the durable command ledger'
);

reset role;
select is(
  (select count(*)::integer from esheep_cloud.events),
  1,
  'the duplicate retry does not append another event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.avatar_mismatch_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.avatar_a_command')::uuid,
      gen_random_uuid(),
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      2,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      0,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_b')),
      array[current_setting('esheep.test.asset_b')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.avatar_mismatch_result')::jsonb #>> '{results,0,reason,code}',
  'command_id_digest_mismatch',
  'the same command ID with different content fails closed'
);

reset role;
select is(
  (select count(*)::integer from esheep_cloud.events),
  1,
  'a command ID digest mismatch cannot create a business event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.avatar_b_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.avatar_b_command')::uuid,
      gen_random_uuid(),
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_b')::uuid,
      current_setting('esheep.test.device_b')::uuid,
      1,
      'sheepAvatar.set',
      'sheepAvatar',
      current_setting('esheep.test.sheep')::uuid,
      'avatar',
      0,
      current_setting('esheep.test.null_digest'),
      jsonb_build_object('type', 'identifier', 'value', current_setting('esheep.test.asset_b')),
      array[current_setting('esheep.test.asset_b')::uuid]
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.avatar_b_result')::jsonb #>> '{results,0,type}',
  'needs_confirmation',
  'two devices choosing different avatars produce a visible confirmation item'
);

reset role;
select is(
  (
    select count(*)::integer
    from esheep_cloud.attention_items
    where status = 'open' and field_key = 'avatar'
  ),
  1,
  'the real same-field conflict produces exactly one persistent attention item'
);

select is(
  (
    select cloud_value ->> 'value'
    from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.avatar_b_command')::uuid
  ),
  current_setting('esheep.test.asset_a'),
  'the attention item preserves the eSheep Cloud avatar value'
);

select is(
  (
    select device_value ->> 'value'
    from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.avatar_b_command')::uuid
  ),
  current_setting('esheep.test.asset_b'),
  'the attention item preserves the second device avatar value'
);

select is(
  (select count(*)::integer from esheep_cloud.events),
  1,
  'a fully conflicting avatar command does not overwrite the accepted avatar'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.profile_ear_tag_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.profile_ear_tag_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      3,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'earTag', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"DH054"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.profile_ear_tag_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'the first scalar profile field is accepted'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.profile_breed_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.profile_breed_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_b')::uuid,
      current_setting('esheep.test.device_b')::uuid,
      2,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'breed', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"湖羊"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.profile_breed_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a different field from a stale device view merges automatically'
);

reset role;
select is(
  (
    select count(*)::integer
    from esheep_cloud.attention_items
    where status = 'open'
  ),
  1,
  'the different-field merge creates no extra attention item'
);

select is(
  (
    select canonical_state #>> '{earTag,value}'
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  'DH054',
  'the merged profile retains the first field'
);

select is(
  (
    select canonical_state #>> '{breed,value}'
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  '湖羊',
  'the merged profile also contains the independently changed field'
);

select is(
  (select count(*)::integer from esheep_cloud.events),
  3,
  'the avatar and two independent profile edits each produce one event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.profile_converge_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.profile_converge_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_b')::uuid,
      current_setting('esheep.test.device_b')::uuid,
      3,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'earTag', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"DH054"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.profile_converge_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'the same desired value converges even from a stale field observation'
);

reset role;
select is(
  (select count(*)::integer from esheep_cloud.events),
  3,
  'same-value convergence does not manufacture a duplicate event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.unknown_schema_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.unknown_schema_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      4,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"future"}'::jsonb,
      '{}', 2, 99
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.unknown_schema_result')::jsonb #>> '{results,0,reason,code}',
  'application_update_required',
  'an unknown schema version fails closed with an actionable result'
);

reset role;
select is(
  (
    select count(*)::integer
    from esheep_cloud.commands
    where command_id = current_setting('esheep.test.unknown_schema_command')::uuid
  ),
  0,
  'an unknown schema cannot enter the durable command ledger'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.sequence_reuse_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.sequence_reuse_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      3,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"must not apply"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.sequence_reuse_result')::jsonb #>> '{results,0,reason,code}',
  'malformed_command',
  'a reused device sequence is rejected instead of being processed twice'
);

select is(
  jsonb_array_length(
    public.esheep_cloud_query_command_status_v2(
      current_setting('esheep.test.farm')::uuid,
      array[current_setting('esheep.test.avatar_a_command')::uuid]
    ) -> 'results'
  ),
  1,
  'an active member can query the durable result for an accepted command ID'
);

select is(
  jsonb_array_length(
    public.esheep_cloud_query_command_status_v2(
      current_setting('esheep.test.farm')::uuid,
      array[gen_random_uuid()]
    ) -> 'results'
  ),
  0,
  'an empty command-status result is authoritative only after membership succeeds'
);

select set_config(
  'esheep.test.bundle_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.bundle_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      10,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"must remain atomic"}'::jsonb,
      '{}', 2, 1, '{}', gen_random_uuid()
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.bundle_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a valid atomic bundle is committed as one durable business result'
);

reset role;
select is(
  (
    select count(*)::integer
    from esheep_cloud.commands
    where command_id = current_setting('esheep.test.sequence_reuse_command')::uuid
  ),
  0,
  'a reused device sequence cannot create a ledger row'
);

select is(
  (
    select count(*)::integer
    from esheep_cloud.commands
    where command_id = current_setting('esheep.test.bundle_command')::uuid
  ),
  1,
  'an accepted atomic bundle leaves exactly one command ledger row'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_c'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  format(
    $$select public.esheep_cloud_pull_events_v2(%L::uuid, 2, 0, 100)$$,
    current_setting('esheep.test.farm')
  ),
  '42501',
  'esheep_cloud_farm_read_denied',
  'a non-member cannot pull another farm event stream'
);

select throws_ok(
  format(
    $$select public.esheep_cloud_query_command_status_v2(%L::uuid, array[%L::uuid])$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.avatar_a_command')
  ),
  '42501',
  'esheep_cloud_farm_read_denied',
  'a non-member gets an explicit access failure instead of an ambiguous empty status'
);

reset role;
select ok(
  (
    esheep_cloud.farm_integrity_report_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) ->> 'passed'
  )::boolean,
  'the independent ledger audit recomputes a healthy event and projection chain'
);

select set_config(
  'esheep.test.pre_snapshot_integrity_report',
  esheep_cloud.audit_farm_integrity_v2(
    current_setting('esheep.test.farm')::uuid,
    2
  )::text,
  false
);

select ok(
  (
    current_setting('esheep.test.pre_snapshot_integrity_report')::jsonb
      ->> 'passed'
  )::boolean
  and (
    select last_integrity_check_at is not null
      and (last_integrity_report ->> 'passed')::boolean
    from esheep_cloud.farm_state
    where farm_id = current_setting('esheep.test.farm')::uuid
  ),
  'a passing audit records its evidence before a snapshot is built'
);

select set_config(
  'esheep.test.snapshot',
  esheep_cloud.build_snapshot_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    100
  )::text,
  false
);

select is(
  (
    select status
    from esheep_cloud.snapshots
    where snapshot_id = current_setting('esheep.test.snapshot')::uuid
  ),
  'verified',
  'the service creates an immutable verified initial-sync snapshot'
);

select is(
  (
    select (manifest #>> '{record_counts,events}')::integer
    from esheep_cloud.snapshots
    where snapshot_id = current_setting('esheep.test.snapshot')::uuid
  ),
  4,
  'the snapshot manifest is bound to the complete event boundary'
);

select ok(
  (
    select bool_and(
      content_sha256 = encode(extensions.digest(content_data, 'sha256'), 'hex')
      and byte_count = octet_length(content_data)
    )
    from esheep_cloud.snapshot_chunks
    where snapshot_id = current_setting('esheep.test.snapshot')::uuid
  ),
  'every snapshot chunk carries a verifiable content digest and byte count'
);

select ok(
  (
    select farm_profile_digest = encode(extensions.digest(farm_profile_data, 'sha256'), 'hex')
      and total_digest = encode(extensions.digest(convert_to(
        farm_profile_digest || coalesce((
          select string_agg(chunk.content_sha256, '' order by chunk.chunk_index)
          from esheep_cloud.snapshot_chunks chunk
          where chunk.snapshot_id = snapshot.snapshot_id
        ), ''),
        'utf8'
      ), 'sha256'), 'hex')
    from esheep_cloud.snapshots snapshot
    where snapshot.snapshot_id = current_setting('esheep.test.snapshot')::uuid
  ),
  'the immutable farm profile and every chunk are bound by the snapshot digest'
);

-- Cut-over must never be callable against an already V2-authoritative farm,
-- even if a caller forges otherwise-plausible migration rows. The fixture is
-- temporarily shaped like a ready migration so this assertion exercises the
-- provider/source-generation guard rather than the earlier parity checks.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
reset role;
update public.farm_registry
set provider = 'esheep_cloud', authority_generation = 1
where farm_id = current_setting('esheep.test.farm')::uuid;
update esheep_cloud.farm_state
set farm_generation = 2, status = 'preparing', v2_ready = true,
    latest_snapshot_id = current_setting('esheep.test.snapshot')::uuid
where farm_id = current_setting('esheep.test.farm')::uuid;
update esheep_cloud.migration_reconciliations
set source_generation = 1, target_generation = 2, status = 'v2_ready',
    source_manifest_digest = repeat('a', 64),
    target_manifest_digest = repeat('a', 64),
    parity_report = '{"all_checks_passed":true}'::jsonb,
    parity_digest = esheep_cloud.json_digest('{"all_checks_passed":true}'::jsonb)
where farm_id = current_setting('esheep.test.farm')::uuid;
select set_config(
  'esheep.test.cutover_parity_digest',
  esheep_cloud.json_digest('{"all_checks_passed":true}'::jsonb),
  false
);
set local role authenticated;

select throws_ok(
  format(
    $$select public.esheep_cloud_cut_over_farm_v2(%L::uuid, 1, %L)$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.cutover_parity_digest')
  ),
  '40001',
  'esheep_cloud_cutover_precondition_failed',
  'cut-over rejects a farm whose current authority is already eSheep Cloud'
);

-- A migration cannot be cut over merely because the ledger says it is ready;
-- the verified immutable snapshot is a separate mandatory activation proof.
set role postgres;
update public.farm_registry
set provider = 'supabase'
where farm_id = current_setting('esheep.test.farm')::uuid;
update esheep_cloud.farm_state
set latest_snapshot_id = null
where farm_id = current_setting('esheep.test.farm')::uuid;
set local role authenticated;
select throws_ok(
  format(
    $$select public.esheep_cloud_cut_over_farm_v2(%L::uuid, 1, %L)$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.cutover_parity_digest')
  ),
  '40001',
  'esheep_cloud_cutover_precondition_failed',
  'cut-over rejects a migration without a verified initial-sync snapshot'
);
set role postgres;
update esheep_cloud.farm_state
set latest_snapshot_id = current_setting('esheep.test.snapshot')::uuid,
    status = 'active'
where farm_id = current_setting('esheep.test.farm')::uuid;
update public.farm_registry
set provider = 'esheep_cloud', authority_generation = 2
where farm_id = current_setting('esheep.test.farm')::uuid;

select is(
  (
    select array_agg((record.value ->> 'event_sequence')::bigint order by chunk.chunk_index, record.ordinality)
    from esheep_cloud.snapshot_chunks chunk
    cross join lateral jsonb_array_elements(
      convert_from(chunk.content_data, 'utf8')::jsonb
    ) with ordinality as record(value, ordinality)
    where chunk.snapshot_id = current_setting('esheep.test.snapshot')::uuid
      and record.value ->> 'record_kind' = 'event'
  ),
  array[1::bigint, 2::bigint, 3::bigint, 4::bigint],
  'snapshot chunks preserve authoritative event-sequence replay order'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  public.esheep_cloud_open_initial_sync_v2(
    current_setting('esheep.test.farm')::uuid,
    2
  ) ->> 'snapshot_id',
  current_setting('esheep.test.snapshot'),
  'an active farm member receives the verified server snapshot, not a client baseline'
);

select ok(
  (
    with ticket as (
      select public.esheep_cloud_open_initial_sync_v2(
        current_setting('esheep.test.farm')::uuid,
        2
      ) as value
    )
    select value ->> 'member_role' = 'worker'
      and value ->> 'membership_status' = 'active'
      and (value ->> 'member_account_id')::uuid =
        current_setting('esheep.test.account_b')::uuid
      and encode(extensions.digest(
        decode(value ->> 'farm_profile_base64', 'base64'),
        'sha256'
      ), 'hex') = value #>> '{manifest,farm_profile_digest}'
    from ticket
  ),
  'initial sync binds the snapshot farm identity while rechecking the current member role'
);

select ok(
  (
    with access as (
      select public.esheep_cloud_list_my_farms_v2() #> '{farms,0}' as value
    )
    select value ->> 'farm_id' = current_setting('esheep.test.farm')
      and value ->> 'member_account_id' = current_setting('esheep.test.account_b')
      and value ->> 'role' = 'worker'
      and (value ->> 'initial_sync_ready')::boolean
    from access
  ),
  'farm discovery is account-bound and advertises only a verified initial snapshot'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.invite',
  public.esheep_cloud_create_invite_v2(
    current_setting('esheep.test.farm')::uuid,
    'worker'
  )::text,
  false
);

select ok(
  current_setting('esheep.test.invite')::jsonb ->> 'code' ~ '^[A-Za-z0-9_-]{43}$',
  'eSheep Cloud creates a one-time 256-bit invitation without storing the secret'
);

select is(
  jsonb_array_length(
    public.esheep_cloud_list_members_v2(
      current_setting('esheep.test.farm')::uuid
    ) -> 'members'
  ),
  2,
  'an active member can list the current farm members through the V2 RPC'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_c'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  jsonb_array_length(public.esheep_cloud_list_my_farms_v2() -> 'farms'),
  0,
  'an account cannot discover a farm before accepting its invitation'
);

select set_config(
  'esheep.test.invite_redemption',
  public.esheep_cloud_redeem_invite_v2(
    current_setting('esheep.test.invite')::jsonb ->> 'code'
  )::text,
  false
);

select is(
  current_setting('esheep.test.invite_redemption')::jsonb ->> 'role',
  'worker',
  'the V2 invitation is redeemed exactly once into its authorized role'
);

select is(
  public.esheep_cloud_open_initial_sync_v2(
    current_setting('esheep.test.farm')::uuid,
    2
  ) ->> 'member_account_id',
  current_setting('esheep.test.account_c'),
  'a newly admitted member receives an initial-sync ticket for their own account'
);

select is(
  jsonb_array_length(
    public.esheep_cloud_list_members_v2(
      current_setting('esheep.test.farm')::uuid
    ) -> 'members'
  ),
  3,
  'the admitted member becomes visible without exposing the private membership table'
);

select is(
  public.esheep_cloud_list_my_farms_v2() #>> '{farms,0,farm_id}',
  current_setting('esheep.test.farm'),
  'a redeemed farm is recoverable even if the app stops before saving local admission'
);

select throws_ok(
  format(
    $$select public.esheep_cloud_revoke_member_v2(%L::uuid, %L::uuid)$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.user_b')
  ),
  '42501',
  'esheep_cloud_owner_required',
  'a worker cannot revoke another farm member'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;
select is(
  public.esheep_cloud_revoke_member_v2(
    current_setting('esheep.test.farm')::uuid,
    current_setting('esheep.test.user_c')::uuid
  ) ->> 'status',
  'revoked',
  'the owner can revoke only the selected non-owner member'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_c'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  jsonb_array_length(public.esheep_cloud_list_my_farms_v2() -> 'farms'),
  0,
  'revocation removes the farm from the authoritative discovery list immediately'
);

reset role;
select set_config(
  'esheep.test.avatar_attention',
  (
    select attention_id::text from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.avatar_b_command')::uuid
  ),
  false
);
select set_config(
  'esheep.test.avatar_attention_cloud_digest',
  (
    select esheep_cloud.value_digest(cloud_value)
    from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.avatar_b_command')::uuid
  ),
  false
);
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  format(
    $$select pg_temp.esheep_cloud_resolve_attention_v2(
      %L::uuid, 2, %L::uuid, %L::uuid, 'use_this_device', %L,
      %L::uuid, %L::uuid, 4, 32
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.avatar_attention'),
    current_setting('esheep.test.stale_resolution_command'),
    current_setting('esheep.test.avatar_attention_cloud_digest'),
    current_setting('esheep.test.account_b'),
    current_setting('esheep.test.device_b')
  ),
  '22023',
  'esheep_cloud_device_signature_invalid',
  'the verified transaction rejects a malformed resolution signature as defense in depth'
);

select set_config(
  'esheep.test.stale_resolution_result',
  pg_temp.esheep_cloud_resolve_attention_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.avatar_attention')::uuid,
    current_setting('esheep.test.stale_resolution_command')::uuid,
    'use_this_device',
    repeat('f', 64),
    current_setting('esheep.test.account_b')::uuid,
    current_setting('esheep.test.device_b')::uuid,
    4
  )::text,
  false
);

select is(
  current_setting('esheep.test.stale_resolution_result')::jsonb #>> '{reason,code}',
  'attention_cloud_changed',
  'a decision based on an obsolete cloud value cannot overwrite newer state'
);

reset role;
select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.stale_resolution_command')::uuid
  ),
  0,
  'a failed stale decision leaves no partial command-ledger row'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.attention_resolution_result',
  pg_temp.esheep_cloud_resolve_attention_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.avatar_attention')::uuid,
    current_setting('esheep.test.attention_resolution_command')::uuid,
    'use_this_device',
    current_setting('esheep.test.avatar_attention_cloud_digest'),
    current_setting('esheep.test.account_b')::uuid,
    current_setting('esheep.test.device_b')::uuid,
    4
  )::text,
  false
);

select is(
  current_setting('esheep.test.attention_resolution_result')::jsonb ->> 'type',
  'accepted',
  'choosing this device creates one accepted resolution command'
);

reset role;
select is(
  (
    select status from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.avatar_b_command')::uuid
  ),
  'resolved',
  'the attention item closes only after the resolution transaction succeeds'
);

select is(
  (
    select canonical_state #>> '{avatar,value}'
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and stream_type = 'sheepAvatar'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  current_setting('esheep.test.asset_b'),
  'choosing this device applies the preserved device-side avatar value'
);

select is(
  (select count(*)::integer from esheep_cloud.events),
  5,
  'the accepted decision appends exactly one auditable resolution event'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.attention_resolution_duplicate',
  pg_temp.esheep_cloud_resolve_attention_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.avatar_attention')::uuid,
    current_setting('esheep.test.attention_resolution_command')::uuid,
    'use_this_device',
    current_setting('esheep.test.avatar_attention_cloud_digest'),
    current_setting('esheep.test.account_b')::uuid,
    current_setting('esheep.test.device_b')::uuid,
    4
  )::text,
  false
);

select is(
  current_setting('esheep.test.attention_resolution_duplicate')::jsonb ->> 'type',
  'duplicate',
  'retrying the same decision returns its original result'
);

select is(
  pg_temp.esheep_cloud_resolve_attention_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    current_setting('esheep.test.avatar_attention')::uuid,
    current_setting('esheep.test.attention_resolution_command')::uuid,
    'keep_cloud',
    current_setting('esheep.test.avatar_attention_cloud_digest'),
    current_setting('esheep.test.account_b')::uuid,
    current_setting('esheep.test.device_b')::uuid,
    4
  ) #>> '{reason,code}',
  'command_id_digest_mismatch',
  'the same resolution command ID can never be reused for a different choice'
);

reset role;
select is(
  (select count(*)::integer from esheep_cloud.events),
  5,
  'retrying a decision never appends a second business event'
);

select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.attention_resolution_command')::uuid
  ),
  1,
  'the resolution command is durable exactly once'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);

select ok(
  pg_temp.esheep_cloud_storage_path_allowed(
    lower(current_setting('esheep.test.farm')) || '/2/' ||
      lower(current_setting('esheep.test.asset_a')) || '/' ||
      repeat('e', 64) || '/thumbnail.jpg',
    false,
    false
  ),
  'a farm member can read the exact verified thumbnail variant path'
);

select ok(
  not pg_temp.esheep_cloud_storage_path_allowed(
    lower(current_setting('esheep.test.farm')) || '/2/' ||
      lower(current_setting('esheep.test.asset_a')) || '/' ||
      repeat('e', 64) || '/thumbnail.jpg',
    false,
    true
  ),
  'a verified immutable variant cannot be overwritten by another upload'
);

select ok(
  not pg_temp.esheep_cloud_storage_path_allowed(
    lower(current_setting('esheep.test.farm')) || '/2/' ||
      lower(current_setting('esheep.test.asset_a')) || '/' ||
      repeat('a', 64) || '/thumbnail.jpg',
    false,
    false
  ),
  'a thumbnail path cannot substitute the logical original digest for its byte digest'
);

set local role authenticated;

select ok(
  (
    public.esheep_cloud_prepare_asset_transfer_v2(
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.asset_a')::uuid,
      current_setting('esheep.test.sheep')::uuid,
      repeat('a', 64),
      repeat('e', 64),
      '{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb,
      current_setting('esheep.test.asset_a_metadata_digest'),
      'thumbnail',
      'upload',
      11
    ) ->> 'already_verified'
  )::boolean,
  'a lost client acknowledgement reuses the already verified object without reopening it'
);

select throws_ok(
  format(
    $$select public.esheep_cloud_prepare_asset_transfer_v2(
      %L::uuid, 2, %L::uuid, %L::uuid,
      %L, %L, %L::jsonb, %L, 'thumbnail', 'upload', 11
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.asset_a'),
    current_setting('esheep.test.sheep'),
    repeat('a', 64),
    repeat('e', 64),
    '{"mimeType":"image/jpeg"}',
    repeat('9', 64)
  ),
  '22023',
  'esheep_cloud_asset_digest_invalid',
  'client-supplied metadata cannot masquerade as a verified metadata digest'
);

select set_config(
  'esheep.test.photo_register_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_photo_registration(
      current_setting('esheep.test.photo_register_command')::uuid,
      current_setting('esheep.test.photo_register_request')::uuid,
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      5,
      current_setting('esheep.test.asset_a')::uuid,
      current_setting('esheep.test.sheep')::uuid,
      '{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb,
      current_setting('esheep.test.asset_a_metadata_digest')
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.photo_register_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a photo is registered only after every exact byte variant is verified'
);

reset role;
select ok(
  (
    select event_body #>> '{command_payload,body,register,thumbnailSHA256}' = repeat('e', 64)
      and event_body #>> '{command_payload,body,register,avatarSHA256}' = repeat('f', 64)
      and event_body #>> '{command_payload,body,register,originalSHA256}' = repeat('a', 64)
    from esheep_cloud.events
    where command_id = current_setting('esheep.test.photo_register_command')::uuid
  ),
  'the immutable photo event carries every variant digest needed by a new device'
);

select is(
  (
    select count(*)::integer from esheep_cloud.commands
    where command_id = current_setting('esheep.test.photo_register_command')::uuid
  ),
  1,
  'the photo registration enters the command ledger exactly once'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.photo_register_duplicate',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_photo_registration(
      current_setting('esheep.test.photo_register_command')::uuid,
      current_setting('esheep.test.photo_register_request')::uuid,
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      5,
      current_setting('esheep.test.asset_a')::uuid,
      current_setting('esheep.test.sheep')::uuid,
      '{"mimeType":"image/jpeg","sourceSHA256":"1111111111111111111111111111111111111111111111111111111111111111","sourcePixelWidth":"2000","sourcePixelHeight":"1500","cloudPixelWidth":"1600","cloudPixelHeight":"1200","capturedAtMillis":"1800000000000"}'::jsonb,
      current_setting('esheep.test.asset_a_metadata_digest')
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.photo_register_duplicate')::jsonb #>> '{results,0,type}',
  'duplicate',
  'an interrupted photo registration retry returns its original result'
);

reset role;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.same_device_first_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.same_device_first_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      20,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"同设备第一版"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.same_device_first_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'the first field command in one device sequence is accepted'
);

select set_config(
  'esheep.test.same_device_newer_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.same_device_newer_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      22,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"同设备最终版"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.same_device_newer_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a causally newer same-device field command converges despite a delayed acknowledgement'
);

reset role;

select is(
  (
    select canonical_state #>> '{note,value}'
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and farm_generation = 2
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  '同设备最终版',
  'the newer same-device value becomes canonical without user confirmation'
);

select is(
  (
    select (field_versions #>> '{note,device_sequence}')::bigint
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and farm_generation = 2
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  22::bigint,
  'the field ledger retains the causal device sequence'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.same_device_older_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.same_device_older_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      21,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"迟到旧值"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.same_device_older_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a delayed older command from the same device is a terminal no-op'
);

reset role;

select is(
  (
    select status
    from esheep_cloud.commands
    where command_id = current_setting('esheep.test.same_device_older_command')::uuid
  ),
  'accepted',
  'the superseded command is durable and will not retry forever'
);

select is(
  (
    select count(*)::integer
    from esheep_cloud.events
    where command_id = current_setting('esheep.test.same_device_older_command')::uuid
  ),
  0,
  'the delayed older command cannot overwrite state or append an event'
);

select is(
  (
    select count(*)::integer
    from esheep_cloud.attention_items
    where command_id in (
      current_setting('esheep.test.same_device_first_command')::uuid,
      current_setting('esheep.test.same_device_newer_command')::uuid,
      current_setting('esheep.test.same_device_older_command')::uuid
    )
  ),
  0,
  'one device causally editing one field never manufactures a confirmation item'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.interleaved_a_new_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.interleaved_a_new_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      30,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"设备A较新值"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.interleaved_a_new_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'device A advances its own per-field causal watermark'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.interleaved_b_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.interleaved_b_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_b')::uuid,
      current_setting('esheep.test.device_b')::uuid,
      30,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 4,
      current_setting('esheep.test.device_a_value_digest'),
      '{"type":"string","value":"设备B随后值"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.interleaved_b_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'device B can validly edit after observing device A'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.interleaved_a_old_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.interleaved_a_old_command')::uuid,
      gen_random_uuid(), current_setting('esheep.test.farm')::uuid, 2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      29,
      'sheep.patchProfile', 'sheepProfile',
      current_setting('esheep.test.sheep')::uuid,
      'note', 0, current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"设备A迟到旧值"}'::jsonb
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.interleaved_a_old_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'device A sequence 29 remains a terminal no-op after device B becomes current'
);

reset role;
select ok(
  (
    select canonical_state #>> '{note,value}' = '设备B随后值'
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and farm_generation = 2
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  )
  and not exists (
    select 1 from esheep_cloud.events
    where command_id = current_setting('esheep.test.interleaved_a_old_command')::uuid
  )
  and not exists (
    select 1 from esheep_cloud.attention_items
    where command_id = current_setting('esheep.test.interleaved_a_old_command')::uuid
  )
  and (
    select highest_device_sequence = 30
      and command_id = current_setting('esheep.test.interleaved_a_new_command')::uuid
    from esheep_cloud.field_device_watermarks
    where farm_id = current_setting('esheep.test.farm')::uuid
      and farm_generation = 2
      and stream_type = 'sheepProfile'
      and stream_id = current_setting('esheep.test.sheep')::uuid
      and field_key = 'note'
      and device_id = current_setting('esheep.test.device_a')::uuid
  ),
  'the per-device field watermark prevents an old A command from becoming a false A-vs-B confirmation'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select event.value ->> 'source_device_sequence'
    from jsonb_array_elements(
      public.esheep_cloud_pull_events_v2(
        current_setting('esheep.test.farm')::uuid,
        2,
        0,
        100
      ) -> 'events'
    ) event(value)
    where event.value ->> 'command_id' =
      current_setting('esheep.test.same_device_newer_command')
  ),
  '22',
  'the authoritative event exposes the signed source device sequence'
);

reset role;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select set_config(
  'esheep.test.multistream_result',
  pg_temp.esheep_cloud_submit_commands_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    jsonb_build_array(pg_temp.esheep_cloud_test_command(
      current_setting('esheep.test.multistream_command')::uuid,
      gen_random_uuid(),
      current_setting('esheep.test.farm')::uuid,
      2,
      current_setting('esheep.test.account_a')::uuid,
      current_setting('esheep.test.device_a')::uuid,
      1000,
      'transfer.record',
      'transfer',
      current_setting('esheep.test.multistream_primary')::uuid,
      '',
      0,
      current_setting('esheep.test.null_digest'),
      '{"type":"string","value":"transfer"}'::jsonb,
      '{}', 2, 1, '{}', null,
      'sheepLocation', current_setting('esheep.test.sheep')::uuid
    ))
  )::text,
  false
);

select is(
  current_setting('esheep.test.multistream_result')::jsonb #>> '{results,0,type}',
  'accepted',
  'a multi-stream command is accepted as one business operation'
);

select is(
  jsonb_array_length(
    current_setting('esheep.test.multistream_result')::jsonb #> '{results,0,event_sequences}'
  ),
  2,
  'a multi-stream command returns one contiguous event for every affected lane'
);

reset role;
select is(
  (
    select count(*)::integer
    from esheep_cloud.events
    where command_id = current_setting('esheep.test.multistream_command')::uuid
  ),
  2,
  'the transaction persists both primary and semantic stream events'
);

select is(
  (
    select stream_version::integer
    from esheep_cloud.streams
    where farm_id = current_setting('esheep.test.farm')::uuid
      and farm_generation = 2
      and stream_type = 'sheepLocation'
      and stream_id = current_setting('esheep.test.sheep')::uuid
  ),
  1,
  'the semantic stream is advanced instead of being silently ignored'
);

select is(
  (select count(*)::integer from esheep_cloud.events),
  12,
  'retrying photo registration cannot append a second photo event'
);

select ok(
  (
    esheep_cloud.audit_farm_integrity_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) ->> 'passed'
  )::boolean,
  'a later audit also verifies the immutable snapshot and newer events'
);

select set_config(
  'esheep.test.snapshot_count_before_integrity_hold',
  (select count(*)::text from esheep_cloud.snapshots),
  false
);

update esheep_cloud.events
set event_digest = repeat('f', 64)
where farm_id = current_setting('esheep.test.farm')::uuid
  and farm_generation = 2
  and event_sequence = 1;

update esheep_cloud.events
set event_body = jsonb_set(event_body, '{command_kind}', '"substituted"'::jsonb)
where farm_id = current_setting('esheep.test.farm')::uuid
  and farm_generation = 2
  and event_sequence = 2;

select ok(
  not (
    esheep_cloud.audit_farm_integrity_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) ->> 'passed'
  )::boolean
  and (
    esheep_cloud.farm_integrity_report_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) #>> '{checks,event_digest_mismatches}'
  )::integer = 1
  and (
    esheep_cloud.farm_integrity_report_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) #>> '{checks,event_body_mismatches}'
  )::integer = 1
  and (
    esheep_cloud.farm_integrity_report_v2(
      current_setting('esheep.test.farm')::uuid,
      2
    ) #>> '{checks,event_body_digest_mismatches}'
  )::integer = 1,
  'changed event receipts and substituted bodies are detected instead of trusted'
);

select ok(
  (
    select write_frozen
      and status = 'integrity_hold'
      and write_freeze_trace_id is not null
      and last_integrity_report ->> 'trace_id' = write_freeze_trace_id::text
    from esheep_cloud.farm_state
    where farm_id = current_setting('esheep.test.farm')::uuid
  ),
  'a failed audit durably freezes only the affected farm with a trace ID'
);

select is(
  esheep_cloud.build_snapshot_v2(
    current_setting('esheep.test.farm')::uuid,
    2,
    100
  ),
  null::uuid,
  'snapshot generation refuses corrupted authority without rolling back the hold'
);

select is(
  (select count(*)::integer from esheep_cloud.snapshots),
  current_setting('esheep.test.snapshot_count_before_integrity_hold')::integer,
  'a failed snapshot preflight cannot publish another initial-sync snapshot'
);

select * from finish();
rollback;
