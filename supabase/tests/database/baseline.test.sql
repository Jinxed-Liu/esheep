begin;

create extension if not exists pgtap with schema extensions;
select plan(8);

select set_config('esheep.test.user', gen_random_uuid()::text, false);
select set_config('esheep.test.farm', gen_random_uuid()::text, false);
select set_config('esheep.test.migration', gen_random_uuid()::text, false);
select set_config('esheep.test.device', gen_random_uuid()::text, false);
select set_config('esheep.test.operation', gen_random_uuid()::text, false);

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at
) values (
  current_setting('esheep.test.user')::uuid,
  'authenticated',
  'authenticated',
  'baseline-owner@example.invalid',
  crypt('not-a-real-user-password', gen_salt('bf')),
  now()
);

insert into public.entitlements (
  owner_user_id, product_id, state, valid_until
) values (
  current_setting('esheep.test.user')::uuid,
  'development-baseline-test',
  'active',
  now() + interval '1 day'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.user'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  format(
    $$select public.register_device(%L::uuid, '{"kty":"EC"}'::jsonb, 'pgTAP')$$,
    current_setting('esheep.test.device')
  ),
  'owner registers the baseline signing device'
);

select lives_ok(
  format(
    $$select public.begin_farm_authority_transition(
      %L::uuid, %L::uuid, 'local_only', 1, 1, %L
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration'),
    repeat('a', 64)
  ),
  'owner begins a non-empty authority transition'
);

select lives_ok(
  format(
    $$select * from public.stage_farm_baseline_batch(
      %L::uuid, %L::uuid, 1,
      jsonb_build_array(jsonb_build_object(
        'operation_id', %L,
        'client_sequence', 1,
        'entity_type', 'farm',
        'entity_id', %L,
        'base_revision', 0,
        'resulting_revision', 7,
        'schema_version', 2,
        'payload_base64', encode(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'base64'),
        'payload_digest', encode(extensions.digest(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'sha256'), 'hex'),
        'modified_by_account_id', %L,
        'modified_by_device_id', %L,
        'capability_certificate', 'supabase-authenticated-owner-baseline',
        'operation_signature', '',
        'occurred_at', now(),
        'modified_at', now(),
        'deleted_at', null
      ))
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration'),
    current_setting('esheep.test.operation'),
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.user'),
    current_setting('esheep.test.device')
  ),
  'bootstrap operation preserves a source entity revision'
);

select is(
  (
    select staged_operation_count::integer
    from public.get_farm_authority_transition_status(
      current_setting('esheep.test.farm')::uuid,
      current_setting('esheep.test.migration')::uuid
    )
  ),
  1,
  'transition status reports the confirmed operation'
);

select lives_ok(
  format(
    $$select * from public.stage_farm_baseline_batch(
      %L::uuid, %L::uuid, 1,
      jsonb_build_array(jsonb_build_object(
        'operation_id', %L,
        'client_sequence', 1,
        'entity_type', 'farm',
        'entity_id', %L,
        'base_revision', 0,
        'resulting_revision', 7,
        'schema_version', 2,
        'payload_base64', encode(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'base64'),
        'payload_digest', encode(extensions.digest(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'sha256'), 'hex'),
        'modified_by_account_id', %L,
        'modified_by_device_id', %L,
        'capability_certificate', 'supabase-authenticated-owner-baseline',
        'operation_signature', '',
        'occurred_at', now(),
        'modified_at', now(),
        'deleted_at', null
      ))
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration'),
    current_setting('esheep.test.operation'),
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.user'),
    current_setting('esheep.test.device')
  ),
  'byte-identical operation retry is idempotent'
);

select throws_ok(
  format(
    $$select * from public.stage_farm_baseline_batch(
      %L::uuid, %L::uuid, 1,
      jsonb_build_array(jsonb_build_object(
        'operation_id', %L,
        'client_sequence', 2,
        'entity_type', 'farm',
        'entity_id', %L,
        'base_revision', 0,
        'resulting_revision', 7,
        'schema_version', 2,
        'payload_base64', encode(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'base64'),
        'payload_digest', encode(extensions.digest(convert_to('{"kind":"bootstrapEntity"}', 'utf8'), 'sha256'), 'hex'),
        'modified_by_account_id', %L,
        'modified_by_device_id', %L,
        'capability_certificate', 'supabase-authenticated-owner-baseline',
        'operation_signature', '',
        'occurred_at', now(),
        'modified_at', now(),
        'deleted_at', null
      ))
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration'),
    current_setting('esheep.test.operation'),
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.user'),
    current_setting('esheep.test.device')
  ),
  '23505',
  'operation_id_payload_mismatch',
  'same operation ID with different content is rejected'
);

select throws_ok(
  format(
    $$select * from public.stage_farm_baseline_batch(
      %L::uuid, %L::uuid, 1,
      (select jsonb_agg(jsonb_build_object('client_sequence', value))
       from generate_series(1, 26) value)
    )$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration')
  ),
  '22023',
  'operation_batch_size_invalid',
  'baseline batches are capped at 25 operations'
);

select lives_ok(
  format(
    $$select public.abort_farm_authority_transition(%L::uuid, %L::uuid)$$,
    current_setting('esheep.test.farm'),
    current_setting('esheep.test.migration')
  ),
  'owner can abort before authority commit'
);

select * from finish();
rollback;
