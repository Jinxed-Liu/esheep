-- Returns the caller's active Supabase farm memberships without bypassing
-- table RLS. This intentionally remains SECURITY INVOKER: a revoked user sees
-- no row as soon as farm_members.status changes.
create or replace function public.list_my_active_farm_access()
returns table (
  farm_id uuid,
  owner_user_id uuid,
  owner_app_account_id uuid,
  member_user_id uuid,
  member_app_account_id uuid,
  member_role text,
  provider text,
  farm_status text,
  authority_generation integer,
  current_revision bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    registry.farm_id,
    registry.owner_user_id,
    owner_member.app_account_id as owner_app_account_id,
    member.user_id as member_user_id,
    member.app_account_id as member_app_account_id,
    member.role as member_role,
    registry.provider,
    registry.status as farm_status,
    registry.authority_generation,
    registry.current_revision
  from public.farm_members member
  join public.farm_registry registry
    on registry.farm_id = member.farm_id
  join public.farm_members owner_member
    on owner_member.farm_id = registry.farm_id
   and owner_member.user_id = registry.owner_user_id
   and owner_member.role = 'owner'
   and owner_member.status = 'active'
  where member.user_id = (select auth.uid())
    and member.status = 'active'
    and registry.provider = 'supabase'
    and registry.status in ('active', 'read_only')
  order by registry.created_at, registry.farm_id;
$$;

revoke all on function public.list_my_active_farm_access()
  from public, anon;
grant execute on function public.list_my_active_farm_access()
  to authenticated;

comment on function public.list_my_active_farm_access() is
  'RLS-bound active farm access snapshot for the current authenticated user.';
