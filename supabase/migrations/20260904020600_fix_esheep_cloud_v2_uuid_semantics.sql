-- SwiftData UUID values are 128-bit identifiers, but UUID does not require
-- the RFC 4122 version/variant bits to be set. The original V2 validator used
-- the narrower RFC pattern for transport shape checks and therefore rejected
-- real Air entity IDs. Normalize only a private validation copy; all command,
-- stream, payload and asset rows continue to use the original UUID bytes.
create or replace function esheep_cloud.contract_uuid_v2(p_value text)
returns text
language plpgsql
immutable
strict
security invoker
set search_path = ''
as $$
declare
  v_hex text;
begin
  if p_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    return lower(p_value);
  end if;
  if p_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return p_value;
  end if;
  v_hex := replace(lower(p_value), '-', '');
  return substr(v_hex, 1, 8) || '-' || substr(v_hex, 9, 4) || '-' ||
    '4' || substr(v_hex, 14, 3) || '-' || '8' || substr(v_hex, 18, 3) ||
    '-' || substr(v_hex, 21, 12);
end;
$$;

create or replace function esheep_cloud.normalize_contract_json_v2(p_value jsonb)
returns jsonb
language plpgsql
immutable
strict
security invoker
set search_path = ''
as $$
declare
  v_type text := jsonb_typeof(p_value);
  v_result jsonb;
begin
  case v_type
    when 'object' then
      select coalesce(jsonb_object_agg(item.key, esheep_cloud.normalize_contract_json_v2(item.value)), '{}'::jsonb)
      into v_result
      from jsonb_each(p_value) item;
    when 'array' then
      select coalesce(jsonb_agg(esheep_cloud.normalize_contract_json_v2(item.value) order by item.ordinality), '[]'::jsonb)
      into v_result
      from jsonb_array_elements(p_value) with ordinality item(value, ordinality);
    when 'string' then
      v_result := to_jsonb(esheep_cloud.contract_uuid_v2(p_value #>> '{}'));
    else
      v_result := p_value;
  end case;
  return v_result;
end;
$$;

create or replace function esheep_cloud.validate_command_semantics_v2(
  p_kind text,
  p_payload jsonb,
  p_merge_mode text,
  p_affected_streams jsonb,
  p_affected_fields jsonb,
  p_field_changes jsonb
)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_payload jsonb := esheep_cloud.normalize_contract_json_v2(p_payload);
  v_streams jsonb := esheep_cloud.normalize_contract_json_v2(p_affected_streams);
  v_fields jsonb := esheep_cloud.normalize_contract_json_v2(p_affected_fields);
  v_field_changes jsonb;
begin
  if p_kind = 'farm.updateLocation' then
    v_payload := jsonb_build_object(
      'kind', p_kind,
      'body', jsonb_build_object(
        'updateLocation', v_payload #> '{body,action,updateLocation}'
      )
    );
  end if;

  select coalesce(jsonb_agg(
    case
      when item.value #>> '{mutation,value,type}' = 'decimal' then
        jsonb_set(item.value, '{mutation,value,type}', '"string"'::jsonb)
      else item.value
    end
    order by item.ordinality
  ), '[]'::jsonb)
  into v_field_changes
  from jsonb_array_elements(coalesce(p_field_changes, '[]'::jsonb))
    with ordinality item(value, ordinality);
  v_field_changes := esheep_cloud.normalize_contract_json_v2(v_field_changes);

  perform esheep_cloud.validate_command_semantics_v2_legacy(
    p_kind,
    v_payload,
    p_merge_mode,
    v_streams,
    v_fields,
    v_field_changes
  );
end;
$$;
