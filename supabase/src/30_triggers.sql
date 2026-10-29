-- =====================================================================
--  Triggers: validation, counters, notifications, levels, audit log
-- =====================================================================

create or replace function public.check_rate_limit(p_bucket text, max_count integer, window_seconds integer)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000');
  rl record;
begin
  select * into rl from rate_limits r where r.user_id = me and r.bucket = p_bucket for update;
  if not found or rl.window_start < now() - make_interval(secs => window_seconds) then
    insert into rate_limits as r (user_id, bucket, window_start, count)
    values (me, p_bucket, now(), 1)
    on conflict (user_id, bucket) do update set window_start = now(), count = 1;
    return;
  end if;
  if rl.count >= max_count then
    raise exception 'You''re doing that too often. Try again in a little while.' using errcode = 'GX429';
  end if;
  update rate_limits r set count = r.count + 1 where r.user_id = me and r.bucket = p_bucket;
end $$;

-- ---------------------------------------------------------------------
-- New accounts
-- ---------------------------------------------------------------------
create or replace function public.unique_username(wanted text)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  base text;
  candidate text;
  tries integer := 0;
begin
  base := lower(regexp_replace(coalesce(wanted, ''), '[^a-zA-Z0-9_.]', '', 'g'));
  if char_length(base) < 2 then base := base || 'star'; end if;
  base := left(base, 27);
  candidate := base;
  while exists (select 1 from profiles where username = candidate) loop
    tries := tries + 1;
    candidate := base || (1000 + floor(random() * 9000))::integer::text;
    if tries > 25 then
      candidate := 'user' || substr(md5(random()::text), 1, 10);
    end if;
  end loop;
  return candidate;
end $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  wanted text := coalesce(meta->>'username', split_part(coalesce(new.email, ''), '@', 1), 'user');
  shown text := nullif(btrim(left(coalesce(meta->>'display_name', meta->>'full_name', meta->>'username', ''), 32)), '');
