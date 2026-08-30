begin;

create extension if not exists pgtap with schema extensions;
select plan(14);

select set_config('esheep.test.consent_user', gen_random_uuid()::text, false);
select set_config('esheep.test.other_user', gen_random_uuid()::text, false);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
values
  (
    current_setting('esheep.test.consent_user')::uuid,
    'authenticated', 'authenticated', 'consent@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.test.other_user')::uuid,
    'authenticated', 'authenticated', 'other-consent@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  );

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.consent_user'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select * from public.record_legal_consent(
    '2026.09.01', '2026.09.01', '2026.09.01', now(), '3.1.0 (1)', 'zh_CN'
  )$$,
  'authenticated user records versioned legal consent'
);

select is(
  (select count(*)::integer from public.legal_consent_receipts),
  1,
  'user can select their own receipt'
);

select lives_ok(
  $$select * from public.record_legal_consent(
    '2026.09.01', '2026.09.01', '2026.09.01', now(), '3.1.0 (2)', 'en_US'
  )$$,
  'recording the same versions is idempotent'
);

select is(
  (select count(*)::integer from public.legal_consent_receipts),
  1,
  'idempotent retry keeps one receipt for the version tuple'
);

select lives_ok(
  $$select * from public.record_legal_consent_withdrawal(
    '2026.09.01', '2026.09.01', '2026.09.01', now(), '3.1.0 (2)', 'zh_CN'
  )$$,
  'authenticated user can record consent withdrawal'
);

select is(
  (select count(*)::integer from public.legal_consent_withdrawal_events),
  1,
  'withdrawal evidence is append-only and separately retained'
);

select throws_ok(
  $$select * from public.record_legal_consent(
    '', '2026.09.01', '2026.09.01', now(), '3.1.0', 'zh_CN'
  )$$,
  '22023',
  'legal_consent_payload_invalid',
  'empty version is rejected'
);

select throws_ok(
  $$select * from public.record_legal_consent(
    '2026.09.01', '2026.09.01', '2026.09.01', now() - interval '31 days', '3.1.0', 'zh_CN'
  )$$,
  '22023',
  'legal_consent_timestamp_invalid',
  'stale device timestamp is rejected'
);

select throws_ok(
  $$insert into public.legal_consent_receipts (
    user_id, terms_version, privacy_version, cross_border_version,
    consented_at, app_version, locale_identifier
  ) values (
    current_setting('esheep.test.consent_user')::uuid,
    'direct', 'direct', 'direct', now(), '3.1.0', 'zh_CN'
  )$$,
  '42501',
  'permission denied for table legal_consent_receipts',
  'authenticated client cannot insert directly'
);

select throws_ok(
  $$insert into public.legal_consent_withdrawal_events (
    user_id, terms_version, privacy_version, cross_border_version,
    occurred_at, app_version, locale_identifier
  ) values (
    current_setting('esheep.test.consent_user')::uuid,
    'direct', 'direct', 'direct', now(), '3.1.0', 'zh_CN'
  )$$,
  '42501',
  'permission denied for table legal_consent_withdrawal_events',
  'authenticated client cannot forge withdrawal events'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.other_user'),
    'role', 'authenticated'
  )::text,
  true
);

select is(
  (select count(*)::integer from public.legal_consent_receipts),
  0,
  'RLS hides another user receipt'
);

select is(
  (select count(*)::integer from public.legal_consent_withdrawal_events),
  0,
  'RLS hides another user withdrawal event'
);

reset role;
delete from auth.users
where id in (
  current_setting('esheep.test.consent_user')::uuid,
  current_setting('esheep.test.other_user')::uuid
);

select is(
  (select count(*)::integer from public.legal_consent_receipts),
  0,
  'receipt is removed when the Auth user is deleted'
);

select is(
  (select count(*)::integer from public.legal_consent_withdrawal_events),
  0,
  'withdrawal event is removed when the Auth user is deleted'
);

select * from finish();
rollback;
