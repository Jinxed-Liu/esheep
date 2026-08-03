begin;

create extension if not exists pgtap with schema extensions;
select plan(16);

select set_config('esheep.test.icloud_owner', gen_random_uuid()::text, false);
select set_config('esheep.test.icloud_member', gen_random_uuid()::text, false);
select set_config('esheep.test.icloud_device', gen_random_uuid()::text, false);
select set_config('esheep.test.member_device', gen_random_uuid()::text, false);
select set_config('esheep.test.icloud_farm', gen_random_uuid()::text, false);
select set_config('esheep.test.collision_farm', gen_random_uuid()::text, false);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
values
  (
    current_setting('esheep.test.icloud_owner')::uuid,
    'authenticated', 'authenticated', 'icloud-owner@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.test.icloud_member')::uuid,
    'authenticated', 'authenticated', 'icloud-member@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  );

insert into public.devices (device_id, user_id, public_key_jwk, display_name)
values
  (
    current_setting('esheep.test.icloud_device')::uuid,
    current_setting('esheep.test.icloud_owner')::uuid,
    '{"kty":"EC","crv":"P-256","x":"AA","y":"AA"}'::jsonb,
    'Owner device'
  ),
  (
    current_setting('esheep.test.member_device')::uuid,
    current_setting('esheep.test.icloud_member')::uuid,
    '{"kty":"EC","crv":"P-256","x":"BB","y":"BB"}'::jsonb,
    'Member device'
  );

insert into public.farm_registry (
  farm_id, owner_user_id, provider, status, authority_generation, current_revision
)
values (
  current_setting('esheep.test.collision_farm')::uuid,
  current_setting('esheep.test.icloud_owner')::uuid,
  'supabase', 'active', 1, 0
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.icloud_owner'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner'
    )$$,
    current_setting('esheep.test.icloud_farm'),
    current_setting('esheep.test.icloud_owner'),
    current_setting('esheep.test.icloud_device'),
    'Farm_' || lower(current_setting('esheep.test.icloud_farm'))
  ),
  'authenticated owner registers only CloudKit control-plane metadata'
);

select is(
  (
    select provider
    from public.farm_registry
    where farm_id = current_setting('esheep.test.icloud_farm')::uuid
  ),
  'icloud',
  'registered control-plane farm is iCloud authoritative'
);

select lives_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner', 3
    )$$,
    current_setting('esheep.test.icloud_farm'),
    current_setting('esheep.test.icloud_owner'),
    current_setting('esheep.test.icloud_device'),
    'Farm_' || lower(current_setting('esheep.test.icloud_farm'))
  ),
  'legacy CloudKit security generation can be observed during registration'
);

select is(
  (
    select authority_generation
    from public.farm_registry
    where farm_id = current_setting('esheep.test.icloud_farm')::uuid
  ),
  4,
  'control plane advances above the observed legacy generation'
);

select lives_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner', 4
    )$$,
    current_setting('esheep.test.icloud_farm'),
    current_setting('esheep.test.icloud_owner'),
    current_setting('esheep.test.icloud_device'),
    'Farm_' || lower(current_setting('esheep.test.icloud_farm'))
  ),
  'repeating the current generation is idempotent'
);

select is(
  (
    select authority_generation
    from public.farm_registry
    where farm_id = current_setting('esheep.test.icloud_farm')::uuid
  ),
  4,
  'idempotent registration does not advance generation repeatedly'
);

select throws_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner'
    )$$,
    gen_random_uuid(),
    current_setting('esheep.test.icloud_member'),
    current_setting('esheep.test.icloud_device'),
    'Farm_' || lower(gen_random_uuid()::text)
  ),
  '42501',
  'owner_account_mismatch',
  'caller cannot register a different app account'
);

select throws_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner'
    )$$,
    current_setting('esheep.test.icloud_farm'),
    current_setting('esheep.test.icloud_owner'),
    current_setting('esheep.test.member_device'),
    'Farm_' || lower(current_setting('esheep.test.icloud_farm'))
  ),
  '42501',
  'active_device_required',
  'caller cannot register another user device'
);

select throws_ok(
  format(
    $$select * from public.register_owned_icloud_farm(
      %L::uuid, %L::uuid, %L::uuid, %L, '_icloud-owner'
    )$$,
    current_setting('esheep.test.collision_farm'),
    current_setting('esheep.test.icloud_owner'),
    current_setting('esheep.test.icloud_device'),
    'Farm_' || lower(current_setting('esheep.test.collision_farm'))
  ),
  '42501',
  'farm_authority_collision',
  'iCloud registration cannot replace an existing Supabase authority'
);

select throws_ok(
  'select count(*) from public.icloud_capability_certificates',
  '42501',
  null,
  'authenticated clients cannot read the certificate audit table directly'
);

reset role;

select ok(
  (select relrowsecurity from pg_class where oid = 'public.icloud_capability_certificates'::regclass),
  'certificate audit table has RLS enabled'
);
select ok(
  not has_table_privilege('authenticated', 'public.icloud_capability_certificates', 'SELECT,INSERT,UPDATE,DELETE'),
  'authenticated has no direct certificate table mutation privileges'
);
select ok(
  has_function_privilege('authenticated', 'public.register_owned_icloud_farm(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'authenticated can execute the narrowly scoped registration RPC'
);
select ok(
  not has_function_privilege('anon', 'public.register_owned_icloud_farm(uuid,uuid,uuid,text,text)', 'EXECUTE'),
  'anon cannot execute the registration RPC'
);

insert into public.farm_members (
  farm_id, user_id, app_account_id, role, status, invited_by
)
values (
  current_setting('esheep.test.icloud_farm')::uuid,
  current_setting('esheep.test.icloud_member')::uuid,
  current_setting('esheep.test.icloud_member')::uuid,
  'worker', 'active', current_setting('esheep.test.icloud_owner')::uuid
);
insert into public.icloud_capability_certificates (
  certificate_id, farm_id, user_id, app_account_id, device_id, role,
  capabilities, certificate_jws, certificate_digest, key_id,
  issued_at, expires_at
)
values (
  gen_random_uuid(),
  current_setting('esheep.test.icloud_farm')::uuid,
  current_setting('esheep.test.icloud_member')::uuid,
  current_setting('esheep.test.icloud_member')::uuid,
  current_setting('esheep.test.member_device')::uuid,
  'worker', '["readFarm","recordProduction"]'::jsonb,
  'test-jws', repeat('0', 64), 'test-key', now(), now() + interval '1 day'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.icloud_owner'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;
select lives_ok(
  format(
    $$select * from public.revoke_farm_member(%L::uuid, %L::uuid)$$,
    current_setting('esheep.test.icloud_farm'),
    current_setting('esheep.test.icloud_member')
  ),
  'owner can revoke an iCloud member through the established API'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.icloud_capability_certificates
    where farm_id = current_setting('esheep.test.icloud_farm')::uuid
      and user_id = current_setting('esheep.test.icloud_member')::uuid
      and revoked_at is not null
  ),
  1,
  'member revocation also revokes active iCloud capability certificates'
);

select * from finish();
rollback;
