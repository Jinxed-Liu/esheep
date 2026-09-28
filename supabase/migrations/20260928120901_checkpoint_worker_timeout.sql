-- The atomic maintenance export seals all streams at one database snapshot.
-- Its timeout is separate from interactive client requests.
alter function public.esheep_cloud_checkpoint_worker_source_v1(text,uuid,integer,bigint,bigint,uuid) set statement_timeout to '120s';
notify pgrst, 'reload schema';
