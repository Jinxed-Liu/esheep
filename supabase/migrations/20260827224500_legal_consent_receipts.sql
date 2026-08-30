-- Versioned, server-timestamped evidence that an authenticated user accepted
-- the legal texts shown by the iOS client. Direct client writes are denied;
-- the RPC derives the subject from auth.uid().

create table if not exists public.legal_consent_receipts (
  receipt_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  terms_version text not null check (
    length(terms_version) between 1 and 64 and
    terms_version ~ '^[0-9A-Za-z._-]+$'
  ),
  privacy_version text not null check (
    length(privacy_version) between 1 and 64 and
    privacy_version ~ '^[0-9A-Za-z._-]+$'
  ),
  cross_border_version text not null check (
    length(cross_border_version) between 1 and 64 and
    cross_border_version ~ '^[0-9A-Za-z._-]+$'
  ),
  consented_at timestamptz not null,
  app_version text not null check (length(app_version) between 1 and 64),
  locale_identifier text not null check (length(locale_identifier) between 1 and 64),
  first_recorded_at timestamptz not null default clock_timestamp(),
  last_recorded_at timestamptz not null default clock_timestamp(),
  unique (user_id, terms_version, privacy_version, cross_border_version)
);

alter table public.legal_consent_receipts enable row level security;
alter table public.legal_consent_receipts force row level security;

drop policy if exists legal_consent_receipts_select_self
  on public.legal_consent_receipts;
create policy legal_consent_receipts_select_self
  on public.legal_consent_receipts
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.legal_consent_receipts
  from public, anon, authenticated;
grant select on table public.legal_consent_receipts to authenticated;

