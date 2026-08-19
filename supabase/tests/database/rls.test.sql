begin;

create extension if not exists pgtap with schema extensions;
select plan(55);

select set_config('esheep.test.user_a', gen_random_uuid()::text, false);
select set_config('esheep.test.user_b', gen_random_uuid()::text, false);
select set_config('esheep.test.user_c', gen_random_uuid()::text, false);
select set_config('esheep.test.user_d', gen_random_uuid()::text, false);
select set_config('esheep.test.farm_a', gen_random_uuid()::text, false);
select set_config('esheep.test.invite_code', encode(gen_random_bytes(32), 'hex'), false);

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at
)
values
  (
    current_setting('esheep.test.user_a')::uuid,
    'authenticated',
    'authenticated',
    'rls-a@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')),
    now()
  ),
  (
    current_setting('esheep.test.user_b')::uuid,
    'authenticated',
    'authenticated',
    'rls-b@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')),
    now()
  ),
  (
    current_setting('esheep.test.user_c')::uuid,
    'authenticated',
    'authenticated',
    'rls-c@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')),
    now()
  );

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_user_meta_data
)
values (
  current_setting('esheep.test.user_d')::uuid,
  'authenticated',
  'authenticated',
  'rls-d@example.invalid',
  crypt('not-a-real-user-password', gen_salt('bf')),
  now(),
  jsonb_build_object(
    'display_name',
    '  Development' || chr(1) || ' Tester  '
  )
);