begin
  insert into profiles (id, username, display_name)
  values (new.id, unique_username(wanted), shown)
  on conflict (id) do nothing;
  insert into user_settings (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_deleted_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from profiles where id = old.id;
  return old;
end $$;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  after delete on auth.users
  for each row execute function public.handle_deleted_user();

create or replace function public.profiles_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.username is distinct from old.username and auth.uid() is not null then
    new.username := lower(btrim(new.username));
    perform check_rate_limit('username_change', 4, 3600);
  end if;
  if new.custom_status is not null and btrim(new.custom_status) = '' then
    new.custom_status := null;
  end if;
  return new;
end $$;

drop trigger if exists profiles_before_update on public.profiles;
create trigger profiles_before_update
  before update on public.profiles
  for each row execute function public.profiles_before_update();

-- ---------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------
create or replace function public.messages_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ch record;
  srv record;
  perms bigint := 0;
  recent integer;
  maxlen integer;
  w text;
  is_user_message boolean;
begin
  select * into ch from channels where id = new.channel_id;
  if not found then raise exception 'That channel doesn''t exist anymore'; end if;
  if ch.type = 'category' then raise exception 'You can''t send messages in a category'; end if;
  new.server_id := ch.server_id;
  new.edited_at := null;
  new.pinned := false;
  new.pinned_at := null;
  new.thread_id := null;

  is_user_message := new.type in ('default', 'reply', 'forward', 'command');
  if not is_user_message then
    return new;   -- system messages written by trusted functions
  end if;

  maxlen := config_int('max_message_length', 4000);
  if char_length(new.content) > maxlen then
    raise exception 'Messages can be up to % characters', maxlen;
  end if;
  if char_length(btrim(new.content)) = 0
     and jsonb_array_length(new.attachments) = 0
     and cardinality(new.sticker_ids) = 0
     and new.poll is null
     and jsonb_array_length(new.embeds) = 0
     and new.forwarded is null then
    raise exception 'You can''t send an empty message';
  end if;
  if jsonb_array_length(new.embeds) > 10 then raise exception 'Up to 10 embeds per message'; end if;
  if cardinality(new.sticker_ids) > 3 then raise exception 'Up to 3 stickers per message'; end if;
  if jsonb_array_length(new.attachments) > 10 then raise exception 'Up to 10 files per message'; end if;

  if new.author_id is not null then
    perms := channel_permissions(new.channel_id, new.author_id);
    if (perms & perm_bit('SEND_MESSAGES')) = 0 then
      raise exception 'You don''t have permission to send messages here' using errcode = 'GX403';
    end if;
    if jsonb_array_length(new.attachments) > 0 and (perms & perm_bit('ATTACH_FILES')) = 0 then
      raise exception 'You don''t have permission to upload files here' using errcode = 'GX403';
    end if;

    select count(*) into recent from messages
    where author_id = new.author_id
      and created_at > now() - make_interval(secs => config_int('rate_limit_window_seconds', 5));
    if recent >= config_int('rate_limit_messages', 8) then
      raise exception 'You''re sending messages too quickly. Wait a moment.' using errcode = 'GX429';
    end if;

    if ch.slowmode > 0 and (perms & (perm_bit('MANAGE_MESSAGES') | perm_bit('MANAGE_CHANNELS'))) = 0 then
      if exists (
        select 1 from messages
        where channel_id = new.channel_id and author_id = new.author_id
          and created_at > now() - make_interval(secs => ch.slowmode)
      ) then
        raise exception 'Slow mode is on. You can send one message every % seconds.', ch.slowmode using errcode = 'GX429';
      end if;
    end if;

    if ch.server_id is not null and (perms & perm_bit('MANAGE_MESSAGES')) = 0 then
      select * into srv from servers where id = ch.server_id;
      foreach w in array srv.automod_words loop
        if btrim(w) <> '' and position(lower(btrim(w)) in lower(new.content)) > 0 then
          raise exception 'Your message was blocked by this server''s AutoMod' using errcode = 'GX403';
        end if;
      end loop;
      if srv.automod_block_invites and new.content ~* '#/invite/[A-Za-z0-9-]{3,}' then
        raise exception 'Invite links aren''t allowed in this server' using errcode = 'GX403';
      end if;
    end if;

    -- Attachment paths must have been uploaded by this author into this
    -- channel (or, for a new forum post, into its parent forum)
    if exists (
      select 1 from jsonb_array_elements(new.attachments) a
      where coalesce(a->>'path', '') not like new.channel_id::text || '/' || new.author_id::text || '/%'
        and (ch.type <> 'thread' or coalesce(a->>'path', '') not like ch.parent_id::text || '/' || new.author_id::text || '/%')
    ) then
      raise exception 'One of the files couldn''t be attached. Upload it again.';
    end if;

    -- Stickers must exist
    if cardinality(new.sticker_ids) > 0
       and (select count(*) from stickers where id = any(new.sticker_ids)) <> cardinality(new.sticker_ids) then
      raise exception 'That sticker no longer exists';
    end if;
  else
    perms := perm_bit('SEND_MESSAGES');   -- webhook messages: checked by execute_webhook()
  end if;

  -- Mentions are always computed here, never trusted from the client
  new.mentions := coalesce(array(
    select distinct safe_uuid(m[1]) from regexp_matches(new.content, '<@([0-9a-fA-F-]{36})>', 'g') as m
    where safe_uuid(m[1]) is not null limit 50), '{}');
  new.mention_roles := coalesce(array(
    select distinct safe_uuid(m[1]) from regexp_matches(new.content, '<@&([0-9a-fA-F-]{36})>', 'g') as m
    where safe_uuid(m[1]) is not null limit 20), '{}');
  if (perms & perm_bit('MENTION_EVERYONE')) = 0 then
    new.mention_roles := coalesce(array(
      select r.id from roles r where r.id = any(new.mention_roles) and r.mentionable and r.server_id = ch.server_id), '{}');
    new.mention_everyone := false;
  else
    new.mention_everyone := new.content ~ '@(everyone|here)([^A-Za-z0-9_]|$)';
  end if;

  if new.reply_to is not null then
    if not exists (select 1 from messages where id = new.reply_to and channel_id = new.channel_id) then
      new.reply_to := null;
    elsif new.type = 'default' then
      new.type := 'reply';
    end if;
  end if;

  if new.poll is not null then
    if jsonb_typeof(new.poll->'answers') is distinct from 'array'
       or jsonb_array_length(new.poll->'answers') not between 2 and 10
       or char_length(coalesce(new.poll->>'question', '')) not between 1 and 300 then
      raise exception 'A poll needs a question and 2 to 10 answers';
    end if;
    new.poll := jsonb_set(new.poll, '{expires_at}', to_jsonb(now() + make_interval(
      hours => least(greatest(coalesce((new.poll->>'duration_hours')::integer, 24), 1), 336))));
  end if;

  return new;
end $$;

drop trigger if exists messages_before_insert on public.messages;
create trigger messages_before_insert
  before insert on public.messages
  for each row execute function public.messages_before_insert();

create or replace function public.level_for_xp(xp integer)
returns integer language sql immutable as $$
  select floor(sqrt(greatest(xp, 0) / 100.0))::integer
$$;

create or replace function public.messages_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  new_xp integer;
  old_level integer;
  new_level integer;
  srv record;
begin
  update channels
     set last_message_at = new.created_at,
         message_count = message_count + 1,
         archived = case when type = 'thread' then false else archived end
   where id = new.channel_id;

  if jsonb_array_length(new.attachments) > 0 then
    insert into attachments (message_id, channel_id, uploader_id, path, name, size, content_type)
    select new.id, new.channel_id, new.author_id, a->>'path', left(coalesce(a->>'name', 'file'), 200),
           coalesce((a->>'size')::bigint, 0), a->>'type'
    from jsonb_array_elements(new.attachments) a
    where a->>'path' is not null;
  end if;
  -- Forwarded files become readable wherever the forward can be read
  if new.forwarded is not null and jsonb_typeof(new.forwarded->'attachments') = 'array' then
    insert into attachments (message_id, channel_id, uploader_id, path, name, size, content_type)
    select new.id, new.channel_id, new.author_id, a->>'path', left(coalesce(a->>'name', 'file'), 200),
           0, a->>'type'
    from jsonb_array_elements(new.forwarded->'attachments') a
    where a->>'path' is not null;
  end if;

  if new.server_id is null then
    update channel_recipients set closed = false where channel_id = new.channel_id and closed;
  end if;

  if new.type in ('default', 'reply', 'forward', 'command') then
    insert into notifications (user_id, type, actor_id, server_id, channel_id, message_id, data)
    select t.u, 'mention', new.author_id, new.server_id, new.channel_id, new.id,
           jsonb_build_object('preview', left(new.content, 160), 'webhook_name', new.webhook_name)
    from (
      select unnest(new.mentions) as u
      union select mr.user_id from member_roles mr where mr.role_id = any(new.mention_roles)
      union select m.user_id from members m where new.mention_everyone and m.server_id = new.server_id
      union select r.user_id from channel_recipients r
            where new.mention_everyone and new.server_id is null and r.channel_id = new.channel_id
    ) t
    where t.u is distinct from new.author_id
      and channel_permissions(new.channel_id, t.u) <> 0
      and (new.author_id is null or not exists (select 1 from blocks b where b.user_id = t.u and b.blocked_id = new.author_id))
    limit 1000
    on conflict do nothing;

    if new.reply_to is not null then
      insert into notifications (user_id, type, actor_id, server_id, channel_id, message_id, data)
      select m.author_id, 'reply', new.author_id, new.server_id, new.channel_id, new.id,
             jsonb_build_object('preview', left(new.content, 160))
      from messages m
      where m.id = new.reply_to
        and m.author_id is not null
        and m.author_id is distinct from new.author_id
        and not (m.author_id = any(new.mentions))
        and not exists (select 1 from blocks b where b.user_id = m.author_id and b.blocked_id = new.author_id)
      on conflict do nothing;
    end if;

    -- Levels (built-in, free): 15–25 XP per message, once a minute
    if new.server_id is not null and new.author_id is not null then
      select * into srv from servers where id = new.server_id;
      if srv.levels_enabled then
        update members
           set xp = xp + 15 + floor(random() * 11)::integer, last_xp_at = now()
         where server_id = new.server_id and user_id = new.author_id
           and (last_xp_at is null or last_xp_at < now() - interval '60 seconds')
        returning xp, level into new_xp, old_level;
        if found then
          new_level := level_for_xp(new_xp);
          if new_level > old_level then
            update members set level = new_level where server_id = new.server_id and user_id = new.author_id;
            if srv.level_up_messages then
              insert into messages (channel_id, author_id, type, content)
              values (new.channel_id, null, 'level_up', '<@' || new.author_id || '> reached level ' || new_level || '!');
            end if;
          end if;
        end if;
      end if;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert
  after insert on public.messages
  for each row execute function public.messages_after_insert();

create or replace function public.messages_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.content is distinct from old.content then
    if auth.uid() is not null and old.author_id is distinct from auth.uid() then
      raise exception 'You can only edit your own messages' using errcode = 'GX403';
    end if;
    if char_length(new.content) > config_int('max_message_length', 4000) then
      raise exception 'Messages can be up to % characters', config_int('max_message_length', 4000);
    end if;
    insert into message_edits (message_id, content) values (old.id, old.content);
    new.edited_at := now();
    new.mentions := coalesce(array(
      select distinct safe_uuid(m[1]) from regexp_matches(new.content, '<@([0-9a-fA-F-]{36})>', 'g') as m
      where safe_uuid(m[1]) is not null limit 50), '{}');
  end if;
  if jsonb_array_length(new.attachments) > jsonb_array_length(old.attachments) then
    raise exception 'Files can be removed from a message but not added';
  end if;
  return new;
end $$;

drop trigger if exists messages_before_update on public.messages;
create trigger messages_before_update
  before update on public.messages
  for each row execute function public.messages_before_update();

-- Reactions: fill channel, cap distinct emoji per message
create or replace function public.reactions_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select channel_id into new.channel_id from messages where id = new.message_id;
  if new.channel_id is null then raise exception 'That message doesn''t exist anymore'; end if;
  if new.emoji like 'c:%' and not exists (select 1 from emojis where id = safe_uuid(substr(new.emoji, 3))) then
    raise exception 'That emoji doesn''t exist anymore';
  end if;
  if not exists (select 1 from reactions where message_id = new.message_id and emoji = new.emoji)
     and (select count(distinct emoji) from reactions where message_id = new.message_id) >= 20 then
    raise exception 'This message already has the maximum number of different reactions';
  end if;
  return new;
end $$;

drop trigger if exists reactions_before_insert on public.reactions;
create trigger reactions_before_insert
  before insert on public.reactions
  for each row execute function public.reactions_before_insert();

create or replace function public.poll_votes_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  msg record;
begin
  select * into msg from messages where id = new.message_id;
  if not found or msg.poll is null then raise exception 'That poll doesn''t exist'; end if;
  new.channel_id := msg.channel_id;
  if (msg.poll->>'expires_at')::timestamptz < now() then raise exception 'This poll has ended'; end if;
  if new.answer_id < 0 or new.answer_id >= jsonb_array_length(msg.poll->'answers') then
    raise exception 'That answer isn''t part of the poll';
  end if;
  if not coalesce((msg.poll->>'multi')::boolean, false) then
    delete from poll_votes where message_id = new.message_id and user_id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists poll_votes_before_insert on public.poll_votes;
create trigger poll_votes_before_insert
  before insert on public.poll_votes
  for each row execute function public.poll_votes_before_insert();

-- ---------------------------------------------------------------------
-- Members: member count + welcome message
-- ---------------------------------------------------------------------
create or replace function public.members_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  srv record;
begin
  if tg_op = 'INSERT' then
    update servers set member_count = member_count + 1 where id = new.server_id returning * into srv;
    if srv.welcome_enabled and srv.system_channel_id is not null and new.user_id <> srv.owner_id then
      insert into messages (channel_id, author_id, type, content)
      values (srv.system_channel_id, null, 'join',
              replace(replace(srv.welcome_message, '{user}', '<@' || new.user_id || '>'), '{server}', srv.name));
    end if;
    return null;
  else
    update servers set member_count = greatest(member_count - 1, 0) where id = old.server_id;
    delete from channel_overrides where server_id = old.server_id and target_type = 'member' and target_id = old.user_id;
    return null;
  end if;
end $$;

drop trigger if exists members_after_change on public.members;
create trigger members_after_change
  after insert or delete on public.members
  for each row execute function public.members_after_change();

create or replace function public.members_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.user_id <> auth.uid()
     and new.avatar_url is distinct from old.avatar_url then
    raise exception 'Only the member can change their server avatar' using errcode = 'GX403';
  end if;
  if auth.uid() is not null and new.user_id = auth.uid()
     and new.nickname is distinct from old.nickname
     and not can_edit_member(new.server_id, new.user_id) then
    raise exception 'You don''t have permission to change your nickname here' using errcode = 'GX403';
  end if;
  if new.nickname is not null and btrim(new.nickname) = '' then new.nickname := null; end if;
  return new;
end $$;

drop trigger if exists members_before_update on public.members;
create trigger members_before_update
  before update on public.members
  for each row execute function public.members_before_update();

-- ---------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------
create or replace function public.roles_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_default then
    new.position := 0;
    if tg_op = 'UPDATE' then new.name := old.name; end if;
  elsif new.position < 1 then
    new.position := 1;
  end if;
  return new;
end $$;

drop trigger if exists roles_before_write on public.roles;
create trigger roles_before_write
  before insert or update on public.roles
  for each row execute function public.roles_before_write();

create or replace function public.roles_after_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from channel_overrides where target_id = old.id;
  return null;
end $$;

drop trigger if exists roles_after_delete on public.roles;
create trigger roles_after_delete
  after delete on public.roles
  for each row execute function public.roles_after_delete();

-- ---------------------------------------------------------------------
-- Channels
-- ---------------------------------------------------------------------
create or replace function public.channels_before_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.type in ('text', 'announcement', 'forum', 'media') and new.name is not null then
    new.name := left(lower(regexp_replace(btrim(new.name), '\s+', '-', 'g')), 100);
  end if;
  if new.type in ('dm', 'group_dm') then
    new.parent_id := null;
  end if;
  if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id and new.parent_id is not null then
    if not exists (select 1 from channels where id = new.parent_id and type = 'category' and server_id = new.server_id)
       and new.type <> 'thread' then
      raise exception 'Channels can only be moved into a category of the same server';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists channels_before_write on public.channels;
create trigger channels_before_write
  before insert or update on public.channels
  for each row execute function public.channels_before_write();

create or replace function public.channels_before_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Deleted as part of deleting the whole server: nothing to tidy up
  if pg_trigger_depth() > 1 then return old; end if;
  if old.type = 'category' then
    update channels set parent_id = null, synced = false where parent_id = old.id and type <> 'thread';
  end if;
  if old.server_id is not null then
    update servers set system_channel_id = null where id = old.server_id and system_channel_id = old.id;
  end if;
  return old;
end $$;

drop trigger if exists channels_before_delete on public.channels;
create trigger channels_before_delete
  before delete on public.channels
  for each row execute function public.channels_before_delete();

-- Overrides: fill server, block handing out permissions you don't have.
-- Runs with the caller's rights so trusted functions (which run as the
-- table owner) can copy overrides without this check.
create or replace function public.overrides_before_write()
returns trigger language plpgsql security invoker set search_path = public as $$
declare
  mine bigint;