create or replace function public.record_legal_consent(
  p_terms_version text,
  p_privacy_version text,
  p_cross_border_version text,
  p_consented_at timestamptz,
  p_app_version text,
  p_locale_identifier text
)
returns table (
  receipt_id uuid,
  recorded_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_receipt public.legal_consent_receipts%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  if p_terms_version is null or length(p_terms_version) not between 1 and 64
     or p_terms_version !~ '^[0-9A-Za-z._-]+$'
     or p_privacy_version is null or length(p_privacy_version) not between 1 and 64
     or p_privacy_version !~ '^[0-9A-Za-z._-]+$'
     or p_cross_border_version is null or length(p_cross_border_version) not between 1 and 64
     or p_cross_border_version !~ '^[0-9A-Za-z._-]+$'
     or p_app_version is null or length(p_app_version) not between 1 and 64
     or p_locale_identifier is null or length(p_locale_identifier) not between 1 and 64
  then
    raise exception using errcode = '22023', message = 'legal_consent_payload_invalid';
  end if;

  if p_consented_at is null
     or p_consented_at < clock_timestamp() - interval '30 days'
     or p_consented_at > clock_timestamp() + interval '1 day'
  then
    raise exception using errcode = '22023', message = 'legal_consent_timestamp_invalid';
  end if;

  insert into public.legal_consent_receipts (
    user_id,
    terms_version,
    privacy_version,
    cross_border_version,
    consented_at,
    app_version,
    locale_identifier
  ) values (
    v_user_id,
    p_terms_version,
    p_privacy_version,
    p_cross_border_version,
    p_consented_at,
    p_app_version,
    p_locale_identifier
  )
  on conflict (user_id, terms_version, privacy_version, cross_border_version)
  do update set
    consented_at = excluded.consented_at,
    app_version = excluded.app_version,
    locale_identifier = excluded.locale_identifier,
    last_recorded_at = clock_timestamp()
  returning * into v_receipt;

  return query select v_receipt.receipt_id, v_receipt.last_recorded_at;
end;
$$;

revoke all on function public.record_legal_consent(
  text, text, text, timestamptz, text, text
) from public, anon, authenticated;
grant execute on function public.record_legal_consent(
  text, text, text, timestamptz, text, text
) to authenticated;

comment on table public.legal_consent_receipts is
  'Versioned legal acceptance evidence; client writes only through record_legal_consent.';

create table if not exists public.legal_consent_withdrawal_events (
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  terms_version text not null check (
    length(terms_version) between 1 and 64 and
    terms_version ~ '^[0-9A-Za-z._-]+$'
  ),
  privacy_version text not null check (
    length(privacy_version) between 1 and 64 and
    privacy_version ~ '^[0-9A-Za-z._-]+$'
  ),
  cross_border_version text not null check (
    length(cross_border_version) between 1 and 64 and
    cross_border_version ~ '^[0-9A-Za-z._-]+$'
  ),
  occurred_at timestamptz not null,
  app_version text not null check (length(app_version) between 1 and 64),
  locale_identifier text not null check (length(locale_identifier) between 1 and 64),
  recorded_at timestamptz not null default clock_timestamp()
);

alter table public.legal_consent_withdrawal_events enable row level security;
alter table public.legal_consent_withdrawal_events force row level security;

drop policy if exists legal_consent_withdrawal_events_select_self
  on public.legal_consent_withdrawal_events;
create policy legal_consent_withdrawal_events_select_self
  on public.legal_consent_withdrawal_events
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.legal_consent_withdrawal_events
  from public, anon, authenticated;
grant select on table public.legal_consent_withdrawal_events to authenticated;

create or replace function public.record_legal_consent_withdrawal(
  p_terms_version text,
  p_privacy_version text,
  p_cross_border_version text,
  p_occurred_at timestamptz,
  p_app_version text,
  p_locale_identifier text
)
returns table (
  event_id uuid,
  recorded_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_event public.legal_consent_withdrawal_events%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  if p_terms_version is null or length(p_terms_version) not between 1 and 64
     or p_terms_version !~ '^[0-9A-Za-z._-]+$'
     or p_privacy_version is null or length(p_privacy_version) not between 1 and 64
     or p_privacy_version !~ '^[0-9A-Za-z._-]+$'
     or p_cross_border_version is null or length(p_cross_border_version) not between 1 and 64
     or p_cross_border_version !~ '^[0-9A-Za-z._-]+$'
     or p_app_version is null or length(p_app_version) not between 1 and 64
     or p_locale_identifier is null or length(p_locale_identifier) not between 1 and 64
  then
    raise exception using errcode = '22023', message = 'legal_consent_withdrawal_payload_invalid';
  end if;

  if p_occurred_at is null
     or p_occurred_at < clock_timestamp() - interval '30 days'
     or p_occurred_at > clock_timestamp() + interval '1 day'
  then
    raise exception using errcode = '22023', message = 'legal_consent_withdrawal_timestamp_invalid';
  end if;

  insert into public.legal_consent_withdrawal_events (
    user_id,
    terms_version,
    privacy_version,
    cross_border_version,
    occurred_at,
    app_version,
    locale_identifier
  ) values (
    v_user_id,
    p_terms_version,
    p_privacy_version,
    p_cross_border_version,
    p_occurred_at,
    p_app_version,
    p_locale_identifier
  )
  returning * into v_event;

  return query select v_event.event_id, v_event.recorded_at;
end;
$$;

revoke all on function public.record_legal_consent_withdrawal(
  text, text, text, timestamptz, text, text
) from public, anon, authenticated;
grant execute on function public.record_legal_consent_withdrawal(
  text, text, text, timestamptz, text, text
) to authenticated;

comment on table public.legal_consent_withdrawal_events is
  'Append-only evidence that a user withdrew the current legal and cross-border consent.';

create table if not exists public.ai_privacy_consent_events (
  event_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  version text not null check (
    length(version) between 1 and 64 and version ~ '^[0-9A-Za-z._-]+$'
  ),
  action text not null check (action in ('accepted', 'withdrawn')),
  occurred_at timestamptz not null,
  app_version text not null check (length(app_version) between 1 and 64),
  locale_identifier text not null check (length(locale_identifier) between 1 and 64),
  recorded_at timestamptz not null default clock_timestamp()
);

alter table public.ai_privacy_consent_events enable row level security;
alter table public.ai_privacy_consent_events force row level security;

drop policy if exists ai_privacy_consent_events_select_self
  on public.ai_privacy_consent_events;
create policy ai_privacy_consent_events_select_self
  on public.ai_privacy_consent_events
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.ai_privacy_consent_events
  from public, anon, authenticated;
grant select on table public.ai_privacy_consent_events to authenticated;

create or replace function public.record_ai_privacy_consent(
  p_version text,
  p_action text,
  p_occurred_at timestamptz,
  p_app_version text,
  p_locale_identifier text
)
returns table (
  event_id uuid,
  recorded_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_event public.ai_privacy_consent_events%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  if p_version is null or length(p_version) not between 1 and 64
     or p_version !~ '^[0-9A-Za-z._-]+$'
     or p_action is null or p_action not in ('accepted', 'withdrawn')
     or p_app_version is null or length(p_app_version) not between 1 and 64
     or p_locale_identifier is null or length(p_locale_identifier) not between 1 and 64
  then
    raise exception using errcode = '22023', message = 'ai_privacy_consent_payload_invalid';
  end if;

  if p_occurred_at is null
     or p_occurred_at < clock_timestamp() - interval '30 days'
     or p_occurred_at > clock_timestamp() + interval '1 day'
  then
    raise exception using errcode = '22023', message = 'ai_privacy_consent_timestamp_invalid';
  end if;

  insert into public.ai_privacy_consent_events (
    user_id, version, action, occurred_at, app_version, locale_identifier
  ) values (
    v_user_id, p_version, p_action, p_occurred_at, p_app_version, p_locale_identifier
  )
  returning * into v_event;

  return query select v_event.event_id, v_event.recorded_at;
end;
$$;

revoke all on function public.record_ai_privacy_consent(
  text, text, timestamptz, text, text
) from public, anon, authenticated;
grant execute on function public.record_ai_privacy_consent(
  text, text, timestamptz, text, text
) to authenticated;

comment on table public.ai_privacy_consent_events is
  'Append-only acceptance and withdrawal evidence for optional MiMo AI processing.';
