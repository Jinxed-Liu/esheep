-- Swift's millisecondsSince1970 encodes fractional milliseconds. The value
-- digest already rounds numeric dates to milliseconds; accept that wire value
-- without changing stored command bytes, integer fields, or authorization.
DO $migration$
DECLARE
  definition text;
  before_text text := $before$when 'date' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'number'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~ '^-?[0-9]+$'$before$;
  after_text text := $after$when 'date' then
                  coalesce(jsonb_typeof(change.value -> 'mutation' -> 'value' -> 'value'), '') = 'number'
                  and coalesce(change.value -> 'mutation' -> 'value' ->> 'value', '') ~ '^-?[0-9]+([.][0-9]+)?$'$after$;
BEGIN
  SELECT pg_get_functiondef('esheep_cloud.validate_command_semantics_v2_legacy(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure) INTO definition;
  IF position(before_text IN definition) = 0 THEN
    RAISE EXCEPTION 'Reviewed date validation predicate changed';
  END IF;
  EXECUTE replace(definition, before_text, after_text);
END;
$migration$;
