-- Read only the current V2 farm location for an active member. Weather is an
-- external display; it never writes farm facts or grants direct table access.
create function public.esheep_cloud_weather_location_v1(p_farm_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_location jsonb;
begin
  if not esheep_private.is_active_farm_member(
    p_farm_id, array['owner', 'administrator', 'worker']
  ) then
    raise exception using errcode = '42501', message = 'esheep_cloud_farm_read_denied';
  end if;

  select jsonb_build_object(
    'farmID', registry.farm_id,
    'generation', profile.farm_generation,
    'latitude', profile.latitude,
    'longitude', profile.longitude,
    'locationDisplayName', profile.location_display_name,
    'timeZone', profile.time_zone_identifier,
    'locationRevision', profile.updated_at
  ) into v_location
  from public.farm_registry registry
  join esheep_cloud.farm_profiles profile
    on profile.farm_id = registry.farm_id
   and profile.farm_generation = registry.authority_generation
  where registry.farm_id = p_farm_id
    and registry.provider = 'esheep_cloud'
    and registry.status in ('active', 'read_only');

  return v_location;
end;
$$;

revoke all on function public.esheep_cloud_weather_location_v1(uuid) from public, anon;
grant execute on function public.esheep_cloud_weather_location_v1(uuid) to authenticated;
