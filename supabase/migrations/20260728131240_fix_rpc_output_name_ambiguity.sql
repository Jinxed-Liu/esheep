-- The RETURNS TABLE output name `farm_id` is also a PL/pgSQL variable.
-- Prefer the table column in unqualified ON CONFLICT targets.
create or replace function public.register_farm_authority(
  p_farm_id uuid,
  p_provider text,
  p_cloud_locator jsonb default null
)
returns table (farm_id uuid, authority_generation integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_existing public.farm_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_provider not in ('icloud', 'supabase') then
    raise exception using errcode = '22023', message = 'invalid_farm_provider';
  end if;

  select profile.app_account_id
  into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  if v_account_id is null then
    raise exception using errcode = '23503', message = 'profile_missing';
  end if;

  select *
  into v_existing
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
  for update;

  if found then
    if v_existing.owner_user_id <> v_user_id
      or v_existing.provider <> p_provider
    then
      raise exception using errcode = '42501', message = 'farm_authority_already_registered';
    end if;
  else
    insert into public.farm_registry (
      farm_id,
      owner_user_id,
      provider,
      status,
      authority_generation,
      cloud_locator
    )
    values (
      p_farm_id,
      v_user_id,
      p_provider,
      'preparing',
      0,
      case when p_provider = 'icloud' then p_cloud_locator else null end
    )
    returning * into v_existing;
  end if;

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by
  )
  values (
    p_farm_id,
    v_user_id,
    v_account_id,
    'owner',
    'active',
    v_user_id
  )
  on conflict (farm_id, user_id) do update
  set role = 'owner', status = 'active', updated_at = now()
  where public.farm_members.user_id = v_user_id;

  return query select p_farm_id, v_existing.authority_generation;
end;
$$;

revoke all on function public.register_farm_authority(uuid, text, jsonb)
  from public, anon;
grant execute on function public.register_farm_authority(uuid, text, jsonb)
  to authenticated;

create or replace function public.redeem_farm_invite(
  p_code text
)
returns table (
  farm_id uuid,
  role text,
  authority_generation integer
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user_id uuid := (select auth.uid());
  v_account_id uuid;
  v_invite public.farm_invites%rowtype;
  v_registry public.farm_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;

  select profile.app_account_id
  into v_account_id
  from public.profiles profile
  where profile.user_id = v_user_id;

  select *
  into v_invite
  from public.farm_invites invite
  where invite.code_digest = extensions.digest(p_code, 'sha256')
  for update;

  if not found
    or v_invite.status <> 'pending'
    or v_invite.expires_at <= now()
  then
    raise exception using errcode = '22023', message = 'farm_invite_invalid_or_expired';
  end if;

  select *
  into v_registry
  from public.farm_registry registry
  where registry.farm_id = v_invite.farm_id
    and registry.status in ('active', 'read_only');

  if not found then
    raise exception using errcode = '55000', message = 'farm_authority_not_available';
  end if;

  insert into public.farm_members (
    farm_id,
    user_id,
    app_account_id,
    role,
    status,
    invited_by
  )
  values (
    v_invite.farm_id,
    v_user_id,
    v_account_id,
    v_invite.role,
    'active',
    v_invite.invited_by
  )
  on conflict (farm_id, user_id) do update
  set role = excluded.role, status = 'active', updated_at = now();

  update public.farm_invites
  set status = 'redeemed',
      redeemed_by = v_user_id,
      redeemed_at = now()
  where invite_id = v_invite.invite_id;

  return query
  select v_registry.farm_id, v_invite.role, v_registry.authority_generation;
end;
$$;

revoke all on function public.redeem_farm_invite(text) from public, anon;
grant execute on function public.redeem_farm_invite(text) to authenticated;
