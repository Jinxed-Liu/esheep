-- CREATE OR REPLACE triggers the public API exposure guard. Explicitly restore
-- the signed-in read RPC grants after the farm identity migration's DDL.
SET lock_timeout = '5s';
SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION public.esheep_cloud_list_my_farms_v2() TO authenticated;
GRANT EXECUTE ON FUNCTION public.esheep_cloud_fetch_status_v2(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.esheep_cloud_pull_events_v2(uuid,integer,bigint,integer) TO authenticated;
