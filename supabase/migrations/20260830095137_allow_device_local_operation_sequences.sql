-- client_sequence is allocated from a device-local durable counter. It orders
-- one client's pending batch; it is not a farm-wide operation identity. The
-- previous unique index made two independently operating devices collide as
-- soon as they emitted the same local sequence number. operation_id remains
-- the immutable idempotency key and (farm_id, revision) remains the canonical
-- server ordering constraint.
drop index if exists public.farm_operations_client_sequence_idx;

create index farm_operations_device_sequence_idx
  on public.farm_operations (
    farm_id,
    authority_generation,
    modified_by_device_id,
    client_sequence
  )
  where client_sequence > 0;
