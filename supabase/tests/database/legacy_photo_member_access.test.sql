begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- A and B share no membership. Both have a verified original, avatar and
-- thumbnail, but only A's asset has the historical UUID bit pattern.
create temp table photo_fixtures as
select farm, gen_random_uuid() as farm_id, gen_random_uuid() as worker_id,
       gen_random_uuid() as owner_id, asset_id
from (values
  ('A', overlay(gen_random_uuid()::text placing '1' from 20 for 1)::uuid),
  ('B', gen_random_uuid())
) as f(farm, asset_id);

insert into auth.users (id, aud, role, email, email_confirmed_at)
select id, 'authenticated', 'authenticated', id || '@example.invalid', now()
from photo_fixtures cross join lateral (values (owner_id), (worker_id)) u(id);

insert into public.farm_registry (farm_id, owner_user_id, provider, status, authority_generation)
select farm_id, owner_id, 'esheep_cloud', 'active', 1 from photo_fixtures;
insert into public.farm_members (farm_id, user_id, app_account_id, role, status)
select f.farm_id, p.user_id, p.app_account_id,
       case p.user_id when f.owner_id then 'owner' else 'worker' end, 'active'
from photo_fixtures f join public.profiles p on p.user_id in (f.owner_id, f.worker_id);
insert into esheep_cloud.farm_state (farm_id, farm_generation, status)
select farm_id, 1, 'active' from photo_fixtures;

insert into esheep_cloud.assets (
  farm_id, farm_generation, asset_id, content_sha256, metadata_digest,
  original_path, original_sha256, original_state,
  thumbnail_path, thumbnail_sha256, thumbnail_state,
  avatar_path, avatar_sha256, avatar_state, recycle_expires_at
)
select farm_id, 1, asset_id, repeat('a', 64), repeat('0', 64),
       prefix || repeat('a', 64) || '/original.bin', repeat('a', 64), 'verified',
       prefix || repeat('b', 64) || '/thumbnail.jpg', repeat('b', 64), 'verified',
       prefix || repeat('c', 64) || '/avatar.jpg', repeat('c', 64), 'verified', now() - interval '1 day'
from photo_fixtures cross join lateral (select farm_id || '/1/' || asset_id || '/' as prefix) k;

insert into storage.objects (bucket_id, name)
select 'esheep-cloud-assets', k.path
from esheep_cloud.assets a join photo_fixtures f using (asset_id)
cross join lateral (values (a.original_path), (a.thumbnail_path), (a.avatar_path)) k(path);

grant select on photo_fixtures to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', (select worker_id::text from photo_fixtures where farm='A'), true);
select is(
  (select array_agg(f.farm order by f.farm) from storage.objects o
   join photo_fixtures f on split_part(o.name, '/', 1) = f.farm_id::text
   where o.bucket_id = 'esheep-cloud-assets'),
  array['A','A','A'], 'farm A worker reads all three legacy variants and sees no farm B photos');

select set_config('request.jwt.claim.sub', (select worker_id::text from photo_fixtures where farm='B'), true);
select is(
  (select array_agg(f.farm order by f.farm) from storage.objects o
   join photo_fixtures f on split_part(o.name, '/', 1) = f.farm_id::text
   where o.bucket_id = 'esheep-cloud-assets'),
  array['B','B','B'], 'farm B worker reads all three variants and sees no farm A photos');
reset role;

select set_config('request.jwt.claim.sub', (select owner_id::text from photo_fixtures where farm='A'), true);
select is(esheep_cloud.storage_path_is_authorized(original_path || '/unregistered', false, false), false,
          'the legacy read must match the exact registered path')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';
select is(esheep_cloud.storage_path_is_authorized(original_path, true, false), false,
          'the new read permission does not permit owner deletion even after recycle expiry')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';
update esheep_cloud.assets set original_state = 'transferring'
where asset_id = (select asset_id from photo_fixtures where farm='A');
select is(esheep_cloud.storage_path_is_authorized(original_path, false, false), false,
          'a legacy original must be verified before a member can read it')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';
select is(esheep_cloud.storage_path_is_authorized(original_path, false, true), false,
          'a transferring legacy variant does not gain upload permission')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';
update esheep_cloud.assets set original_state = 'verified', original_sha256 = repeat('d', 64)
where asset_id = (select asset_id from photo_fixtures where farm='A');
select is(esheep_cloud.storage_path_is_authorized(original_path, false, false), false,
          'the digest in a registered legacy path must still match the verified variant')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';
update esheep_cloud.farm_state set farm_generation = 2
where farm_id = (select farm_id from photo_fixtures where farm='A');
select is(esheep_cloud.storage_path_is_authorized(thumbnail_path, false, false), false,
          'a verified legacy variant from an earlier generation is hidden')
from esheep_cloud.assets join photo_fixtures using (asset_id) where farm='A';

select * from finish();
rollback;
