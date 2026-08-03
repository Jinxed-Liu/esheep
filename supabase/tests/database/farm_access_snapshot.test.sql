begin;

create extension if not exists pgtap with schema extensions;
select plan(8);

select set_config('esheep.access.user_a', gen_random_uuid()::text, false);
select set_config('esheep.access.user_b', gen_random_uuid()::text, false);
select set_config('esheep.access.user_c', gen_random_uuid()::text, false);
select set_config('esheep.access.farm', gen_random_uuid()::text, false);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
values
  (
    current_setting('esheep.access.user_a')::uuid,
    'authenticated', 'authenticated', 'access-a@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.access.user_b')::uuid,
    'authenticated', 'authenticated', 'access-b@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.access.user_c')::uuid,
    'authenticated', 'authenticated', 'access-c@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  );

insert into public.farm_registry (
  farm_id, owner_user_id, provider, status, authority_generation, current_revision
)
values (
  current_setting('esheep.access.farm')::uuid,
  current_setting('esheep.access.user_a')::uuid,
  'supabase', 'active', 1, 492
);

insert into public.farm_members (
  farm_id, user_id, app_account_id, role, status
)
select
  current_setting('esheep.access.farm')::uuid,
  current_setting('esheep.access.user_a')::uuid,
  app_account_id,
  'owner',
  'active'
from public.profiles
where user_id = current_setting('esheep.access.user_a')::uuid;

insert into public.farm_members (
  farm_id, user_id, app_account_id, role, status
)
select
  current_setting('esheep.access.farm')::uuid,
  current_setting('esheep.access.user_b')::uuid,
  app_account_id,
  'worker',
  'active'
from public.profiles
where user_id = current_setting('esheep.access.user_b')::uuid;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.access.user_a'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select count(*)::integer
    from public.list_my_active_farm_access() access
    where access.member_role = 'owner'
      and access.current_revision = 492
  ),
  1,
  'owner receives the active farm snapshot'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.access.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select count(*)::integer
    from public.list_my_active_farm_access() access
    where access.owner_user_id =
            current_setting('esheep.access.user_a')::uuid
      and access.member_user_id =
            current_setting('esheep.access.user_b')::uuid
      and access.member_role = 'worker'
      and access.authority_generation = 1
  ),
  1,
  'member receives owner identity, role and generation'
);

select is(
  (select count(*)::integer from public.farm_members),
  2,
  'active member RLS permits the function owner join'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.access.user_c'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (select count(*)::integer from public.list_my_active_farm_access()),
  0,
  'uninvited user receives no access row'
);

reset role;
update public.farm_members
set status = 'revoked', updated_at = now()
where farm_id = current_setting('esheep.access.farm')::uuid
  and user_id = current_setting('esheep.access.user_b')::uuid;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.access.user_b'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select is(
  (select count(*)::integer from public.list_my_active_farm_access()),
  0,
  'revoked member immediately receives no access row'
);

reset role;

select ok(
  has_function_privilege(
    'authenticated', 'public.list_my_active_farm_access()', 'EXECUTE'
  ),
  'authenticated can execute the access snapshot'
);

select ok(
  not has_function_privilege(
    'anon', 'public.list_my_active_farm_access()', 'EXECUTE'
  ),
  'anon cannot execute the access snapshot'
);

select ok(
  exists (
    select 1
    from pg_proc function
    where function.oid =
      'public.list_my_active_farm_access()'::regprocedure
      and not function.prosecdef
      and function.proconfig @> array['search_path=""']
  ),
  'snapshot is SECURITY INVOKER with an empty search_path'
);

select * from finish();
rollback;