begin
  new.server_id := (select public.channel_server(new.channel_id));
  if new.server_id is null then raise exception 'Permission overrides only exist in servers'; end if;
  if current_user = 'authenticated' then
    mine := server_permissions(new.server_id, auth.uid());
    if mine <> perm_all() and ((new.allow | new.deny) & ~mine) <> 0 then
      raise exception 'You can''t change permissions you don''t have yourself' using errcode = 'GX403';
    end if;
  end if;
  new.allow := new.allow & perm_all() & ~new.deny;
  return new;
end $$;

drop trigger if exists overrides_before_write on public.channel_overrides;
create trigger overrides_before_write
  before insert or update on public.channel_overrides
  for each row execute function public.overrides_before_write();

-- Expression packs have generous but finite limits (same for everyone)
create or replace function public.expressions_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n integer;
  lim integer;
begin
  execute format('select count(*) from %I where server_id = $1', tg_table_name) into n using new.server_id;
  lim := case tg_table_name
    when 'emojis' then config_int('max_emojis_per_server', 250)
    when 'stickers' then config_int('max_stickers_per_server', 60)
    else config_int('max_sounds_per_server', 48) end;
  if n >= lim then
    raise exception 'This server has reached the limit of % %', lim, tg_table_name;
  end if;
  new.created_by := coalesce(auth.uid(), new.created_by);
  return new;
