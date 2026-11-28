-- Run with psql -X -v ON_ERROR_STOP=1 during the authorized maintenance window.
-- Acquiring all table locks in this transaction drains in-flight commits. A timeout
-- rolls the entire change back so there is no half-frozen source.
BEGIN;
SET LOCAL lock_timeout = '8s';
CREATE SCHEMA esheep_migration_freeze;
REVOKE ALL ON SCHEMA esheep_migration_freeze FROM PUBLIC;
CREATE TABLE esheep_migration_freeze.protected_tables (
    relation regclass PRIMARY KEY
);
CREATE FUNCTION esheep_migration_freeze.reject_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    -- The legacy business RPC converts WHEN OTHERS into a terminal malformed-command
    -- receipt. query_canceled propagates out of that handler; clients keep the original ID.
    RAISE EXCEPTION USING ERRCODE = '57014', MESSAGE = 'eSheep production is in maintenance';
END;
$$;
REVOKE ALL ON FUNCTION esheep_migration_freeze.reject_write() FROM PUBLIC;
DO $freeze$
DECLARE target record;
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role','authenticator','supabase_auth_admin','supabase_storage_admin','postgres')
               AND (rolsuper OR has_parameter_privilege(oid,'session_replication_role','SET'))) THEN
        RAISE EXCEPTION 'A writer could bypass normal triggers; review before freezing';
    END IF;
    FOR target IN SELECT c.oid::regclass AS relation
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname IN ('public','esheep_cloud','esheep_private','private','auth','storage')
                    -- These are platform upgrade history and vector-index administration.
                    -- The farm clients and the four business functions use neither.
                    AND (n.nspname,c.relname) NOT IN (('auth','schema_migrations'),('storage','migrations'),
                        ('storage','buckets_vectors'),('storage','vector_indexes'))
                    AND c.relkind IN ('r','p') AND NOT EXISTS (
                        SELECT FROM pg_depend d WHERE d.classid='pg_class'::regclass
                            AND d.objid=c.oid AND d.deptype='e'
                    )
                  ORDER BY n.nspname,c.relname LOOP
        EXECUTE format('CREATE TRIGGER esheep_cutover_freeze BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION esheep_migration_freeze.reject_write()',target.relation);
        INSERT INTO esheep_migration_freeze.protected_tables VALUES (target.relation);
    END LOOP;
    IF NOT EXISTS (SELECT FROM esheep_migration_freeze.protected_tables WHERE relation='auth.users'::regclass)
       OR NOT EXISTS (SELECT FROM esheep_migration_freeze.protected_tables WHERE relation='storage.objects'::regclass)
       OR NOT EXISTS (SELECT FROM esheep_migration_freeze.protected_tables p JOIN pg_class c ON c.oid=p.relation WHERE c.relnamespace=to_regnamespace('esheep_cloud')) THEN
        RAISE EXCEPTION 'Expected business, Auth and Storage tables are required';
    END IF;
END;
$freeze$;
COMMIT;
SELECT count(*) AS frozen_tables FROM esheep_migration_freeze.protected_tables;
