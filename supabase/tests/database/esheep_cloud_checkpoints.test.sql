begin;
create extension if not exists pgtap with schema extensions;
select plan(13);
select has_table('esheep_cloud','business_checkpoints','checkpoint metadata exists');
select ok(not has_table_privilege('anon','esheep_cloud.business_checkpoints','SELECT'),'anonymous callers cannot read checkpoint metadata');
select ok(not has_table_privilege('authenticated','esheep_cloud.business_checkpoints','SELECT'),'members must use the scoped read RPC');
select ok(not has_function_privilege('authenticated','public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text)','EXECUTE'),'members cannot publish checkpoints');
select ok(has_function_privilege('service_role','public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text)','EXECUTE'),'protected publisher can publish');
select ok(has_function_privilege('authenticated','public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid)','EXECUTE'),'members may invoke the authorization gate');
select ok(not has_function_privilege('anon','public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid)','EXECUTE'),'anonymous manifest RPC is revoked');
select is((select public from storage.buckets where id='esheep-cloud-checkpoints'),false,'checkpoint bucket stays private');
select throws_ok($$select public.esheep_cloud_checkpoint_manifest_v1(gen_random_uuid(),3,null)$$,
 '42501','checkpoint_read_denied','missing member rejected before lookup');
select throws_ok($$select public.esheep_cloud_command_audit_v1(gen_random_uuid(),array[gen_random_uuid()])$$,
 '42501','command_audit_denied','audit details require current membership');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_v1('{}'::jsonb,repeat('a',64),repeat('b',64))$$,
 '22023','checkpoint_invalid_manifest','missing manifest keys cannot publish');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_v1(null,null,null)$$,
 '22023','checkpoint_invalid_manifest','null publication fails closed');
select ok(has_column_privilege('service_role','public.devices','public_key_jwk','SELECT'),'edge verifier can read the registered device public key');
select * from finish();
rollback;
