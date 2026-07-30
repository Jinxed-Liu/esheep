-- Opt this existing Development project into the least-privilege Data API
-- model. RLS is not a substitute for object privileges: whole-table
-- operations such as TRUNCATE and REFERENCES are outside RLS.

revoke all privileges on all tables in schema public
  from public, anon, authenticated;
revoke all privileges on all sequences in schema public
  from public, anon, authenticated;
revoke execute on all functions in schema public
  from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all privileges on tables from public, anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all privileges on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

-- The iOS client reads projections directly under RLS. All business writes
-- continue to cross a transaction RPC boundary.
grant select on table
  public.profiles,
  public.devices,
  public.farm_registry,
  public.farm_members,
  public.farm_invites,
  public.farm_operations,
  public.farm_entities,
  public.farm_tombstones,
  public.farm_assets,
  public.farm_checkpoints,
  public.authority_transitions,
  public.entitlements,
  public.account_deletion_requests
to authenticated;

grant update (display_name, updated_at)
  on table public.profiles
  to authenticated;

grant execute on function public.register_device(uuid, jsonb, text)
  to authenticated;
grant execute on function public.claim_legacy_account(text)
  to authenticated;
grant execute on function public.request_account_deletion()
  to authenticated;
grant execute on function public.register_farm_authority(uuid, text, jsonb)
  to authenticated;
grant execute on function public.activate_farm_authority(uuid, integer, bigint, text)
  to authenticated;
grant execute on function public.deactivate_farm_authority(uuid, integer, boolean)
  to authenticated;
grant execute on function public.apply_farm_operation(
  uuid, uuid, integer, text, uuid, integer, integer, integer, text, text,
  uuid, uuid, text, text, timestamptz, timestamptz, timestamptz
) to authenticated;
grant execute on function public.register_farm_asset(
  uuid, uuid, integer, text, text, bigint, text
) to authenticated;
grant execute on function public.begin_farm_authority_transition(
  uuid, uuid, text, integer, bigint, text
) to authenticated;
grant execute on function public.register_farm_checkpoint(
  uuid, uuid, uuid, integer, bigint, jsonb, text, text,
  bigint, bigint, bigint, bigint
) to authenticated;
grant execute on function public.verify_and_activate_farm_authority(
  uuid, uuid, uuid, integer, text
) to authenticated;
grant execute on function public.apply_farm_operations_batch(
  uuid, integer, jsonb
) to authenticated;
grant execute on function public.stage_farm_operations_batch(
  uuid, uuid, integer, jsonb
) to authenticated;
grant execute on function public.create_farm_invite(
  uuid, text, text, timestamptz
) to authenticated;
grant execute on function public.redeem_farm_invite(text)
  to authenticated;
grant execute on function public.revoke_farm_member(uuid, uuid)
  to authenticated;

-- Display names are presentation-only metadata. They are copied once during
-- Auth user creation, sanitized and capped, and are never consulted by RLS or
-- an authorization RPC.
create or replace function esheep_private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  v_display_name := nullif(
    left(
      regexp_replace(
        btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')),
        '[[:cntrl:]]',
        '',
        'g'
      ),
      120
    ),
    ''
  );

  insert into public.profiles (user_id, app_account_id, display_name)
  values (new.id, new.id, v_display_name)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function esheep_private.handle_new_auth_user()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
