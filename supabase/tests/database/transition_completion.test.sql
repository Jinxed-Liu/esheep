begin;

create extension if not exists pgtap with schema extensions;
select plan(7);

select set_config('esheep.test.owner', gen_random_uuid()::text, false);
select set_config('esheep.test.other', gen_random_uuid()::text, false);
select set_config('esheep.test.active_farm', gen_random_uuid()::text, false);
select set_config('esheep.test.active_migration', gen_random_uuid()::text, false);
select set_config('esheep.test.precommit_farm', gen_random_uuid()::text, false);
select set_config('esheep.test.precommit_migration', gen_random_uuid()::text, false);

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at
)
values
  (
    current_setting('esheep.test.owner')::uuid,
    'authenticated',
    'authenticated',
    'transition-owner@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')),
    now()
  ),
  (
    current_setting('esheep.test.other')::uuid,
    'authenticated',
    'authenticated',
    'transition-other@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')),
    now()
  );

insert into public.entitlements (
  owner_user_id,
  product_id,
  state,
  valid_until
)
values (
  current_setting('esheep.test.owner')::uuid,
  'transition-completion-test',
  'active',
  now() + interval '1 day'
);

insert into public.farm_registry (
  farm_id,
  owner_user_id,
  provider,
  status,
  authority_generation,
  current_revision
)
values
  (
    current_setting('esheep.test.active_farm')::uuid,
    current_setting('esheep.test.owner')::uuid,
    'supabase',
    'active',
    1,
    9
  ),
  (
    current_setting('esheep.test.precommit_farm')::uuid,
    current_setting('esheep.test.owner')::uuid,
    'supabase',
    'preparing',
    1,
    0
  );

insert into public.farm_members (
  farm_id, user_id, app_account_id, role, status
)
values
  (
    current_setting('esheep.test.active_farm')::uuid,
    current_setting('esheep.test.owner')::uuid,
    current_setting('esheep.test.owner')::uuid,
    'owner',
    'active'
  ),
  (
    current_setting('esheep.test.precommit_farm')::uuid,
    current_setting('esheep.test.owner')::uuid,
    current_setting('esheep.test.owner')::uuid,
    'owner',
    'active'
  );

insert into public.authority_transitions (
  migration_id,
  farm_id,
  source_provider,
  target_provider,
  source_generation,
  target_generation,
  baseline_revision,
  state,
  initiated_by,
  committed_at
)
values
  (
    current_setting('esheep.test.active_migration')::uuid,
    current_setting('esheep.test.active_farm')::uuid,
    'local_only',
    'supabase',
    0,
    1,
    0,
    'draining',
    current_setting('esheep.test.owner')::uuid,
    now()
  ),
  (
    current_setting('esheep.test.precommit_migration')::uuid,
    current_setting('esheep.test.precommit_farm')::uuid,
    'local_only',
    'supabase',
    0,
    1,
    0,
    'verifying',
    current_setting('esheep.test.owner')::uuid,
    null
  );

-- Farm creation requires a writable entitlement, but completing an already
-- committed transition must remain recoverable after that entitlement ends.
delete from public.entitlements
where owner_user_id = current_setting('esheep.test.owner')::uuid;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.owner'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  format(
    $$select * from public.complete_farm_authority_transition(
      %L::uuid, %L::uuid, 1
    )$$,
    current_setting('esheep.test.active_farm'),
    current_setting('esheep.test.active_migration')
  ),
  'owner completes an already committed transition without entitlement'
);

select is(
  (
    select state
    from public.authority_transitions
    where migration_id =
      current_setting('esheep.test.active_migration')::uuid
  ),
  'completed',
  'transition is durably completed'
);

select lives_ok(
  format(
    $$select * from public.complete_farm_authority_transition(
      %L::uuid, %L::uuid, 1
    )$$,
    current_setting('esheep.test.active_farm'),
    current_setting('esheep.test.active_migration')
  ),
  'completion retry is idempotent'
);

select is(
  (
    select count(*)::integer
    from public.entitlements
    where owner_user_id =
      current_setting('esheep.test.owner')::uuid
  ),
  0,
  'post-commit completion does not require an entitlement row'
);

select throws_ok(
  format(
    $$select * from public.complete_farm_authority_transition(
      %L::uuid, %L::uuid, 2
    )$$,
    current_setting('esheep.test.active_farm'),
    current_setting('esheep.test.active_migration')
  ),
  '42501',
  'farm_transition_completion_denied',
  'incorrect generation is rejected'
);

select throws_ok(
  format(
    $$select * from public.complete_farm_authority_transition(
      %L::uuid, %L::uuid, 1
    )$$,
    current_setting('esheep.test.precommit_farm'),
    current_setting('esheep.test.precommit_migration')
  ),
  '42501',
  'farm_transition_completion_denied',
  'pre-commit transition cannot be completed'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.other'),
    'role', 'authenticated'
  )::text,
  true
);

select throws_ok(
  format(
    $$select * from public.complete_farm_authority_transition(
      %L::uuid, %L::uuid, 1
    )$$,
    current_setting('esheep.test.active_farm'),
    current_setting('esheep.test.active_migration')
  ),
  '42501',
  'farm_transition_completion_denied',
  'non-owner cannot complete another farm transition'
);

select * from finish();
rollback;
