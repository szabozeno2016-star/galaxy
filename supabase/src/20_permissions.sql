-- =====================================================================
--  Permission engine
--
--  Order of evaluation for a server channel (same idea as Discord):
--    1. not a member                      -> nothing
--    2. server owner or ADMINISTRATOR     -> everything
--    3. @everyone role | all member roles -> base permissions
--    4. channel overrides: @everyone, then roles (deny then allow),
--       then the member's own override
--    5. timed-out members keep only VIEW_CHANNEL + READ_HISTORY
--    6. no VIEW_CHANNEL                   -> nothing
--  Channels inside a category use the category's overrides while
--  "synced" is true. Threads inherit from their parent channel and use
--  SEND_IN_THREADS for sending.
--
--  All checks run in the database. The app only reads the results to
--  decide which buttons to show.
-- =====================================================================

create or replace function public.require_uid()
returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then
    raise exception 'You need to be signed in' using errcode = 'GX401';
  end if;
  return u;
end $$;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false)
$$;

create or replace function public.is_member(sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where server_id = sid and user_id = auth.uid())
$$;

create or replace function public.is_member_of(sid uuid, uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where server_id = sid and user_id = uid)
$$;

create or replace function public.channel_server(cid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select server_id from channels where id = cid
$$;

create or replace function public.is_owner(sid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from servers where id = sid and owner_id = auth.uid())
$$;

create or replace function public.is_recipient(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from channel_recipients where channel_id = cid and user_id = auth.uid())
$$;

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from friends where user_id = a and friend_id = b)
$$;

create or replace function public.shares_server(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from members m1 join members m2 on m2.server_id = m1.server_id
    where m1.user_id = a and m2.user_id = b
  )
$$;

create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from blocks
    where (user_id = a and blocked_id = b) or (user_id = b and blocked_id = a)
  )
$$;

create or replace function public.server_permissions(sid uuid, uid uuid)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare
  srv_owner uuid;
  p bigint;
begin
  if uid is null or sid is null then return 0; end if;
  select owner_id into srv_owner from servers where id = sid;
  if not found then return 0; end if;
  if not exists (select 1 from members where server_id = sid and user_id = uid) then return 0; end if;
  if srv_owner = uid then return perm_all(); end if;
  select coalesce(bit_or(r.permissions), 0) into p
  from roles r
  where r.server_id = sid
    and (r.is_default or r.id in (select mr.role_id from member_roles mr where mr.server_id = sid and mr.user_id = uid));
  if (p & perm_bit('ADMINISTRATOR')) <> 0 then return perm_all(); end if;
  return p;
end $$;

-- Highest role position of a member (owner ranks above everyone).
create or replace function public.member_rank(sid uuid, uid uuid)
returns integer language sql stable security definer set search_path = public as $$
  select case
    when (select owner_id from servers where id = sid) = uid then 2147483647
    else coalesce((
      select max(r.position) from roles r
      join member_roles mr on mr.role_id = r.id
      where mr.server_id = sid and mr.user_id = uid
    ), 0)
  end
$$;

create or replace function public.channel_permissions(cid uuid, uid uuid)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare
  ch record;
  src uuid;
  base bigint;
  p bigint;
  everyone_role uuid;
  a bigint;
  d bigint;
  tmo timestamptz;
begin
  if uid is null or cid is null then return 0; end if;
  select * into ch from channels where id = cid;
  if not found then return 0; end if;

  -- Direct messages and group DMs
  if ch.server_id is null then
    if not exists (select 1 from channel_recipients where channel_id = cid and user_id = uid) then
      return 0;
    end if;
    p := perm_dm();
    if ch.type = 'dm' and exists (
      select 1 from channel_recipients r
      where r.channel_id = cid and r.user_id <> uid and is_blocked_between(uid, r.user_id)
    ) then
      p := p & ~(perm_bit('SEND_MESSAGES') | perm_bit('CONNECT') | perm_bit('ADD_REACTIONS'));
    end if;
    if ch.type = 'group_dm' and ch.owner_id = uid then
      p := p | perm_bit('MANAGE_CHANNELS') | perm_bit('KICK_MEMBERS');
    end if;
    return p;
  end if;

  -- Threads inherit from the parent channel
  if ch.type = 'thread' then
    p := channel_permissions(ch.parent_id, uid);
    if p = 0 then return 0; end if;
    p := p & ~perm_bit('SEND_MESSAGES');
    if (p & perm_bit('SEND_IN_THREADS')) <> 0
       and (not ch.locked or (p & perm_bit('MANAGE_MESSAGES')) <> 0) then
      p := p | perm_bit('SEND_MESSAGES');
    end if;
    return p;
  end if;

  base := server_permissions(ch.server_id, uid);
  if base = 0 then return 0; end if;
  if base = perm_all() then return base; end if;

  src := case when ch.parent_id is not null and ch.synced then ch.parent_id else cid end;
  select id into everyone_role from roles where server_id = ch.server_id and is_default;
  p := base;

  select o.allow, o.deny into a, d from channel_overrides o
  where o.channel_id = src and o.target_id = everyone_role;
  if found then p := (p & ~d) | a; end if;

  select coalesce(bit_or(o.allow), 0), coalesce(bit_or(o.deny), 0) into a, d
  from channel_overrides o
  join member_roles mr on mr.role_id = o.target_id and mr.user_id = uid and mr.server_id = ch.server_id
  where o.channel_id = src and o.target_type = 'role';
  p := (p & ~d) | a;

  select o.allow, o.deny into a, d from channel_overrides o
  where o.channel_id = src and o.target_type = 'member' and o.target_id = uid;
  if found then p := (p & ~d) | a; end if;

  select timeout_until into tmo from members where server_id = ch.server_id and user_id = uid;
  if tmo is not null and tmo > now() then
    p := p & (perm_bit('VIEW_CHANNEL') | perm_bit('READ_HISTORY'));
  end if;

  if (p & perm_bit('VIEW_CHANNEL')) = 0 then return 0; end if;
  return p;
