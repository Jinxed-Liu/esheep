-- Deployed Development diagnostics. The RPC never returns a farm name,
-- entity payload, operation payload, storage path or member identity.
create or replace function public.get_farm_storage_metrics(
  p_farm_id uuid
)
returns table (
  farm_id uuid,
  authority_generation integer,
  current_revision bigint,
  entity_count bigint,
  operation_count bigint,
  tombstone_count bigint,
  registered_asset_count bigint,
  registered_asset_bytes bigint,
  duplicate_asset_sha_count bigint,
  checkpoint_count bigint,
  checkpoint_archive_bytes bigint,
  logical_payload_bytes bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'authentication_required'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.farm_members member
    where member.farm_id = p_farm_id
      and member.user_id = v_user_id
      and member.status = 'active'
  ) then
    raise exception 'farm_access_denied'
      using errcode = '42501';
  end if;

  return query
  select
    registry.farm_id,
    registry.authority_generation,
    registry.current_revision,
    (
      select count(*)
      from public.farm_entities entity
      where entity.farm_id = p_farm_id
    ),
    (
      select count(*)
      from public.farm_operations operation
      where operation.farm_id = p_farm_id
        and operation.is_staged = false
    ),
    (
      select count(*)
      from public.farm_tombstones tombstone
      where tombstone.farm_id = p_farm_id
    ),
    (
      select count(*)
      from public.farm_assets asset
      where asset.farm_id = p_farm_id
        and asset.deleted_at is null
    ),
    (
      select coalesce(sum(asset.byte_count), 0)::bigint
      from public.farm_assets asset
      where asset.farm_id = p_farm_id
        and asset.deleted_at is null
    ),
    (
      select count(*)
      from (
        select asset.sha256
        from public.farm_assets asset
        where asset.farm_id = p_farm_id
          and asset.deleted_at is null
        group by asset.sha256
        having count(*) > 1
      ) duplicate_sha
    ),
    (
      select count(*)
      from public.farm_checkpoints checkpoint
      where checkpoint.farm_id = p_farm_id
        and checkpoint.verified_at is not null
    ),
    (
      select coalesce(
        sum(coalesce(checkpoint.archive_byte_count, 0)),
        0
      )::bigint
      from public.farm_checkpoints checkpoint
      where checkpoint.farm_id = p_farm_id
        and checkpoint.verified_at is not null
    ),
    (
      coalesce(
        (
          select sum(
            coalesce(pg_column_size(entity.payload_json), 0) +
            coalesce(octet_length(entity.payload_base64), 0)
          )
          from public.farm_entities entity
          where entity.farm_id = p_farm_id
        ),
        0
      ) +
      coalesce(
        (
          select sum(octet_length(operation.payload_base64))
          from public.farm_operations operation
          where operation.farm_id = p_farm_id
            and operation.is_staged = false
        ),
        0
      )
    )::bigint
  from public.farm_registry registry
  where registry.farm_id = p_farm_id
    and registry.provider = 'supabase';
end;
$$;

revoke all on function public.get_farm_storage_metrics(uuid)
  from public, anon, authenticated;
grant execute on function public.get_farm_storage_metrics(uuid)
  to authenticated;

comment on function public.get_farm_storage_metrics(uuid) is
  'Member-scoped aggregate storage diagnostics without business payloads.';
