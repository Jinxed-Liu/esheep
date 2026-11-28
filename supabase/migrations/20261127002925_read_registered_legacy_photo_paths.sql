-- Historical imports can carry any 128-bit asset ID. Permit a member to read
-- its exact registered, verified variant. Writes retain the original ID rules.
create or replace function esheep_cloud.storage_path_is_authorized(
  p_name text,
  p_require_recycle_expired boolean default false,
  p_require_writable_upload boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and split_part(p_name, '/', 2) ~ '^[0-9]+$'
    and split_part(p_name, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and split_part(p_name, '/', 4) ~ '^[0-9a-f]{64}$'
    and split_part(p_name, '/', 5) ~ '^(thumbnail|avatar)\.jpg$|^original\.bin$'
    and esheep_private.is_active_farm_member(
      split_part(p_name, '/', 1)::uuid,
      case when p_require_recycle_expired
        then array['owner']::text[]
        else array['owner', 'administrator', 'worker']::text[]
      end
    )
    and exists (
      select 1
      from esheep_cloud.assets asset
      join esheep_cloud.farm_state state on state.farm_id = asset.farm_id
      where asset.farm_id = split_part(p_name, '/', 1)::uuid
        and asset.farm_generation = split_part(p_name, '/', 2)::integer
        and asset.asset_id = split_part(p_name, '/', 3)::uuid
        and case split_part(p_name, '/', 5)
          when 'thumbnail.jpg' then asset.thumbnail_sha256
          when 'avatar.jpg' then asset.avatar_sha256
          when 'original.bin' then asset.original_sha256
        end = split_part(p_name, '/', 4)
        and (
          split_part(p_name, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          or (
            not p_require_writable_upload and not p_require_recycle_expired
            and case split_part(p_name, '/', 5)
              when 'thumbnail.jpg' then asset.thumbnail_path = p_name and asset.thumbnail_state = 'verified'
              when 'avatar.jpg' then asset.avatar_path = p_name and asset.avatar_state = 'verified'
              when 'original.bin' then asset.original_path = p_name and asset.original_state = 'verified'
            end
          )
        )
        and state.farm_generation = asset.farm_generation
        and case
          when p_require_recycle_expired or p_require_writable_upload
            then state.status = 'active' and not state.write_frozen
          else state.status in ('active', 'read_only')
        end
        and (
          not p_require_writable_upload
          or case split_part(p_name, '/', 5)
            when 'thumbnail.jpg' then asset.thumbnail_state
            when 'avatar.jpg' then asset.avatar_state
            when 'original.bin' then asset.original_state
          end = 'transferring'
        )
        and (not p_require_recycle_expired or asset.recycle_expires_at <= now())
    );
$$;
