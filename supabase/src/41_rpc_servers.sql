-- =====================================================================
--  Servers: create, join, leave, channels, moderation
-- =====================================================================

create or replace function public.log_action(sid uuid, act text, ttype text, tid text, reason text, details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into audit_logs (server_id, actor_id, action, target_type, target_id, reason, changes)
  values (sid, auth.uid(), act, ttype, tid, reason, details)
$$;

create or replace function public.create_server(p_name text, p_icon_url text default null, p_template text default 'default')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  sid uuid;
  cat_text uuid;
  cat_voice uuid;
  general uuid;
begin
  if (select count(*) from members where user_id = me) >= config_int('max_servers_per_user', 200) then
    raise exception 'You''re in the maximum number of servers. Leave one to create another.';
  end if;
  perform check_rate_limit('create_server', 10, 3600);
  insert into servers (name, icon_url, owner_id) values (btrim(p_name), p_icon_url, me) returning id into sid;
  insert into roles (server_id, name, permissions, position, is_default)
  values (sid, '@everyone', perm_default(), 0, true);
  insert into members (server_id, user_id) values (sid, me);

  insert into channels (server_id, type, name, position) values (sid, 'category', 'Text Channels', 0) returning id into cat_text;
  insert into channels (server_id, type, name, position) values (sid, 'category', 'Voice Channels', 1) returning id into cat_voice;
  insert into channels (server_id, parent_id, type, name, position, topic)
  values (sid, cat_text, 'text', 'general', 0, 'Say hi and hang out') returning id into general;

  if p_template = 'gaming' then
    insert into channels (server_id, parent_id, type, name, position) values
      (sid, cat_text, 'text', 'clips-and-highlights', 1),
      (sid, cat_text, 'text', 'looking-for-group', 2),
      (sid, cat_voice, 'voice', 'Lobby', 0),
      (sid, cat_voice, 'voice', 'Gaming', 1),
      (sid, cat_voice, 'voice', 'Squad', 2);
  elsif p_template = 'friends' then
    insert into channels (server_id, parent_id, type, name, position) values
      (sid, cat_text, 'text', 'memes', 1),
      (sid, cat_text, 'text', 'music', 2),
      (sid, cat_voice, 'voice', 'Lounge', 0),
      (sid, cat_voice, 'voice', 'Movie Night', 1);
  elsif p_template = 'study' then
    insert into channels (server_id, parent_id, type, name, position) values
      (sid, cat_text, 'text', 'homework-help', 1),
      (sid, cat_text, 'text', 'resources', 2),
      (sid, cat_voice, 'voice', 'Study Room', 0),
      (sid, cat_voice, 'voice', 'Quiet Focus', 1);
  elsif p_template = 'creators' then
    insert into channels (server_id, parent_id, type, name, position) values
      (sid, cat_text, 'announcement', 'announcements', 1),
      (sid, cat_text, 'forum', 'showcase', 2),
      (sid, cat_text, 'text', 'feedback', 3),
      (sid, cat_voice, 'voice', 'Live', 0);
  else
    insert into channels (server_id, parent_id, type, name, position) values
      (sid, cat_voice, 'voice', 'General', 0);
  end if;

  -- Announcement channels: only moderators post by default
  insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
  select c.id, sid, 'role', r.id, 0, perm_bit('SEND_MESSAGES')
  from channels c join roles r on r.server_id = sid and r.is_default
  where c.server_id = sid and c.type = 'announcement';

  update servers set system_channel_id = general where id = sid;
  return sid;
end $$;

-- What a person sees before joining (invite page / discovery card)
create or replace function public.server_preview(sid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'icon_url', s.icon_url, 'banner_url', s.banner_url,
    'description', s.description, 'member_count', s.member_count, 'rules', s.rules,
    'require_approval', s.require_approval, 'join_questions', s.join_questions,
    'tags', s.tags, 'category', s.category, 'is_public', s.is_public, 'theme', s.theme,
    'is_member', public.is_member(s.id)
  )
  from servers s
  where s.id = sid and (s.is_public or public.is_member(s.id))
$$;

create or replace function public.invite_info(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  inv record;
  srv record;
  inviter record;
begin
  select * into inv from invites where code = p_code;
  if found then
    if (inv.expires_at is not null and inv.expires_at < now()) or (inv.max_uses > 0 and inv.uses >= inv.max_uses) then
      return jsonb_build_object('valid', false, 'reason', 'This invite has expired');
    end if;
    select * into srv from servers where id = inv.server_id;
    select username, display_name, avatar_url into inviter from profiles where id = inv.created_by;
  else
    select * into srv from servers where vanity = lower(p_code);
    if not found then
      return jsonb_build_object('valid', false, 'reason', 'This invite doesn''t exist. Ask for a new one.');
    end if;
  end if;
  return jsonb_build_object(
    'valid', true, 'code', p_code,
    'server', jsonb_build_object('id', srv.id, 'name', srv.name, 'icon_url', srv.icon_url, 'banner_url', srv.banner_url,
      'description', srv.description, 'member_count', srv.member_count, 'rules', srv.rules,
      'require_approval', srv.require_approval, 'join_questions', srv.join_questions, 'theme', srv.theme),
    'inviter', case when inviter is null then null else to_jsonb(inviter) end,
    'expires_at', inv.expires_at,
    'is_member', public.is_member(srv.id)
  );
end $$;

create or replace function public.add_member(sid uuid, uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from bans where server_id = sid and user_id = uid) then
    raise exception 'You''re banned from this server' using errcode = 'GX403';
  end if;
  if (select count(*) from members where user_id = uid) >= config_int('max_servers_per_user', 200) then
    raise exception 'You''re in the maximum number of servers. Leave one to join another.';
  end if;
  insert into members (server_id, user_id) values (sid, uid) on conflict do nothing;
end $$;

create or replace function public.join_server(p_code text, p_answers jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  inv record;
  srv record;
begin
  perform check_rate_limit('join_server', 40, 3600);
  select * into inv from invites where code = p_code;
  if found then
    if (inv.expires_at is not null and inv.expires_at < now()) or (inv.max_uses > 0 and inv.uses >= inv.max_uses) then
      raise exception 'This invite has expired. Ask for a new one.';
    end if;
    select * into srv from servers where id = inv.server_id;
  else
    select * into srv from servers where vanity = lower(p_code);
    if not found then raise exception 'This invite doesn''t exist. Ask for a new one.'; end if;
  end if;
  if exists (select 1 from members where server_id = srv.id and user_id = me) then
    return jsonb_build_object('server_id', srv.id, 'status', 'member');
  end if;
  if exists (select 1 from bans where server_id = srv.id and user_id = me) then
    raise exception 'You''re banned from this server' using errcode = 'GX403';
  end if;
  if srv.require_approval then
    insert into join_requests (server_id, user_id, answers) values (srv.id, me, coalesce(p_answers, '[]'::jsonb))
    on conflict (server_id, user_id) do update set answers = excluded.answers, status = 'pending', created_at = now();
    return jsonb_build_object('server_id', srv.id, 'status', 'pending');
  end if;
  perform add_member(srv.id, me);
  if inv.code is not null then update invites set uses = uses + 1 where code = inv.code; end if;
  return jsonb_build_object('server_id', srv.id, 'status', 'joined');
end $$;

create or replace function public.join_public_server(sid uuid, p_answers jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  srv record;
begin
  perform check_rate_limit('join_server', 40, 3600);
  select * into srv from servers where id = sid and is_public;
  if not found then raise exception 'This server isn''t open to the public'; end if;
  if exists (select 1 from members where server_id = sid and user_id = me) then
    return jsonb_build_object('server_id', sid, 'status', 'member');
  end if;
  if exists (select 1 from bans where server_id = sid and user_id = me) then
    raise exception 'You''re banned from this server' using errcode = 'GX403';
  end if;
  if srv.require_approval then
    insert into join_requests (server_id, user_id, answers) values (sid, me, coalesce(p_answers, '[]'::jsonb))
    on conflict (server_id, user_id) do update set answers = excluded.answers, status = 'pending', created_at = now();
    return jsonb_build_object('server_id', sid, 'status', 'pending');
  end if;
  perform add_member(sid, me);
  return jsonb_build_object('server_id', sid, 'status', 'joined');
end $$;

create or replace function public.discover_servers(p_query text default '', p_category text default null,
                                                   p_limit integer default 24, p_offset integer default 0)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', s.id, 'name', s.name, 'icon_url', s.icon_url, 'banner_url', s.banner_url,
    'description', s.description, 'member_count', s.member_count, 'tags', s.tags, 'category', s.category,
    'require_approval', s.require_approval, 'theme', s.theme, 'is_member', public.is_member(s.id))
  from servers s
  where s.is_public
    and (p_category is null or s.category = p_category)
    and (coalesce(btrim(p_query), '') = ''
         or s.name ilike '%' || replace(replace(btrim(p_query), '%', '\%'), '_', '\_') || '%'
         or s.description ilike '%' || replace(replace(btrim(p_query), '%', '\%'), '_', '\_') || '%'
         or lower(btrim(p_query)) = any(s.tags))
  order by s.member_count desc, s.created_at
  limit least(greatest(coalesce(p_limit, 24), 1), 60)
  offset greatest(coalesce(p_offset, 0), 0)
$$;

create or replace function public.leave_server(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if exists (select 1 from servers where id = sid and owner_id = me) then
    raise exception 'You own this server. Transfer ownership or delete the server instead.';
  end if;
  delete from members where server_id = sid and user_id = me;
end $$;

create or replace function public.transfer_ownership(sid uuid, new_owner uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from servers where id = sid and owner_id = me) then
    raise exception 'Only the owner can transfer the server' using errcode = 'GX403';
  end if;
  if not is_member_of(sid, new_owner) or (select is_bot from profiles where id = new_owner) then
    raise exception 'The new owner has to be a member of the server';
  end if;
  update servers set owner_id = new_owner where id = sid;
  perform log_action(sid, 'server.transfer_ownership', 'user', new_owner::text, null);
end $$;

-- ---------------------------------------------------------------------
-- Moderation
-- ---------------------------------------------------------------------
create or replace function public.notify_moderation(uid uuid, sid uuid, act text, reason text, extra jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into notifications (user_id, type, actor_id, server_id, data)
  values (uid, 'moderation', auth.uid(), case when act in ('kick', 'ban') then null else sid end,
          jsonb_build_object('action', act, 'reason', reason, 'server_id', sid,
                             'server_name', (select name from servers where id = sid)) || extra)
$$;

create or replace function public.kick_member(sid uuid, target uuid, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'KICK_MEMBERS') then raise exception 'You don''t have permission to kick members' using errcode = 'GX403'; end if;
  if not can_moderate(sid, target) then raise exception 'You can only kick members whose highest role is below yours' using errcode = 'GX403'; end if;
  if not is_member_of(sid, target) then raise exception 'That person isn''t in this server'; end if;
  delete from members where server_id = sid and user_id = target;
  perform log_action(sid, 'member.kick', 'user', target::text, reason);
  perform notify_moderation(target, sid, 'kick', reason);
end $$;

create or replace function public.ban_member(sid uuid, target uuid, reason text default null, delete_hours integer default 0)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'BAN_MEMBERS') then raise exception 'You don''t have permission to ban members' using errcode = 'GX403'; end if;
  if is_member_of(sid, target) and not can_moderate(sid, target) then
    raise exception 'You can only ban members whose highest role is below yours' using errcode = 'GX403';
  end if;
  if target = auth.uid() or target = (select owner_id from servers where id = sid) then
    raise exception 'You can''t ban this person' using errcode = 'GX403';
  end if;
  insert into bans (server_id, user_id, reason, banned_by) values (sid, target, reason, auth.uid())
  on conflict (server_id, user_id) do update set reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  delete from members where server_id = sid and user_id = target;
  if coalesce(delete_hours, 0) > 0 then
    delete from messages where server_id = sid and author_id = target
      and created_at > now() - make_interval(hours => least(delete_hours, 168));
  end if;
  perform log_action(sid, 'member.ban', 'user', target::text, reason, jsonb_build_object('delete_hours', delete_hours));
  perform notify_moderation(target, sid, 'ban', reason);
end $$;

create or replace function public.unban_member(sid uuid, target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'BAN_MEMBERS') then raise exception 'You don''t have permission to unban members' using errcode = 'GX403'; end if;
  delete from bans where server_id = sid and user_id = target;
  perform log_action(sid, 'member.unban', 'user', target::text, null);
end $$;

create or replace function public.timeout_member(sid uuid, target uuid, minutes integer, reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'MODERATE_MEMBERS') then raise exception 'You don''t have permission to time out members' using errcode = 'GX403'; end if;
  if not can_moderate(sid, target) then raise exception 'You can only time out members whose highest role is below yours' using errcode = 'GX403'; end if;
  if server_permissions(sid, target) = perm_all() then raise exception 'Admins can''t be timed out' using errcode = 'GX403'; end if;
  update members
     set timeout_until = case when coalesce(minutes, 0) <= 0 then null else now() + make_interval(mins => least(minutes, 40320)) end
   where server_id = sid and user_id = target;
  if not found then raise exception 'That person isn''t in this server'; end if;
  perform log_action(sid, case when coalesce(minutes, 0) <= 0 then 'member.timeout_remove' else 'member.timeout' end,
                     'user', target::text, reason, jsonb_build_object('minutes', minutes));
  if coalesce(minutes, 0) > 0 then
    perform notify_moderation(target, sid, 'timeout', reason, jsonb_build_object('minutes', minutes));
  end if;
end $$;

create or replace function public.warn_member(sid uuid, target uuid, reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'MODERATE_MEMBERS') then raise exception 'You don''t have permission to warn members' using errcode = 'GX403'; end if;
  if not can_moderate(sid, target) then raise exception 'You can only warn members whose highest role is below yours' using errcode = 'GX403'; end if;
  insert into warnings (server_id, user_id, moderator_id, reason) values (sid, target, auth.uid(), reason);
  perform log_action(sid, 'member.warn', 'user', target::text, reason);
  perform notify_moderation(target, sid, 'warn', reason);
end $$;

create or replace function public.set_member_roles(sid uuid, target uuid, role_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  current_ids uuid[];
begin
  perform require_uid();
  select coalesce(array_agg(role_id), '{}') into current_ids from member_roles where server_id = sid and user_id = target;
  foreach rid in array current_ids loop
    if not (rid = any(role_ids)) then
      if not can_assign_role(sid, target, rid) then raise exception 'You can''t remove one of these roles' using errcode = 'GX403'; end if;
      delete from member_roles where user_id = target and role_id = rid;
    end if;
  end loop;
  foreach rid in array role_ids loop
    if not (rid = any(current_ids)) then
      if not can_assign_role(sid, target, rid) then raise exception 'You can''t give one of these roles' using errcode = 'GX403'; end if;
      insert into member_roles (server_id, user_id, role_id) values (sid, target, rid);
    end if;
  end loop;
end $$;

create or replace function public.reorder_roles(sid uuid, role_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare
  i integer;
  my_rank integer;
  n integer := cardinality(role_ids);
begin
  perform require_uid();
  if not has_server_perm(sid, 'MANAGE_ROLES') then raise exception 'You don''t have permission to manage roles' using errcode = 'GX403'; end if;
  my_rank := member_rank(sid, auth.uid());
  -- role_ids is ordered from highest to lowest
  for i in 1 .. n loop
    if (select position from roles where id = role_ids[i] and server_id = sid) >= my_rank then
      raise exception 'You can only move roles below your highest role' using errcode = 'GX403';
    end if;
  end loop;
  for i in 1 .. n loop
    update roles set position = n - i + 1 where id = role_ids[i] and server_id = sid and not is_default;
  end loop;
  if (select max(position) from roles where server_id = sid and id = any(role_ids)) >= my_rank
     and not exists (select 1 from servers where id = sid and owner_id = auth.uid()) then
    raise exception 'That order would put a role above your own' using errcode = 'GX403';
  end if;
end $$;

create or replace function public.respond_join_request(sid uuid, target uuid, approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_uid();
  if not has_server_perm(sid, 'KICK_MEMBERS') then raise exception 'You don''t have permission to review applications' using errcode = 'GX403'; end if;
  update join_requests set status = case when approve then 'approved' else 'rejected' end
   where server_id = sid and user_id = target and status = 'pending';
  if not found then raise exception 'That application isn''t pending anymore'; end if;
  if approve then perform add_member(sid, target); end if;
  perform log_action(sid, case when approve then 'application.approve' else 'application.reject' end, 'user', target::text, null);
  insert into notifications (user_id, type, actor_id, server_id, data)
  values (target, 'application', auth.uid(), case when approve then sid else null end,
          jsonb_build_object('approved', approve, 'server_name', (select name from servers where id = sid), 'server_id', sid));
end $$;

create or replace function public.submit_ban_appeal(sid uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not exists (select 1 from bans where server_id = sid and user_id = me) then raise exception 'You aren''t banned from this server'; end if;
  if exists (select 1 from ban_appeals where server_id = sid and user_id = me and status = 'pending') then
    raise exception 'You already have an appeal waiting for review';
  end if;
  if exists (select 1 from ban_appeals where server_id = sid and user_id = me and created_at > now() - interval '7 days') then
    raise exception 'You can appeal once a week';
  end if;
  insert into ban_appeals (server_id, user_id, reason) values (sid, me, p_reason);
end $$;

create or replace function public.my_bans()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('server_id', b.server_id, 'server_name', s.name, 'icon_url', s.icon_url,
                            'reason', b.reason, 'created_at', b.created_at,
                            'appeal', (select to_jsonb(a) from ban_appeals a where a.server_id = b.server_id and a.user_id = b.user_id order by created_at desc limit 1))
  from bans b join servers s on s.id = b.server_id
  where b.user_id = auth.uid()
$$;

create or replace function public.review_ban_appeal(appeal_id uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  ap record;
begin
  perform require_uid();
  select * into ap from ban_appeals where id = appeal_id;
  if not found then raise exception 'That appeal doesn''t exist'; end if;
  if not has_server_perm(ap.server_id, 'BAN_MEMBERS') then raise exception 'You don''t have permission to review appeals' using errcode = 'GX403'; end if;
  update ban_appeals set status = case when accept then 'accepted' else 'denied' end, reviewed_by = auth.uid() where id = appeal_id;
  if accept then delete from bans where server_id = ap.server_id and user_id = ap.user_id; end if;
  perform log_action(ap.server_id, case when accept then 'appeal.accept' else 'appeal.deny' end, 'user', ap.user_id::text, null);
  insert into notifications (user_id, type, actor_id, data)
  values (ap.user_id, 'appeal', auth.uid(), jsonb_build_object('accepted', accept, 'server_id', ap.server_id,
          'server_name', (select name from servers where id = ap.server_id)));
end $$;

-- ---------------------------------------------------------------------
-- Channels
-- ---------------------------------------------------------------------
create or replace function public.create_channel(sid uuid, p_name text, p_type text, p_parent uuid default null,
                                                 p_private boolean default false, p_role_ids uuid[] default '{}',
                                                 p_topic text default null, p_temporary boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  cid uuid;
  everyone uuid;
  pos integer;
  view_bits bigint := perm_bit('VIEW_CHANNEL') | perm_bit('CONNECT');
  deny_bits bigint := 0;
  rid uuid;
begin
  if p_type not in ('text', 'voice', 'announcement', 'forum', 'media', 'category') then
    raise exception 'Unknown channel type';
  end if;
  if p_temporary then
    if p_type <> 'voice' then raise exception 'Only voice rooms can be temporary'; end if;
    if not has_server_perm(sid, 'CONNECT') then raise exception 'You can''t create voice rooms here' using errcode = 'GX403'; end if;
    perform check_rate_limit('temp_voice', 10, 3600);
  elsif not (has_server_perm(sid, 'MANAGE_CHANNELS') or (p_parent is not null and has_channel_perm(p_parent, 'MANAGE_CHANNELS'))) then
    raise exception 'You don''t have permission to create channels' using errcode = 'GX403';
  end if;
  if p_parent is not null and not exists (select 1 from channels where id = p_parent and server_id = sid and type = 'category') then
    raise exception 'That category doesn''t exist';
  end if;
  if p_type = 'category' then p_parent := null; end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then raise exception 'Give the channel a name'; end if;
  select coalesce(max(position) + 1, 0) into pos from channels
   where server_id = sid and parent_id is not distinct from p_parent and (p_type = 'category') = (type = 'category');
  insert into channels (server_id, parent_id, type, name, topic, position, synced, temporary, expires_at, owner_id)
  values (sid, p_parent, p_type, btrim(p_name), p_topic, pos,
          p_parent is not null and not p_private and p_type <> 'announcement',
          p_temporary, case when p_temporary then now() + interval '24 hours' end,
          case when p_temporary then me end)
  returning id into cid;

  select id into everyone from roles where server_id = sid and is_default;
  -- Unsynced channels inside a category start with a copy of its overrides
  if p_parent is not null and (p_private or p_type = 'announcement') then
    insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
    select cid, sid, target_type, target_id, allow, deny from channel_overrides where channel_id = p_parent;
  end if;
  if p_private then deny_bits := deny_bits | perm_bit('VIEW_CHANNEL'); end if;
  if p_type = 'announcement' then deny_bits := deny_bits | perm_bit('SEND_MESSAGES'); end if;
  if deny_bits <> 0 then
    insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
    values (cid, sid, 'role', everyone, 0, deny_bits)
    on conflict (channel_id, target_id) do update set deny = channel_overrides.deny | excluded.deny,
                                                     allow = channel_overrides.allow & ~excluded.deny;
  end if;
  if p_private then
    foreach rid in array coalesce(p_role_ids, '{}') loop
      if exists (select 1 from roles where id = rid and server_id = sid and not is_default) then
        insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
        values (cid, sid, 'role', rid, view_bits, 0)
        on conflict (channel_id, target_id) do update set allow = channel_overrides.allow | excluded.allow;
      end if;
    end loop;
    if channel_permissions(cid, me) = 0 then
      insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
      values (cid, sid, 'member', me, view_bits, 0)
      on conflict (channel_id, target_id) do nothing;
    end if;
  end if;
  return cid;
end $$;

create or replace function public.set_channel_sync(cid uuid, p_synced boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  ch record;
begin
  perform require_uid();
  select * into ch from channels where id = cid;
  if not found or ch.server_id is null then raise exception 'Channel not found'; end if;
  if not (has_server_perm(ch.server_id, 'MANAGE_ROLES') or has_channel_perm(cid, 'MANAGE_ROLES')) then
    raise exception 'You don''t have permission to manage channel permissions' using errcode = 'GX403';
  end if;
  if p_synced then
    if ch.parent_id is null then raise exception 'This channel isn''t in a category'; end if;
    delete from channel_overrides where channel_id = cid;
    update channels set synced = true where id = cid;
  elsif ch.synced then
    if ch.parent_id is not null then
      insert into channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
      select cid, ch.server_id, target_type, target_id, allow, deny from channel_overrides where channel_id = ch.parent_id
      on conflict do nothing;
    end if;
    update channels set synced = false where id = cid;
  end if;
end $$;

create or replace function public.reorder_channels(sid uuid, items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
begin
  perform require_uid();
  if not has_server_perm(sid, 'MANAGE_CHANNELS') then
    raise exception 'You don''t have permission to manage channels' using errcode = 'GX403';
  end if;
  for it in select * from jsonb_array_elements(items) loop
    update channels
       set position = (it->>'position')::integer,
           parent_id = case when type = 'category' then null else safe_uuid(it->>'parent_id') end,
           synced = case when safe_uuid(it->>'parent_id') is distinct from parent_id then false else synced end
     where id = safe_uuid(it->>'id') and server_id = sid and type <> 'thread';
  end loop;
end $$;

create or replace function public.create_thread(p_parent uuid, p_name text, p_starter uuid default null,
                                                p_content text default null, p_tags text[] default '{}',
                                                p_attachments jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  parent record;
  tid uuid;
  mid uuid;
begin
  select * into parent from channels where id = p_parent;
  if not found or parent.type not in ('text', 'announcement', 'forum', 'media') then
    raise exception 'Threads can only be started in text, announcement, forum and media channels';
  end if;
  if not has_channel_perm(p_parent, 'CREATE_THREADS') then
    raise exception 'You don''t have permission to start threads here' using errcode = 'GX403';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then raise exception 'Give the thread a name'; end if;
  if parent.type in ('forum', 'media') and coalesce(btrim(p_content), '') = '' and jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) = 0 then
    raise exception 'Forum posts need a message';
  end if;
  if p_starter is not null then
    if not exists (select 1 from messages where id = p_starter and channel_id = p_parent) then
      raise exception 'That message isn''t in this channel';
    end if;
    if exists (select 1 from channels where starter_message_id = p_starter) then
      raise exception 'This message already has a thread';
    end if;
  end if;
  perform check_rate_limit('create_thread', 30, 3600);
  insert into channels (server_id, parent_id, type, name, owner_id, starter_message_id, applied_tags, position)
  values (parent.server_id, p_parent, 'thread', left(btrim(p_name), 100), me, p_starter, coalesce(p_tags, '{}'), 0)
  returning id into tid;
  if p_starter is not null then
    update messages set thread_id = tid where id = p_starter;
  end if;
  if parent.type not in ('forum', 'media') then
    insert into messages (channel_id, author_id, type, content)
    values (p_parent, me, 'thread', left(btrim(p_name), 100))
    returning id into mid;
    update messages set thread_id = tid where id = mid;
  end if;
  if coalesce(btrim(p_content), '') <> '' or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 0 then
    insert into messages (channel_id, author_id, content, attachments)
    values (tid, me, coalesce(p_content, ''), coalesce(p_attachments, '[]'::jsonb));
  end if;
  return tid;
end $$;
