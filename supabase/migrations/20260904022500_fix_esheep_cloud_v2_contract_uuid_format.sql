-- Keep the validation-only UUID bridge in canonical hyphenated form. The
-- previous bridge preserved all hex digits but omitted UUID separators.
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