end $$;

create or replace function public.has_channel_perm(cid uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.channel_permissions(cid, auth.uid()) & public.perm_bit(perm)) <> 0
$$;

create or replace function public.has_channel_perm_text(cid text, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((public.channel_permissions(public.safe_uuid(cid), auth.uid()) & public.perm_bit(perm)) <> 0, false)
$$;

create or replace function public.has_server_perm(sid uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.server_permissions(sid, auth.uid()) & public.perm_bit(perm)) <> 0
$$;

create or replace function public.can_view_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.channel_permissions(cid, auth.uid()) <> 0
$$;

create or replace function public.can_read_channel(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (public.channel_permissions(cid, auth.uid())
          & (public.perm_bit('VIEW_CHANNEL') | public.perm_bit('READ_HISTORY')))
       = (public.perm_bit('VIEW_CHANNEL') | public.perm_bit('READ_HISTORY'))
$$;

-- Every channel the signed-in user can see, with their permissions.
-- The app calls this once at start-up and whenever roles change.
create or replace function public.my_channel_perms()
returns table (channel_id uuid, perms bigint)
language sql stable security definer set search_path = public as $$
  select c.id, public.channel_permissions(c.id, auth.uid())
  from channels c
  where c.server_id in (select m.server_id from members m where m.user_id = auth.uid())
     or c.id in (select r.channel_id from channel_recipients r where r.user_id = auth.uid())
$$;

create or replace function public.my_server_perms()
returns table (server_id uuid, perms bigint, rank integer)
language sql stable security definer set search_path = public as $$
  select m.server_id, public.server_permissions(m.server_id, auth.uid()), public.member_rank(m.server_id, auth.uid())
  from members m where m.user_id = auth.uid()
$$;

-- Can the signed-in user moderate `target` in this server?
create or replace function public.can_moderate(sid uuid, target uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and target <> auth.uid()
     and target <> (select owner_id from servers where id = sid)
     and public.member_rank(sid, auth.uid()) > public.member_rank(sid, target)
$$;

-- Role management: needs MANAGE_ROLES, the role must sit below your
-- highest role, and you can't hand out permissions you don't have.
create or replace function public.can_edit_role(sid uuid, role_position integer, role_perms bigint)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  mine bigint;
begin
  if me is null then return false; end if;
  mine := server_permissions(sid, me);
  if (mine & perm_bit('MANAGE_ROLES')) = 0 then return false; end if;
  if exists (select 1 from servers where id = sid and owner_id = me) then return true; end if;
  if role_position >= member_rank(sid, me) then return false; end if;
  if role_perms is not null and mine <> perm_all() and (role_perms & ~mine) <> 0 then return false; end if;
  return true;
end $$;

create or replace function public.can_assign_role(sid uuid, target uuid, rid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r record;
begin
  if me is null then return false; end if;
  select * into r from roles where id = rid;
  if not found or r.server_id <> sid or r.is_default or r.managed_by_bot is not null then return false; end if;
  if not is_member_of(sid, target) then return false; end if;
  if (server_permissions(sid, me) & perm_bit('MANAGE_ROLES')) = 0 then return false; end if;
  if exists (select 1 from servers where id = sid and owner_id = me) then return true; end if;
  return r.position < member_rank(sid, me);
end $$;

create or replace function public.can_edit_member(sid uuid, target uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p bigint;
begin
  if me is null then return false; end if;
  p := server_permissions(sid, me);
  if target = me then
    return (p & (perm_bit('CHANGE_NICKNAME') | perm_bit('MANAGE_NICKNAMES'))) <> 0;
  end if;
  return (p & perm_bit('MANAGE_NICKNAMES')) <> 0 and can_moderate(sid, target);
end $$;

-- Realtime topics (private channels). Topic formats:
--   global            everyone signed in (online presence)
--   server:<id>       members of that server (voice presence)
--   channel:<id>      people who can see the channel (typing)
--   voice:<id>        people allowed to connect (call signalling)
--   user:<id>         that user reads; friends / DM partners can write
create or replace function public.realtime_allowed(topic text, is_write boolean)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  kind text := split_part(topic, ':', 1);
  target uuid := safe_uuid(split_part(topic, ':', 2));
begin
  if me is null then return false; end if;
  if topic = 'global' then return true; end if;
  if target is null then return false; end if;
  if kind = 'server' then return is_member(target); end if;
  if kind = 'channel' then return can_view_channel(target); end if;
  if kind = 'voice' then return has_channel_perm(target, 'CONNECT'); end if;
  if kind = 'user' then
    if target = me then return true; end if;
    if not is_write then return false; end if;
    return not is_blocked_between(me, target) and (
      are_friends(me, target)
      or exists (
        select 1 from channel_recipients a
        join channel_recipients b on b.channel_id = a.channel_id
        where a.user_id = me and b.user_id = target
      )
    );
  end if;
  return false;
end $$;
