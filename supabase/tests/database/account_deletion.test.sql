begin;

create extension if not exists pgtap with schema extensions;
select plan(9);

select set_config('esheep.test.deletion_user', gen_random_uuid()::text, false);

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at
) values (
  current_setting('esheep.test.deletion_user')::uuid,
  'authenticated',
  'authenticated',
  'deletion@example.invalid',
  crypt('not-a-real-user-password', gen_salt('bf')),
  now()
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.deletion_user'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.request_account_deletion()$$,
  'authenticated user can queue account deletion'
);

select lives_ok(
  $$select public.request_account_deletion()$$,
  'duplicate account deletion request is idempotent'
);

select is(
  (
    select count(*)::integer
    from public.account_deletion_requests
  ),
  1,
  'idempotent request creates one open job'
);

select set_config(
  'esheep.test.deletion_job',
  (select deletion_job_id::text from public.account_deletion_requests limit 1),
  false
);

select ok(
  has_function_privilege(
    'anon',
    'public.get_account_deletion_status(uuid)',
    'EXECUTE'
  ),
  'opaque deletion job status can be queried after sign-out'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('role', 'service_role')::text,
  true
);
set local role service_role;

select lives_ok(
  $$select public.claim_account_deletion_jobs(1)$$,
  'service role can claim queued deletion jobs'
);

reset role;
select is(
  (select status from public.account_deletion_requests limit 1),
  'processing',
  'claimed deletion job is processing'
);

select set_config(
  'request.jwt.claims',
  json_build_object('role', 'service_role')::text,
  true
);
set local role service_role;
select lives_ok(
  format(
    $$select public.complete_account_deletion_job(%L::uuid)$$,
    current_setting('esheep.test.deletion_job')
  ),
  'service role can complete the deletion job'
);

reset role;
select is(
  (select status from public.account_deletion_requests limit 1),
  'completed',
  'completed status is retained'
);

delete from auth.users
where id = current_setting('esheep.test.deletion_user')::uuid;

select is(
  (select user_id from public.account_deletion_requests limit 1),
  null,
  'deletion status survives Auth user deletion without personal identifier'
);

select * from finish();
rollback;
