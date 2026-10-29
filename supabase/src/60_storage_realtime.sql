-- =====================================================================
--  Storage buckets and Realtime
-- =====================================================================

-- "media": avatars, banners, server icons, emoji, stickers, sounds.
--   Public to read (they show up everywhere); you can only write inside
--   your own folder: <your user id>/...
-- "attachments": files sent in messages. Private. Path:
--   <channel id>/<your user id>/<random>/<file name>
--   Readable only by people who can read a message that contains it.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 15728640,
        array['image/png','image/jpeg','image/gif','image/webp','image/avif','image/apng',
              'audio/mpeg','audio/ogg','audio/wav','audio/x-wav','audio/webm','audio/mp4','audio/aac','audio/flac'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

do $$
declare
  r record;
begin
  for r in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'galaxy_%' loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;
end $$;

create policy galaxy_media_read on storage.objects for select to authenticated
  using (bucket_id = 'media');
create policy galaxy_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy galaxy_media_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy galaxy_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

create policy galaxy_attachments_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and (
    (storage.foldername(name))[2] = auth.uid()::text
    or exists (select 1 from public.attachments a where a.path = objects.name and public.can_read_channel(a.channel_id))));
create policy galaxy_attachments_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (storage.foldername(name))[2] = auth.uid()::text
              and public.has_channel_perm_text((storage.foldername(name))[1], 'ATTACH_FILES'));
create policy galaxy_attachments_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (
    (storage.foldername(name))[2] = auth.uid()::text
    or public.has_channel_perm_text((storage.foldername(name))[1], 'MANAGE_MESSAGES')));

-- ---------------------------------------------------------------------
-- Realtime: database changes (filtered by the policies above) and
-- private broadcast/presence channels (authorised below).
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['messages','reactions','poll_votes','channels','servers','members','member_roles','roles',
                           'channel_overrides','channel_recipients','friend_requests','friends','blocks','notifications',
                           'profiles','emojis','stickers','sounds','events','event_rsvps','read_states','user_settings',
                           'join_requests','reports'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

do $$
declare
  r record;
begin
  for r in select policyname from pg_policies where schemaname = 'realtime' and tablename = 'messages' and policyname like 'galaxy_%' loop
    execute format('drop policy %I on realtime.messages', r.policyname);
  end loop;
end $$;

create policy galaxy_realtime_receive on realtime.messages for select to authenticated
  using (public.realtime_allowed(realtime.topic(), false));
create policy galaxy_realtime_send on realtime.messages for insert to authenticated
  with check (public.realtime_allowed(realtime.topic(), true));
