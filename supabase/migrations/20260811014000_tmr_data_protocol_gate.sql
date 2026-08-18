alter table public.devices
  add column if not exists tmr_data_protocol_version integer not null default 0
  check (tmr_data_protocol_version >= 0);

create or replace function public.register_device(
  p_device_id uuid,
  p_public_key_jwk jsonb,
  p_display_name text,
  p_tmr_data_protocol_version integer
)
returns table (device_id uuid, registered_at bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_registered_at timestamptz;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_tmr_data_protocol_version < 0 then
    raise exception using errcode = '22023', message = 'invalid_tmr_data_protocol_version';
  end if;

  insert into public.devices (
    device_id,
    user_id,
    public_key_jwk,
    display_name,
    tmr_data_protocol_version,
    status,
    registered_at,
    revoked_at
  )
  values (
    p_device_id,
    v_user_id,
    p_public_key_jwk,
    left(coalesce(p_display_name, ''), 120),
    p_tmr_data_protocol_version,
    'active',
    now(),
    null
  )
  on conflict (device_id) do update
  set
    public_key_jwk = excluded.public_key_jwk,
    display_name = excluded.display_name,
    tmr_data_protocol_version = excluded.tmr_data_protocol_version,
    status = 'active',
    revoked_at = null
  where public.devices.user_id = v_user_id
  returning public.devices.registered_at into v_registered_at;

  if v_registered_at is null then
    raise exception using errcode = '42501', message = 'device_owned_by_another_user';
  end if;

  return query
  select p_device_id, extract(epoch from v_registered_at)::bigint;
end;
$$;

create or replace function public.register_device(
  p_device_id uuid,
  p_public_key_jwk jsonb,
  p_display_name text
)
returns table (device_id uuid, registered_at bigint)
language sql
security definer
set search_path = ''
as $$
  select *
  from public.register_device(
    p_device_id,
    p_public_key_jwk,
    p_display_name,
    0
  );
$$;

revoke all on function public.register_device(uuid, jsonb, text, integer)
  from public, anon;
grant execute on function public.register_device(uuid, jsonb, text, integer)
  to authenticated;
revoke all on function public.register_device(uuid, jsonb, text)
  from public, anon;
grant execute on function public.register_device(uuid, jsonb, text)
  to authenticated;

create or replace function esheep_private.enforce_tmr_data_protocol()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.entity_type like 'tmr%'
     and exists (
       select 1
       from public.devices device
       where device.device_id = new.modified_by_device_id
         and device.tmr_data_protocol_version < 1
     ) then
    raise exception using
      errcode = '55000',
      message = 'tmr_client_upgrade_required';
  end if;
  return new;
end;
$$;

revoke all on function esheep_private.enforce_tmr_data_protocol()
  from public, anon, authenticated;

drop trigger if exists enforce_tmr_data_protocol_before_write
  on public.farm_operations;
create trigger enforce_tmr_data_protocol_before_write
before insert on public.farm_operations
for each row execute function esheep_private.enforce_tmr_data_protocol();
