-- Private, per-user account avatars for the Supabase identity authority.
-- The path contract is: <auth.uid()>/avatar.jpg.

alter table public.profiles
  add column if not exists avatar_digest text,
  add column if not exists avatar_revision bigint not null default 0;

alter table public.profiles
  drop constraint if exists profiles_avatar_digest_format;

alter table public.profiles
  add constraint profiles_avatar_digest_format
  check (
    avatar_digest is null
    or avatar_digest ~ '^[0-9a-f]{64}$'
  );

grant update (avatar_digest, avatar_revision, updated_at)
  on table public.profiles to authenticated;

insert into storage.buckets (id, name, public, file_size_limit)
values ('account-avatars', 'account-avatars', false, 65536)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit;

drop policy if exists account_avatars_select_self on storage.objects;
create policy account_avatars_select_self
on storage.objects for select to authenticated
using (
  bucket_id = 'account-avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name = (select auth.uid())::text || '/avatar.jpg'
);

drop policy if exists account_avatars_insert_self on storage.objects;
create policy account_avatars_insert_self
on storage.objects for insert to authenticated
with check (
  bucket_id = 'account-avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name = (select auth.uid())::text || '/avatar.jpg'
);

drop policy if exists account_avatars_update_self on storage.objects;
create policy account_avatars_update_self
on storage.objects for update to authenticated
using (
  bucket_id = 'account-avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name = (select auth.uid())::text || '/avatar.jpg'
)
with check (
  bucket_id = 'account-avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name = (select auth.uid())::text || '/avatar.jpg'
);

drop policy if exists account_avatars_delete_self on storage.objects;
create policy account_avatars_delete_self
on storage.objects for delete to authenticated
using (
  bucket_id = 'account-avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name = (select auth.uid())::text || '/avatar.jpg'
);
