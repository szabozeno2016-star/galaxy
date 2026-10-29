-- =====================================================================
--  Friends, blocks and direct messages
-- =====================================================================

create or replace function public.make_friends(a uuid, b uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into friends (user_id, friend_id) values (a, b), (b, a) on conflict do nothing;
  delete from friend_requests where (from_id = a and to_id = b) or (from_id = b and to_id = a);
  -- Pending message requests between friends are accepted automatically
  update channel_recipients r set accepted = true
  from channels c
  where c.id = r.channel_id and c.type = 'dm'
    and c.dm_key = least(a::text, b::text) || ':' || greatest(a::text, b::text);
end $$;

create or replace function public.send_friend_request(target_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  target uuid;
  pref text;
  has_mutual boolean;
begin
  select id into target from profiles
  where username = lower(btrim(regexp_replace(target_username, '^@', ''))) and not is_bot;
  if target is null then
    raise exception 'Nobody has that username. Check the spelling, including capital letters and dots.';
  end if;
  if target = me then raise exception 'That''s you! Add someone else.'; end if;
  if exists (select 1 from friends where user_id = me and friend_id = target) then
    raise exception 'You''re already friends';
  end if;
  if exists (select 1 from blocks where user_id = me and blocked_id = target) then
    raise exception 'You blocked this user. Unblock them first.';
  end if;
  if exists (select 1 from blocks where user_id = target and blocked_id = me) then
    raise exception 'Friend request failed. This user isn''t accepting requests from you.';
  end if;
  if exists (select 1 from friend_requests where from_id = target and to_id = me) then
    perform make_friends(me, target);
    insert into notifications (user_id, type, actor_id) values (target, 'friend_accept', me);
    return jsonb_build_object('status', 'accepted', 'user_id', target);
  end if;
  if exists (select 1 from friend_requests where from_id = me and to_id = target) then
    return jsonb_build_object('status', 'pending', 'user_id', target);
  end if;
  select friend_requests_from into pref from user_settings where user_id = target;
  if pref = 'none' then
    raise exception 'This user isn''t accepting friend requests right now';
  end if;
  if pref = 'mutual' then
    has_mutual := shares_server(me, target) or exists (
      select 1 from friends f1 join friends f2 on f2.friend_id = f1.friend_id
      where f1.user_id = me and f2.user_id = target);
    if not has_mutual then
      raise exception 'This user only accepts friend requests from people they share a server or friend with';
    end if;
  end if;
  perform check_rate_limit('friend_request', 30, 3600);
  insert into friend_requests (from_id, to_id) values (me, target);
  insert into notifications (user_id, type, actor_id) values (target, 'friend_request', me);
  return jsonb_build_object('status', 'sent', 'user_id', target);
end $$;

create or replace function public.respond_friend_request(from_user uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from friend_requests where from_id = from_user and to_id = me) then
    raise exception 'That friend request isn''t there anymore';
  end if;
  if accept then
    perform make_friends(me, from_user);
    insert into notifications (user_id, type, actor_id) values (from_user, 'friend_accept', me);
  else
    delete from friend_requests where from_id = from_user and to_id = me;
  end if;
  delete from notifications where user_id = me and type = 'friend_request' and actor_id = from_user;
end $$;

create or replace function public.cancel_friend_request(to_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  delete from friend_requests where from_id = me and to_id = to_user;
  delete from notifications where user_id = to_user and type = 'friend_request' and actor_id = me;
end $$;

create or replace function public.remove_friend(other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  delete from friends where (user_id = me and friend_id = other) or (user_id = other and friend_id = me);
end $$;

create or replace function public.block_user(other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if other = me then raise exception 'You can''t block yourself'; end if;
  insert into blocks (user_id, blocked_id) values (me, other) on conflict do nothing;
  delete from friends where (user_id = me and friend_id = other) or (user_id = other and friend_id = me);
  delete from friend_requests where (from_id = me and to_id = other) or (from_id = other and to_id = me);
end $$;

create or replace function public.unblock_user(other uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  delete from blocks where user_id = me and blocked_id = other;
end $$;

-- Mutual friends and servers (only ever things the caller can see)
create or replace function public.mutuals(other uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  return jsonb_build_object(
    'friends', coalesce((
      select jsonb_agg(f1.friend_id) from friends f1
      join friends f2 on f2.friend_id = f1.friend_id and f2.user_id = other
      where f1.user_id = me), '[]'::jsonb),
    'servers', coalesce((
      select jsonb_agg(m1.server_id) from members m1
      join members m2 on m2.server_id = m1.server_id and m2.user_id = other
      where m1.user_id = me), '[]'::jsonb),
    'is_friend', are_friends(me, other),
    'blocked', exists (select 1 from blocks where user_id = me and blocked_id = other),
    'incoming', exists (select 1 from friend_requests where from_id = other and to_id = me),
    'outgoing', exists (select 1 from friend_requests where from_id = me and to_id = other)
  );
end $$;

-- ---------------------------------------------------------------------
-- Direct messages
-- ---------------------------------------------------------------------
create or replace function public.open_dm(target uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  key text;
  cid uuid;
  allow text;
  friendly boolean;
  target_is_bot boolean;
begin
  if target = me then raise exception 'You can''t message yourself'; end if;
  select is_bot into target_is_bot from profiles where id = target;
  if not found then raise exception 'That user doesn''t exist'; end if;
  key := least(me::text, target::text) || ':' || greatest(me::text, target::text);
  select id into cid from channels where dm_key = key;
  if cid is not null then
    update channel_recipients set closed = false where channel_id = cid and user_id = me;
    return cid;
  end if;
  if is_blocked_between(me, target) then
    raise exception 'You can''t message this user';
  end if;
  friendly := are_friends(me, target);
  if not friendly and not target_is_bot then
    select allow_dms into allow from user_settings where user_id = target;
    if allow = 'friends' then
      raise exception 'This user only accepts messages from friends. Send a friend request first.';
    end if;
    if allow = 'servers' and not shares_server(me, target) then
      raise exception 'This user only accepts messages from friends and people in their servers';
    end if;
  end if;
  perform check_rate_limit('open_dm', 40, 3600);
  insert into channels (type, dm_key) values ('dm', key) returning id into cid;
  insert into channel_recipients (channel_id, user_id, accepted)
  values (cid, me, true), (cid, target, friendly or target_is_bot or shares_server(me, target));
  return cid;
end $$;

create or replace function public.create_group_dm(user_ids uuid[], group_name text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  cid uuid;
  u uuid;
  ids uuid[];
begin
  ids := array(select distinct x from unnest(user_ids) x where x <> me);
  if cardinality(ids) < 1 then raise exception 'Pick at least one friend'; end if;
  if cardinality(ids) + 1 > config_int('max_group_dm_size', 10) then
    raise exception 'Group DMs can have up to % people', config_int('max_group_dm_size', 10);
  end if;
  foreach u in array ids loop
    if not are_friends(me, u) then raise exception 'You can only add friends to a group DM'; end if;
  end loop;
  perform check_rate_limit('group_dm', 20, 3600);
  insert into channels (type, name, owner_id)
  values ('group_dm', nullif(btrim(left(coalesce(group_name, ''), 100)), ''), me)
  returning id into cid;
  insert into channel_recipients (channel_id, user_id) values (cid, me);
  insert into channel_recipients (channel_id, user_id) select cid, x from unnest(ids) x;
  insert into messages (channel_id, author_id, type, content) values (cid, me, 'system', 'created the group');
  return cid;
end $$;

create or replace function public.group_dm_add(cid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from channels where id = cid and type = 'group_dm') then raise exception 'Not a group DM'; end if;
  if not is_recipient(cid) then raise exception 'You''re not in this group'; end if;
  if not are_friends(me, target) then raise exception 'You can only add friends'; end if;
  if (select count(*) from channel_recipients where channel_id = cid) >= config_int('max_group_dm_size', 10) then
    raise exception 'This group is full';
  end if;
  insert into channel_recipients (channel_id, user_id) values (cid, target) on conflict do nothing;
  insert into messages (channel_id, author_id, type, content) values (cid, me, 'system', 'added <@' || target || '> to the group');
end $$;

create or replace function public.group_dm_remove(cid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from channels where id = cid and type = 'group_dm' and owner_id = me) then
    raise exception 'Only the group owner can remove people';
  end if;
  if target = me then raise exception 'Use Leave Group instead'; end if;
  delete from channel_recipients where channel_id = cid and user_id = target;
  insert into messages (channel_id, author_id, type, content) values (cid, me, 'system', 'removed <@' || target || '> from the group');
end $$;

create or replace function public.leave_group_dm(cid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  next_owner uuid;
begin
  if not exists (select 1 from channels where id = cid and type = 'group_dm') then raise exception 'Not a group DM'; end if;
  delete from channel_recipients where channel_id = cid and user_id = me;
  select user_id into next_owner from channel_recipients where channel_id = cid order by joined_at limit 1;
  if next_owner is null then
    delete from channels where id = cid;
  else
    update channels set owner_id = next_owner where id = cid and owner_id = me;
    insert into messages (channel_id, author_id, type, content) values (cid, me, 'system', 'left the group');
  end if;
end $$;
