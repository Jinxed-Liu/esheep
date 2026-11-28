-- Use only after the cutover owner has reconciled changes and selected this as the sole writer.
BEGIN;
SET LOCAL lock_timeout = '8s';
DO $thaw$
BEGIN
    -- Hosted postgres can create a trigger with the TRIGGER grant, but it does
    -- not own managed Auth and Storage tables. Dropping our own function removes
    -- its dependent triggers. Reject any dependency outside our recorded set.
    IF EXISTS (
        SELECT FROM pg_depend d LEFT JOIN pg_trigger t ON d.classid='pg_trigger'::regclass AND d.objid=t.oid
        WHERE d.refclassid='pg_proc'::regclass AND d.refobjid='esheep_migration_freeze.reject_write()'::regprocedure
          AND (t.oid IS NULL OR t.tgname <> 'esheep_cutover_freeze'
               OR NOT EXISTS (SELECT FROM esheep_migration_freeze.protected_tables p WHERE p.relation=t.tgrelid))
    ) THEN RAISE EXCEPTION 'Unexpected dependencies on the write guard'; END IF;
END;
$thaw$;
DROP FUNCTION esheep_migration_freeze.reject_write() CASCADE;
DROP TABLE esheep_migration_freeze.protected_tables;
DROP SCHEMA esheep_migration_freeze;
COMMIT;
