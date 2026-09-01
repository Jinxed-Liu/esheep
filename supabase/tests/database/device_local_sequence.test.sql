begin;

create extension if not exists pgtap with schema extensions;
select plan(2);

select ok(
  not exists (
    select 1
    from pg_catalog.pg_indexes
    where schemaname = 'public'
      and indexname = 'farm_operations_client_sequence_idx'
  ),
  'device-local sequences are not constrained as farm-wide unique'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_indexes
    where schemaname = 'public'
      and indexname = 'farm_operations_device_sequence_idx'
      and indexdef like '%modified_by_device_id%'
  ),
  'the diagnostic sequence index includes the device identity'
);

select * from finish();
rollback;
