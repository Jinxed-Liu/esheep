begin;

create extension if not exists pgtap with schema extensions;
select plan(8);

select set_config('esheep.test.ai_consent_user', gen_random_uuid()::text, false);
select set_config('esheep.test.ai_consent_other', gen_random_uuid()::text, false);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
values
  (
    current_setting('esheep.test.ai_consent_user')::uuid,
    'authenticated', 'authenticated', 'ai-consent@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  ),
  (
    current_setting('esheep.test.ai_consent_other')::uuid,
    'authenticated', 'authenticated', 'ai-consent-other@example.invalid',
    crypt('not-a-real-user-password', gen_salt('bf')), now()
  );

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.ai_consent_user'),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select * from public.record_ai_privacy_consent(
    '2026.09.01', 'accepted', now(), '3.1.0 (1)', 'zh_CN'
  )$$,
  'user can accept optional AI processing'
);

select lives_ok(
  $$select * from public.record_ai_privacy_consent(
    '2026.09.01', 'withdrawn', now(), '3.1.0 (1)', 'zh_CN'
  )$$,
  'user can record withdrawal'
);

select is(
  (select count(*)::integer from public.ai_privacy_consent_events),
  2,
  'acceptance and withdrawal remain append-only evidence'
);

select throws_ok(
  $$select * from public.record_ai_privacy_consent(
    '2026.09.01', 'invalid', now(), '3.1.0', 'zh_CN'
  )$$,
  '22023',
  'ai_privacy_consent_payload_invalid',
  'invalid action is rejected'
);

select throws_ok(
  $$select * from public.record_ai_privacy_consent(
    '2026.09.01', 'accepted', now() + interval '2 days', '3.1.0', 'zh_CN'
  )$$,
  '22023',
  'ai_privacy_consent_timestamp_invalid',
  'future timestamp is rejected'
);

select throws_ok(
  $$insert into public.ai_privacy_consent_events (
    user_id, version, action, occurred_at, app_version, locale_identifier
  ) values (
    current_setting('esheep.test.ai_consent_user')::uuid,
    'direct', 'accepted', now(), '3.1.0', 'zh_CN'
  )$$,
  '42501',
  'permission denied for table ai_privacy_consent_events',
  'direct authenticated insert is denied'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', current_setting('esheep.test.ai_consent_other'),
    'role', 'authenticated'
  )::text,
  true
);
select is(
  (select count(*)::integer from public.ai_privacy_consent_events),
  0,
  'RLS hides another user AI consent events'
);

reset role;
delete from auth.users
where id in (
  current_setting('esheep.test.ai_consent_user')::uuid,
  current_setting('esheep.test.ai_consent_other')::uuid
);

select is(
  (select count(*)::integer from public.ai_privacy_consent_events),
  0,
  'AI consent events cascade on Auth deletion'
);

select * from finish();
rollback;

