-- =====================================================================
--  Bots, slash commands and webhooks
--
--  Bots talk to Galaxy with plain HTTPS calls to these functions using
--  the project's public (anon) key plus their own bot token. Tokens are
--  stored only as SHA-256 hashes and are shown once when created.
--  Bots go through exactly the same permission checks as people.
-- =====================================================================

create or replace function public.hash_token(token text)
returns text language sql immutable as $$
  select encode(extensions.digest(token, 'sha256'), 'hex')
$$;

create or replace function public.new_bot_token(bid uuid)
returns text language sql volatile as $$
  select 'gx.' || replace(bid::text, '-', '') || '.' || encode(extensions.gen_random_bytes(24), 'hex')
$$;

create or replace function public.bot_auth(p_token text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  raw text := split_part(coalesce(p_token, ''), '.', 2);
  bid uuid;
begin
  if char_length(raw) <> 32 then raise exception 'Invalid bot token' using errcode = 'GX401'; end if;
  bid := safe_uuid(substr(raw, 1, 8) || '-' || substr(raw, 9, 4) || '-' || substr(raw, 13, 4) || '-' || substr(raw, 17, 4) || '-' || substr(raw, 21, 12));
  if bid is null or not exists (select 1 from bot_apps where id = bid and token_hash = hash_token(p_token)) then
    raise exception 'Invalid bot token' using errcode = 'GX401';
  end if;
  return bid;
end $$;

create or replace function public.create_bot(p_name text, p_description text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  bid uuid := gen_random_uuid();
  token text;
begin
  if (select count(*) from bot_apps where owner_id = me) >= 25 then raise exception 'You can have up to 25 bots'; end if;
  perform check_rate_limit('create_bot', 10, 86400);
  insert into profiles (id, username, display_name, is_bot, bot_owner_id, bio)
  values (bid, unique_username(btrim(p_name) || '_bot'), left(btrim(p_name), 32), true, me, left(coalesce(p_description, ''), 2000));
  token := new_bot_token(bid);
  insert into bot_apps (id, owner_id, name, description, token_hash, token_hint)
  values (bid, me, left(btrim(p_name), 32), left(coalesce(p_description, ''), 400), hash_token(token), right(token, 4));
  insert into audit_logs (actor_id, action, target_type, target_id) values (me, 'bot.create', 'bot', bid::text);
  return jsonb_build_object('id', bid, 'token', token);
end $$;

create or replace function public.reset_bot_token(bid uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  token text;
begin
  if not exists (select 1 from bot_apps where id = bid and owner_id = me) then raise exception 'That isn''t your bot' using errcode = 'GX403'; end if;
  token := new_bot_token(bid);
  update bot_apps set token_hash = hash_token(token), token_hint = right(token, 4) where id = bid;
  insert into audit_logs (actor_id, action, target_type, target_id) values (me, 'bot.token_reset', 'bot', bid::text);
  return token;
end $$;

create or replace function public.update_bot(bid uuid, p_name text, p_description text, p_avatar_url text, p_public boolean, p_permissions bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from bot_apps where id = bid and owner_id = me) then raise exception 'That isn''t your bot' using errcode = 'GX403'; end if;
  update bot_apps set name = left(btrim(p_name), 32), description = left(coalesce(p_description, ''), 400),
                      is_public = coalesce(p_public, false), permissions = coalesce(p_permissions, 0) & perm_all()
   where id = bid;
  update profiles set display_name = left(btrim(p_name), 32), avatar_url = p_avatar_url, bio = left(coalesce(p_description, ''), 2000)
   where id = bid;
  insert into audit_logs (actor_id, action, target_type, target_id) values (me, 'bot.update', 'bot', bid::text);
end $$;

create or replace function public.delete_bot(bid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from bot_apps where id = bid and owner_id = me) then raise exception 'That isn''t your bot' using errcode = 'GX403'; end if;
  insert into audit_logs (actor_id, action, target_type, target_id) values (me, 'bot.delete', 'bot', bid::text);
  delete from profiles where id = bid;
end $$;

create or replace function public.add_bot_to_server(bid uuid, sid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  bot record;
  granted bigint;
  rid uuid;
begin
  select * into bot from bot_apps where id = bid;
  if not found or not (bot.is_public or bot.owner_id = me) then raise exception 'That bot isn''t available'; end if;
  if not has_server_perm(sid, 'MANAGE_WEBHOOKS') then
    raise exception 'You need the Manage Integrations permission to add bots' using errcode = 'GX403';
  end if;
  if is_member_of(sid, bid) then raise exception 'That bot is already in this server'; end if;
  insert into members (server_id, user_id) values (sid, bid);
  granted := bot.permissions & server_permissions(sid, me) & ~perm_bit('ADMINISTRATOR');
  if granted <> 0 then
    insert into roles (server_id, name, permissions, position, managed_by_bot, color)
    values (sid, bot.name, granted, 1, bid, '#8F5BFF') returning id into rid;
    insert into member_roles (server_id, user_id, role_id) values (sid, bid, rid);
  end if;
  perform log_action(sid, 'bot.add', 'bot', bid::text, null, jsonb_build_object('permissions', granted));
end $$;

-- Called by bots ------------------------------------------------------
create or replace function public.bot_me(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
begin
  return jsonb_build_object(
    'id', bid,
    'username', (select username from profiles where id = bid),
    'servers', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name))
                         from members m join servers s on s.id = m.server_id where m.user_id = bid), '[]'::jsonb));
end $$;

create or replace function public.bot_channels(p_token text, p_server uuid)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
begin
  return query
  select jsonb_build_object('id', c.id, 'name', c.name, 'type', c.type, 'permissions', channel_permissions(c.id, bid))
  from channels c
  where c.server_id = p_server and c.type <> 'category' and channel_permissions(c.id, bid) <> 0
  order by c.position;
end $$;

create or replace function public.bot_send_message(p_token text, p_channel uuid, p_content text,
                                                   p_embeds jsonb default '[]'::jsonb, p_reply_to uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
  mid uuid;
begin
  insert into messages (channel_id, author_id, content, embeds, reply_to)
  values (p_channel, bid, coalesce(p_content, ''), coalesce(p_embeds, '[]'::jsonb), p_reply_to)
  returning id into mid;
  return mid;
end $$;

create or replace function public.bot_read_messages(p_token text, p_channel uuid, p_after timestamptz default null, p_limit integer default 50)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
  needed bigint := perm_bit('VIEW_CHANNEL') | perm_bit('READ_HISTORY');
begin
  if (channel_permissions(p_channel, bid) & needed) <> needed then
    raise exception 'The bot can''t read that channel' using errcode = 'GX403';
  end if;
  return query
  select jsonb_build_object('id', m.id, 'channel_id', m.channel_id, 'author_id', m.author_id,
                            'author', (select username from profiles where id = m.author_id),
                            'content', m.content, 'mentions', m.mentions, 'reply_to', m.reply_to,
                            'created_at', m.created_at)
  from (select * from messages
        where channel_id = p_channel and (p_after is null or created_at > p_after)
        order by created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 100)) m
  order by m.created_at;
end $$;

create or replace function public.bot_set_commands(p_token text, p_commands jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
begin
  if jsonb_array_length(p_commands) > 50 then raise exception 'Up to 50 commands'; end if;
  delete from bot_commands where bot_id = bid;
  insert into bot_commands (bot_id, name, description, options)
  select bid, lower(c->>'name'), coalesce(c->>'description', ''), coalesce(c->'options', '[]'::jsonb)
  from jsonb_array_elements(p_commands) c;
end $$;

create or replace function public.bot_poll_interactions(p_token text)
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
begin
  update interactions set status = 'expired' where bot_id = bid and status in ('pending', 'delivered') and created_at < now() - interval '15 minutes';
  return query
  with picked as (
    update interactions set status = 'delivered'
    where bot_id = bid and status = 'pending'
    returning *
  )
  select jsonb_build_object('id', p.id, 'command', p.command, 'options', p.options, 'channel_id', p.channel_id,
                            'server_id', p.server_id, 'user_id', p.user_id,
                            'user', (select jsonb_build_object('username', username, 'display_name', display_name) from profiles where id = p.user_id),
                            'created_at', p.created_at)
  from picked p order by p.created_at;
end $$;

create or replace function public.bot_respond(p_token text, p_interaction uuid, p_content text, p_embeds jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  bid uuid := bot_auth(p_token);
  it record;
  mid uuid;
begin
  select * into it from interactions where id = p_interaction and bot_id = bid;
  if not found then raise exception 'Unknown interaction'; end if;
  if it.status in ('done', 'expired') then raise exception 'This interaction was already answered or has expired'; end if;
  insert into messages (channel_id, author_id, type, content, embeds, interaction)
  values (it.channel_id, bid, 'command', coalesce(p_content, ''), coalesce(p_embeds, '[]'::jsonb),
          jsonb_build_object('user_id', it.user_id, 'command', it.command))
  returning id into mid;
  update interactions set status = 'done', response_message_id = mid where id = it.id;
  return mid;
end $$;

-- Called by people: run a bot's slash command in a channel
create or replace function public.invoke_command(p_channel uuid, p_bot uuid, p_command text, p_options jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  ch record;
  iid uuid;
begin
  select * into ch from channels where id = p_channel;
  if not found then raise exception 'Channel not found'; end if;
  if not has_channel_perm(p_channel, 'SEND_MESSAGES') then raise exception 'You can''t use commands here' using errcode = 'GX403'; end if;
  if channel_permissions(p_channel, p_bot) = 0 then raise exception 'That bot isn''t in this channel'; end if;
  if not exists (select 1 from bot_commands where bot_id = p_bot and name = lower(p_command)) then
    raise exception 'That bot doesn''t have a /% command', p_command;
  end if;
  perform check_rate_limit('invoke_command', 30, 60);
  insert into interactions (bot_id, user_id, channel_id, server_id, command, options)
  values (p_bot, me, p_channel, ch.server_id, lower(p_command), coalesce(p_options, '{}'::jsonb))
  returning id into iid;
  return iid;
end $$;

-- Webhooks ------------------------------------------------------------
create or replace function public.create_webhook(p_channel uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  ch record;
  wid uuid := gen_random_uuid();
  token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select * into ch from channels where id = p_channel;
  if not found or ch.server_id is null then raise exception 'Webhooks live in server channels'; end if;
  if not has_channel_perm(p_channel, 'MANAGE_WEBHOOKS') then
    raise exception 'You need the Manage Integrations permission' using errcode = 'GX403';
  end if;
  if (select count(*) from webhooks where channel_id = p_channel) >= 15 then raise exception 'Up to 15 webhooks per channel'; end if;
  insert into webhooks (id, server_id, channel_id, name, token_hash, created_by)
  values (wid, ch.server_id, p_channel, left(btrim(p_name), 80), hash_token(token), me);
  return jsonb_build_object('id', wid, 'token', token);
end $$;

create or replace function public.execute_webhook(p_id uuid, p_token text, p_content text,
                                                  p_username text default null, p_avatar_url text default null,
                                                  p_embeds jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  w record;
  mid uuid;
  rl record;
begin
  select * into w from webhooks where id = p_id and token_hash = hash_token(coalesce(p_token, ''));
  if not found then raise exception 'Invalid webhook' using errcode = 'GX401'; end if;
  select * into rl from rate_limits where user_id = p_id and bucket = 'webhook';
  if found and rl.window_start > now() - interval '60 seconds' and rl.count >= 30 then
    raise exception 'This webhook is sending too fast' using errcode = 'GX429';
  end if;
  insert into rate_limits (user_id, bucket, window_start, count) values (p_id, 'webhook', now(), 1)
  on conflict (user_id, bucket) do update
    set count = case when rate_limits.window_start > now() - interval '60 seconds' then rate_limits.count + 1 else 1 end,
        window_start = case when rate_limits.window_start > now() - interval '60 seconds' then rate_limits.window_start else now() end;
  insert into messages (channel_id, author_id, webhook_id, webhook_name, webhook_avatar, content, embeds)
  values (w.channel_id, null, w.id, left(coalesce(nullif(btrim(p_username), ''), w.name), 80),
          coalesce(p_avatar_url, w.avatar_url), coalesce(p_content, ''), coalesce(p_embeds, '[]'::jsonb))
  returning id into mid;
  return mid;
end $$;
