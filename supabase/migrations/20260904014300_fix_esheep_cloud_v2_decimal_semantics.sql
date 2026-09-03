-- The deployed legacy semantic validator has a double-escaped decimal regex.
-- Normalize only its validation copy of decimal mutations to the already
-- accepted string codec. The original field_changes are still passed to the
-- command processor, so decimal value digests and persisted field values keep
-- their declared `decimal` type.
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
  v_payload jsonb := p_payload;
  v_field_changes jsonb;
begin
  if p_kind = 'farm.updateLocation' then
    v_payload := jsonb_build_object(
      'kind', p_kind,
      'body', jsonb_build_object(
        'updateLocation', p_payload #> '{body,action,updateLocation}'
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

  perform esheep_cloud.validate_command_semantics_v2_legacy(
    p_kind,
    v_payload,
    p_merge_mode,
    p_affected_streams,
    p_affected_fields,
    v_field_changes
  );
end;
$$;
