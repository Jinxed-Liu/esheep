-- Fractional Swift dates pass; integer and date-type constraints remain strict.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(1);
SELECT lives_ok($assertion$
DO $test$
DECLARE
  stream jsonb := '{"type":"sheepProfile","id":"00000000-0000-4000-8000-000000000001"}';
  payload jsonb;
  streams jsonb;
  fields jsonb;
  changes jsonb := '[{"field":"parityRecordedAt","mutation":{"action":"set","value":{"type":"date","value":1789144623630.991}}}]';
  invalid jsonb;
  rejected boolean;
BEGIN
  streams := jsonb_build_array(stream);
  fields := jsonb_build_array(jsonb_build_object(
    'stream', stream, 'field', 'parityRecordedAt', 'observedVersion', 0,
    'baseValueDigest', repeat('0', 64)
  ));
  payload := jsonb_build_object('kind', 'sheep.patchProfile', 'body',
    jsonb_build_object('patchProfile', jsonb_build_object(
      'sheepID', stream ->> 'id', 'fields', changes
    )));
  PERFORM esheep_cloud.validate_command_semantics_v2('sheep.patchProfile', payload, 'field_patch', streams, fields, changes);
  IF esheep_cloud.value_digest('{"type":"date","value":1789144623630.991}'::jsonb) <> esheep_cloud.value_digest('{"type":"date","value":1789144623631}'::jsonb) THEN
    RAISE EXCEPTION 'Fractional date digest differs from rounded millisecond';
  END IF;
  FOREACH invalid IN ARRAY ARRAY[
    '{"field":"parityRecordedAt","mutation":{"action":"set","value":{"type":"date","value":"1789144623630.991"}}}'::jsonb,
    '{"field":"parityRecordedAt","mutation":{"action":"set","value":{"type":"integer","value":1.5}}}'::jsonb
  ] LOOP
    rejected := false;
    BEGIN
      PERFORM esheep_cloud.validate_command_semantics_v2('sheep.patchProfile', payload, 'field_patch', streams, fields,
        (SELECT jsonb_agg(CASE WHEN item ->> 'field' = 'parityRecordedAt' THEN invalid ELSE item END) FROM jsonb_array_elements(changes) item));
    EXCEPTION WHEN SQLSTATE '22023' THEN
      rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Invalid date/integer unexpectedly accepted'; END IF;
  END LOOP;
END;
$test$;
$assertion$, 'Fractional Swift dates pass without weakening integer/date type validation');
SELECT * FROM finish();
ROLLBACK;
