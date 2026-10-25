begin;
create extension if not exists pgtap with schema extensions;
select plan(6);
create function pg_temp.reproduction_manifest(capability jsonb) returns jsonb language sql as $$
 select jsonb_build_object('checkpointID','a1111111-1111-4111-8111-111111111111',
 'farmID','a2222222-2222-4222-8222-222222222222','farmGeneration',3,'boundaryEventSequence',0,
 'boundaryEventDigest',repeat('0',64),'formatVersion',1,'minimumClientCapability',capability,
 'chunks',jsonb_build_array(jsonb_build_object('index',0)),'modelCounts','{}'::jsonb,
 'businessDigest',repeat('c',64),'receiptChainDigest',repeat('d',64));
$$;
select throws_ok($$select public.esheep_cloud_publish_checkpoint_content_v1(pg_temp.reproduction_manifest('1'),repeat('a',64),repeat('b',64))$$,
 '55000','checkpoint_boundary_unavailable','legacy capability 1 passes format validation');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_content_v1(pg_temp.reproduction_manifest('2'),repeat('a',64),repeat('b',64))$$,
 '55000','checkpoint_boundary_unavailable','association capability 2 passes format validation');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_content_v1(pg_temp.reproduction_manifest('3'),repeat('a',64),repeat('b',64))$$,
 '22023','checkpoint_invalid_manifest','unknown capability fails closed');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_content_v1(pg_temp.reproduction_manifest('0'),repeat('a',64),repeat('b',64))$$,
 '22023','checkpoint_invalid_manifest','invalid zero capability fails closed');
select throws_ok($$select public.esheep_cloud_publish_checkpoint_content_v1(pg_temp.reproduction_manifest('"2"'),repeat('a',64),repeat('b',64))$$,
 '22023','checkpoint_invalid_manifest','string capability cannot bypass numeric contract');
select ok(not has_function_privilege('service_role','public.esheep_cloud_publish_checkpoint_content_v1(jsonb,text,text)','EXECUTE'),
 'protected publisher must still use the rollout and retention wrapper');
select * from finish();
rollback;
