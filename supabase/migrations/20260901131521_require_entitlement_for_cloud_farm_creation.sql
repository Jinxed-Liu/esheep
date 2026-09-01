-- Cloud-farm creation is a paid owner capability. Keep invitation redemption
-- available to free accounts by gating only new farm_registry rows.
create or replace function esheep_private.enforce_cloud_farm_creation_entitlement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.entitlements entitlement
    where entitlement.owner_user_id = new.owner_user_id
      and entitlement.state in ('active', 'grace_period', 'billing_retry')
      and (
        entitlement.valid_until is null
        or entitlement.valid_until > now()
        or entitlement.grace_until > now()
      )
  ) then
    raise exception using errcode = '42501', message = 'cloud_farm_entitlement_required';
  end if;
  return new;
end;
$$;

revoke all on function esheep_private.enforce_cloud_farm_creation_entitlement()
  from public, anon, authenticated;

drop trigger if exists require_cloud_farm_creation_entitlement on public.farm_registry;
create trigger require_cloud_farm_creation_entitlement
before insert on public.farm_registry
for each row execute function esheep_private.enforce_cloud_farm_creation_entitlement();

comment on function esheep_private.enforce_cloud_farm_creation_entitlement() is
  'Rejects creation of a cloud farm unless its owner has a currently writable entitlement; invited members do not pass through this gate.';
