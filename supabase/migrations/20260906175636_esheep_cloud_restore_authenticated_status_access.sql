-- The signed-in app calls this read-only RPC before any sync work.
-- Preserve the existing SECURITY DEFINER membership check and anonymous denial.
SET lock_timeout = '5s';
SET statement_timeout = '30s';
GRANT EXECUTE ON FUNCTION public.esheep_cloud_fetch_status_v2(uuid) TO authenticated;