insert into public.entitlements (
  owner_user_id,
  product_id,
  state,
  valid_until
)
values (
  current_setting('esheep.test.user_a')::uuid,
  'com.sheepfarm.ios.pro.monthly',
  'active',
  now() + interval '30 days'
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

select lives_ok(
  format(
    $$update public.profiles
      set display_name = 'Renamed account'
      where user_id = %L::uuid$$,
    current_setting('esheep.test.user_a')
  ),
  'user can update own account display name'
);

select results_eq(
  format(
    $$with updated as (
        update public.profiles
        set display_name = 'Must not apply'
        where user_id = %L::uuid
        returning 1
      )
      select count(*)::integer from updated$$,
    current_setting('esheep.test.user_b')
  ),
  array[0],
  'user cannot update another account display name'
);

select lives_ok(
  format(
    $$select public.register_farm_authority(%L::uuid, 'supabase', null)$$,
    current_setting('esheep.test.farm_a')
  ),
  'owner can prepare a Supabase farm'
);

select lives_ok(
  format(
    $$select public.activate_farm_authority(%L::uuid, 0, 0, %L)$$,
    current_setting('esheep.test.farm_a'),
    repeat('0', 64)
  ),
  'owner can activate a verified empty baseline'
);

select is(
  (
    select count(*)::integer
    from public.farm_registry
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  1,
  'owner can read own farm registry'
);

select is(
  (
    select count(*)::integer
    from public.farm_members
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  1,
  'owner can read own membership'
);

select lives_ok(
  format(
    $$select public.create_farm_invite(
      %L::uuid,
      'worker',
      encode(extensions.digest(%L, 'sha256'), 'hex'),
      now() + interval '23 hours'
    )$$,
    current_setting('esheep.test.farm_a'),
    current_setting('esheep.test.invite_code')
  ),
  'owner can create a one-time invite'
);

select lives_ok(
  format(
    $$insert into storage.objects (bucket_id, name, owner_id)
      values ('farm-assets', %L, %L)$$,
    lower(current_setting('esheep.test.farm_a')) || '/' || repeat('b', 64),
    current_setting('esheep.test.user_a')
  ),
  'owner can upload to the farm-scoped private asset path'
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

select is(
  (
    select count(*)::integer
    from public.farm_registry
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'unrelated user cannot query another farm registry'
);

select is(
  (
    select count(*)::integer
    from public.farm_operations
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'unrelated user cannot query another farm operation stream'
);

select throws_ok(
  format(
    $$
      select public.apply_farm_operation(
        %L::uuid,
        gen_random_uuid(),
        0,
        'note',
        gen_random_uuid(),
        0,
        1,
        1,
        encode(convert_to('{}', 'utf8'), 'base64'),
        encode(digest(convert_to('{}', 'utf8'), 'sha256'), 'hex'),
        %L::uuid,
        gen_random_uuid(),
        '',
        '',
        now(),
        now(),
        null
      )
    $$,
    current_setting('esheep.test.farm_a'),
    current_setting('esheep.test.user_b')
  ),
  '42501',
  'farm_write_denied',
  'unrelated user cannot write another farm'
);

select is(
  (
    select count(*)::integer
    from public.farm_members
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'unrelated user cannot enumerate another farm members'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'farm-assets'
      and name like lower(current_setting('esheep.test.farm_a')) || '/%'
  ),
  0,
  'user B cannot read farm Storage before invitation'
);

select lives_ok(
  format(
    $$select public.redeem_farm_invite(%L)$$,
    current_setting('esheep.test.invite_code')
  ),
  'invited user can redeem exactly once'
);

select throws_ok(
  format(
    $$select public.redeem_farm_invite(%L)$$,
    current_setting('esheep.test.invite_code')
  ),
  '22023',
  'farm_invite_invalid_or_expired',
  'redeemed invite cannot be reused'
);

select is(
  (
    select count(*)::integer
    from public.farm_registry
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  1,
  'redeemed member can read only the invited farm'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'farm-assets'
      and name like lower(current_setting('esheep.test.farm_a')) || '/%'
  ),
  1,
  'redeemed member can read invited farm Storage'
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

select lives_ok(
  format(
    $$select public.revoke_farm_member(%L::uuid, %L::uuid)$$,
    current_setting('esheep.test.farm_a'),
    current_setting('esheep.test.user_b')
  ),
  'owner can revoke the invited member'
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

select is(
  (
    select count(*)::integer
    from public.farm_registry
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'revoked member loses farm access after reauthentication'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'farm-assets'
      and name like lower(current_setting('esheep.test.farm_a')) || '/%'
  ),
  0,
  'revoked member loses Storage access after reauthentication'
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
  (
    select count(*)::integer
    from public.farm_registry
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'uninvited user C cannot read farm registry'
);

select is(
  (
    select count(*)::integer
    from public.farm_operations
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'uninvited user C cannot read operations'
);

select is(
  (
    select count(*)::integer
    from public.farm_members
    where farm_id = current_setting('esheep.test.farm_a')::uuid
  ),
  0,
  'uninvited user C cannot enumerate members'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'farm-assets'
      and name like lower(current_setting('esheep.test.farm_a')) || '/%'
  ),
  0,
  'uninvited user C cannot read farm Storage'
);

reset role;

select ok(
  has_function_privilege(
    'authenticated',
    'public.get_farm_storage_metrics(uuid)',
    'EXECUTE'
  ),
  'authenticated members can invoke aggregate storage diagnostics'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.get_farm_storage_metrics(uuid)',
    'EXECUTE'
  ),
  'anonymous users cannot invoke aggregate storage diagnostics'
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

select lives_ok(
  format(
    $$select public.get_farm_storage_metrics(%L::uuid)$$,
    current_setting('esheep.test.farm_a')
  ),
  'active owner can read aggregate storage diagnostics'
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

select throws_ok(
  format(
    $$select public.get_farm_storage_metrics(%L::uuid)$$,
    current_setting('esheep.test.farm_a')
  ),
  '42501',
  'farm_access_denied',
  'uninvited user cannot read aggregate storage diagnostics'
);

reset role;

select is(
  (
    select count(*)::integer
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relkind = 'r'
      and relation.relrowsecurity
      and relation.relname in (
        'profiles', 'devices', 'farm_registry', 'farm_members', 'farm_invites',
        'farm_operations', 'farm_entities', 'farm_tombstones', 'farm_assets',
        'farm_checkpoints', 'authority_transitions', 'entitlements',
        'account_deletion_requests'
      )
  ),
  13,
  'all thirteen public business tables have RLS enabled'
);

select is(
  (
    select count(*)::integer
    from (
      values
        ('profiles'), ('devices'), ('farm_registry'), ('farm_members'),
        ('farm_invites'), ('farm_operations'), ('farm_entities'),
        ('farm_tombstones'), ('farm_assets'), ('farm_checkpoints'),
        ('authority_transitions'), ('entitlements'),
        ('account_deletion_requests')
    ) as business_table(table_name)
    where has_table_privilege(
      'authenticated',
      format('public.%I', business_table.table_name),
      'TRUNCATE'
    )
      or has_table_privilege(
        'authenticated',
        format('public.%I', business_table.table_name),
        'REFERENCES'
      )
      or has_table_privilege(
        'authenticated',
        format('public.%I', business_table.table_name),
        'TRIGGER'
      )
  ),
  0,
  'authenticated has no whole-table privileges outside RLS'
);

select is(
  (
    select count(*)::integer
    from (
      values
        ('profiles'), ('devices'), ('farm_registry'), ('farm_members'),
        ('farm_invites'), ('farm_operations'), ('farm_entities'),
        ('farm_tombstones'), ('farm_assets'), ('farm_checkpoints'),
        ('authority_transitions'), ('entitlements'),
        ('account_deletion_requests')
    ) as business_table(table_name)
    where has_table_privilege(
      'anon',
      format('public.%I', business_table.table_name),
      'SELECT'
    )
  ),
  0,
  'anon cannot select any public business table'
);

select ok(
  has_column_privilege(
    'authenticated',
    'public.profiles',
    'display_name',
    'UPDATE'
  )
  and not has_column_privilege(
    'authenticated',
    'public.profiles',
    'app_account_id',
    'UPDATE'
  ),
  'profile updates are limited to presentation columns'
);

select ok(
  exists (
    select 1
    from storage.buckets
    where id = 'account-avatars'
      and not public
      and file_size_limit = 65536
  ),
  'account avatar bucket is private and size-limited'
);

select ok(
  has_column_privilege('authenticated', 'public.profiles', 'avatar_digest', 'UPDATE')
  and has_column_privilege('authenticated', 'public.profiles', 'avatar_revision', 'UPDATE')
  and not has_column_privilege('authenticated', 'public.profiles', 'app_account_id', 'UPDATE'),
  'authenticated can update avatar presentation metadata but not account identity'
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

select lives_ok(
  format(
    $$update public.profiles
      set avatar_digest = %L, avatar_revision = 1
      where user_id = %L::uuid$$,
    repeat('a', 64),
    current_setting('esheep.test.user_a')
  ),
  'user can update own avatar metadata'
);

select lives_ok(
  format(
    $$insert into storage.objects (bucket_id, name, owner_id)
      values ('account-avatars', %L, %L)$$,
    lower(current_setting('esheep.test.user_a')) || '/avatar.jpg',
    current_setting('esheep.test.user_a')
  ),
  'user can upload only to own avatar object'
);

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'account-avatars'
  ),
  1,
  'user can read own avatar object'
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

select is(
  (
    select count(*)::integer
    from storage.objects
    where bucket_id = 'account-avatars'
  ),
  0,
  'another user cannot read the account avatar object'
);

select throws_ok(
  format(
    $$insert into storage.objects (bucket_id, name, owner_id)
      values ('account-avatars', %L, %L)$$,
    lower(current_setting('esheep.test.user_a')) || '/avatar.jpg',
    current_setting('esheep.test.user_b')
  ),
  '42501',
  'new row violates row-level security policy for table "objects"',
  'another user cannot overwrite the account avatar object'
);

reset role;

select is(
  (
    select count(*)::integer
    from pg_default_acl defaults
    cross join lateral aclexplode(defaults.defaclacl) privilege
    where defaults.defaclnamespace = 'public'::regnamespace
      and defaults.defaclrole = 'postgres'::regrole
      and privilege.grantee in (
        0,
        'anon'::regrole::oid,
        'authenticated'::regrole::oid
      )
  ),
  0,
  'postgres public defaults do not auto-grant client roles'
);

select todo(
  'Hosted postgres cannot alter the platform-owned supabase_admin defaults; ' ||
  'the enabled DDL event trigger enforces the same effective public guard.',
  1
);
select is(
  (
    select count(*)::integer
    from pg_default_acl defaults
    cross join lateral aclexplode(defaults.defaclacl) privilege
    where defaults.defaclnamespace = 'public'::regnamespace
      and defaults.defaclrole = 'supabase_admin'::regrole
      and privilege.grantee in (
        0,
        'anon'::regrole::oid,
        'authenticated'::regrole::oid
      )
  ),
  0,
  'supabase_admin public defaults do not auto-grant client roles'
);

select ok(
  exists (
    select 1
    from pg_event_trigger event_trigger
    join pg_proc function
      on function.oid = event_trigger.evtfoid
    where event_trigger.evtname = 'esheep_guard_public_data_api_exposure'
      and event_trigger.evtenabled = 'O'
      and not function.prosecdef
      and function.proconfig @> array['search_path=""']
  ),
  'DDL guard neutralizes hosted legacy auto-grants as the creating role'
);

set local role authenticated;
select throws_ok(
  format(
    $$insert into public.farm_registry (
        farm_id, owner_user_id, provider
      ) values (%L::uuid, %L::uuid, 'supabase')$$,
    gen_random_uuid(),
    current_setting('esheep.test.user_c')
  ),
  '42501',
  'permission denied for table farm_registry',
  'authenticated cannot bypass RPCs with a direct business write'
);
reset role;

create table public.esheep_acl_table_probe (id bigint primary key);
create sequence public.esheep_acl_sequence_probe;
create function public.esheep_acl_function_probe()
returns integer
language sql
as $$ select 1 $$;

select ok(
  not has_table_privilege(
    'authenticated',
    'public.esheep_acl_table_probe',
    'SELECT'
  ),
  'new postgres-owned tables are not auto-exposed'
);

select ok(
  not has_sequence_privilege(
    'authenticated',
    'public.esheep_acl_sequence_probe',
    'USAGE'
  ),
  'new postgres-owned sequences are not auto-exposed'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.esheep_acl_function_probe()',
    'EXECUTE'
  ),
  'new postgres-owned functions are not auto-exposed'
);

select is(
  (
    select count(*)::integer
    from pg_proc function
    join pg_namespace namespace on namespace.oid = function.pronamespace
    where namespace.nspname = 'public'
      and function.prosecdef
      and (
        function.proconfig is null
        or not (function.proconfig @> array['search_path=""'])
      )
  ),
  0,
  'all public SECURITY DEFINER functions pin an empty search_path'
);

select is(
  (
    select count(*)::integer
    from pg_proc function
    join pg_namespace namespace on namespace.oid = function.pronamespace
    where namespace.nspname = 'public'
      and function.prosecdef
      and function.oid <>
        'public.get_account_deletion_status(uuid)'::regprocedure
      and has_function_privilege(
        'anon',
        function.oid,
        'EXECUTE'
      )
  ),
  0,
  'anon cannot execute public SECURITY DEFINER functions except the opaque deletion status lookup'
);

select is(
  (
    select display_name
    from public.profiles
    where user_id = current_setting('esheep.test.user_d')::uuid
  ),
  'Development Tester',
  'presentation metadata is sanitized before entering profiles'
);

select ok(
  to_regprocedure(
    'public.stage_farm_baseline_batch(uuid,uuid,integer,jsonb)'
  ) is not null,
  'non-empty baseline staging RPC is deployed'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.stage_farm_baseline_batch(uuid,uuid,integer,jsonb)',
    'EXECUTE'
  ),
  'anon cannot stage a farm baseline'
);

select ok(
  to_regprocedure(
    'public.abort_farm_authority_transition(uuid,uuid)'
  ) is not null,
  'pre-commit abort RPC is deployed'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.complete_farm_authority_transition(uuid,uuid,integer)',
    'EXECUTE'
  ),
  'anonymous users cannot complete an authority transition'
);

select is(
  (
    select count(*)::integer
    from pg_policies
    where schemaname = 'realtime'
      and tablename = 'messages'
      and roles @> array['authenticated'::name]
      and cmd = 'INSERT'
  ),
  0,
  'clients have no Realtime Broadcast insert policy'
);

select ok(
  to_regclass('public.farm_checkpoints_migration_id_idx') is not null,
  'checkpoint transition foreign key has a covering index'
);

select * from finish();
rollback;
