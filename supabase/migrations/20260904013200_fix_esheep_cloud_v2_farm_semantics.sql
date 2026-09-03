-- The farm payload intentionally wraps updateLocation inside `body.action`.
-- The first V2 validator handled that shape, but the semantic validator used
-- the unwrapped lookup and rejected every farm.updateLocation command before
-- the ledger could be touched. Keep the original validator as a private
-- implementation and normalize only this one typed envelope at its boundary.
alter function esheep_cloud.validate_command_semantics_v2(
  text, jsonb, text, jsonb, jsonb, jsonb
) rename to validate_command_semantics_v2_legacy;

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
begin
  if p_kind = 'farm.updateLocation' then
    v_payload := jsonb_build_object(
      'kind', p_kind,
      'body', jsonb_build_object(
        'updateLocation', p_payload #> '{body,action,updateLocation}'
      )
    );
  end if;
  perform esheep_cloud.validate_command_semantics_v2_legacy(
    p_kind,
    v_payload,
    p_merge_mode,
    p_affected_streams,
    p_affected_fields,
    p_field_changes
  );
end;
$$;