end $$;

drop trigger if exists emojis_limit on public.emojis;
create trigger emojis_limit before insert on public.emojis for each row execute function public.expressions_limit();
drop trigger if exists stickers_limit on public.stickers;
create trigger stickers_limit before insert on public.stickers for each row execute function public.expressions_limit();
drop trigger if exists sounds_limit on public.sounds;
create trigger sounds_limit before insert on public.sounds for each row execute function public.expressions_limit();

-- Storage quota (same for everyone; protects the project's storage)
create or replace function public.attachments_quota()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  used bigint;
begin
  if new.uploader_id is null or new.size = 0 then return new; end if;
  select coalesce(sum(size), 0) into used from attachments where uploader_id = new.uploader_id;
  if used + new.size > config_int('user_storage_quota_bytes', 524288000)::bigint then
    raise exception 'You''ve used all of your file storage. Delete some old files to upload more.';
  end if;
  return new;
end $$;

drop trigger if exists attachments_quota on public.attachments;
create trigger attachments_quota before insert on public.attachments for each row execute function public.attachments_quota();

-- Reports: capture what was reported so moderators see it even if deleted
create or replace function public.reports_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  msg record;
begin
  perform check_rate_limit('report', 20, 3600);
  new.reporter_id := auth.uid();
  new.status := 'open';
  new.resolved_by := null;
  new.resolution := null;
  if new.target_type in ('message', 'attachment') then
    select * into msg from messages where id = safe_uuid(new.target_id);
    if not found or not can_read_channel(msg.channel_id) then
      raise exception 'You can only report messages you can see';
    end if;
    new.server_id := msg.server_id;
    new.snapshot := jsonb_build_object(
      'content', msg.content, 'author_id', msg.author_id, 'channel_id', msg.channel_id,
      'attachments', msg.attachments, 'created_at', msg.created_at);
  elsif new.target_type = 'user' then
    new.snapshot := coalesce((select to_jsonb(p) - 'is_admin' from profiles p where p.id = safe_uuid(new.target_id)), '{}'::jsonb);
    if new.server_id is not null and not is_member(new.server_id) then new.server_id := null; end if;
  elsif new.target_type = 'server' then
    new.server_id := null;
    new.snapshot := coalesce((select jsonb_build_object('name', s.name, 'description', s.description)
                              from servers s where s.id = safe_uuid(new.target_id)), '{}'::jsonb);
  end if;
  return new;
end $$;

drop trigger if exists reports_before_insert on public.reports;
create trigger reports_before_insert before insert on public.reports for each row execute function public.reports_before_insert();

-- ---------------------------------------------------------------------
-- Audit log: records every change made by a signed-in user to server
-- settings, channels, roles, permissions, invites, expressions, events
-- and webhooks. Moderation actions are logged by their functions.
-- ---------------------------------------------------------------------
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o jsonb;
  n jsonb;
  sid uuid;
  chg jsonb := '{}'::jsonb;
  k text;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  if tg_table_name = 'servers' then
    sid := coalesce(n->>'id', o->>'id')::uuid;
  else
    sid := safe_uuid(coalesce(n->>'server_id', o->>'server_id'));
  end if;
  if sid is null or not exists (select 1 from servers where id = sid) then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k not in ('member_count', 'last_message_at', 'message_count', 'uses', 'xp', 'level', 'last_xp_at', 'tsv', 'token_hash')
         and (n->k) is distinct from (o->k) then
        chg := chg || jsonb_build_object(k, jsonb_build_object('old', o->k, 'new', n->k));
      end if;
    end loop;
    if chg = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    chg := n - 'token_hash';
  else
    chg := o - 'token_hash';
  end if;
  insert into audit_logs (server_id, actor_id, action, target_type, target_id, changes)
  values (sid, auth.uid(), tg_table_name || '.' || lower(tg_op), tg_table_name,
          coalesce(n->>'id', o->>'id', n->>'code', o->>'code', n->>'role_id', o->>'role_id', n->>'target_id', o->>'target_id'),
          chg);
  return coalesce(new, old);
end $$;

do $$
declare
  t text;
begin
  foreach t in array array['servers','channels','roles','channel_overrides','invites','emojis','stickers','sounds','events','webhooks','member_roles'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_audit', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_trigger()', t || '_audit', t);
  end loop;
end $$;
