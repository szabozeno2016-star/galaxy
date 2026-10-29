-- =====================================================================
--  Messages: pins, forwarding, read state, unread counts, search
-- =====================================================================

create or replace function public.pin_message(mid uuid, p_pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  msg record;
begin
  select * into msg from messages where id = mid;
  if not found then raise exception 'That message doesn''t exist anymore'; end if;
  if not (has_channel_perm(msg.channel_id, 'MANAGE_MESSAGES')
          or (msg.server_id is null and is_recipient(msg.channel_id))) then
    raise exception 'You don''t have permission to pin messages here' using errcode = 'GX403';
  end if;
  if p_pinned and not msg.pinned
     and (select count(*) from messages where channel_id = msg.channel_id and pinned) >= 250 then
    raise exception 'This channel has the maximum number of pins. Unpin something first.';
  end if;
  update messages set pinned = p_pinned, pinned_at = case when p_pinned then now() end where id = mid;
  if p_pinned and not msg.pinned then
    insert into messages (channel_id, author_id, type, content, reply_to)
    values (msg.channel_id, me, 'pin', '', mid);
  end if;
  if msg.server_id is not null then
    perform log_action(msg.server_id, case when p_pinned then 'message.pin' else 'message.unpin' end, 'message', mid::text, null);
  end if;
end $$;

create or replace function public.forward_message(mid uuid, target_channel uuid, note text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
  msg record;
  author record;
  new_id uuid;
begin
  select * into msg from messages where id = mid;
  if not found or not can_read_channel(msg.channel_id) then
    raise exception 'You can only forward messages you can see';
  end if;
  if not has_channel_perm(target_channel, 'SEND_MESSAGES') then
    raise exception 'You can''t send messages there' using errcode = 'GX403';
  end if;
  select username, display_name, avatar_url into author from profiles where id = msg.author_id;
  insert into messages (channel_id, author_id, type, content, forwarded)
  values (target_channel, me, 'forward', coalesce(note, ''), jsonb_build_object(
    'message_id', msg.id, 'channel_id', msg.channel_id, 'server_id', msg.server_id,
    'content', msg.content, 'attachments', msg.attachments, 'sticker_ids', msg.sticker_ids,
    'created_at', msg.created_at,
    'author', case when author is null then jsonb_build_object('display_name', coalesce(msg.webhook_name, 'Unknown'))
                   else to_jsonb(author) end))
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.mark_read(cid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  if not can_view_channel(cid) then return; end if;
  insert into read_states (user_id, channel_id, last_read_at) values (me, cid, now())
  on conflict (user_id, channel_id) do update set last_read_at = now();
  update notifications set read = true where user_id = me and channel_id = cid and not read;
end $$;

create or replace function public.mark_server_read(sid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  insert into read_states (user_id, channel_id, last_read_at)
  select me, c.id, now() from channels c where c.server_id = sid and channel_permissions(c.id, me) <> 0
  on conflict (user_id, channel_id) do update set last_read_at = now();
  update notifications set read = true where user_id = me and server_id = sid and not read;
end $$;

-- Unread state for every channel with something new
create or replace function public.my_unreads()
returns table (channel_id uuid, last_read_at timestamptz, unread_count integer, mention_count integer)
language sql stable security definer set search_path = public as $$
  with mine as (
    select p.channel_id from public.my_channel_perms() p where p.perms <> 0
  ),
  base as (
    select c.id, c.server_id, c.last_message_at,
           coalesce(rs.last_read_at,
                    (select m.joined_at from members m where m.server_id = c.server_id and m.user_id = auth.uid()),
                    (select r.joined_at from channel_recipients r where r.channel_id = c.id and r.user_id = auth.uid())) as seen
    from channels c
    left join read_states rs on rs.channel_id = c.id and rs.user_id = auth.uid()
    where c.id in (select channel_id from mine) and c.last_message_at is not null
  )
  select b.id, b.seen,
         case when b.server_id is null then (
           select count(*)::integer from (
             select 1 from messages m
             where m.channel_id = b.id and m.created_at > b.seen and m.author_id is distinct from auth.uid()
             limit 99) x)
         else 0 end,
         (select count(*)::integer from notifications n
           where n.user_id = auth.uid() and n.channel_id = b.id and not n.read)
  from base b
  where b.last_message_at > b.seen
     or exists (select 1 from notifications n where n.user_id = auth.uid() and n.channel_id = b.id and not n.read)
$$;

-- Search only ever looks inside channels the caller can read.
create or replace function public.search_messages(
  p_query text default '', p_server uuid default null, p_channel uuid default null,
  p_author uuid default null, p_has text default null, p_mentions uuid default null,
  p_before timestamptz default null, p_after timestamptz default null, p_pinned boolean default null,
  p_limit integer default 25, p_offset integer default 0)
returns setof public.messages language sql stable security definer set search_path = public as $$
  with readable as (
    select p.channel_id from public.my_channel_perms() p
    where (p.perms & (public.perm_bit('VIEW_CHANNEL') | public.perm_bit('READ_HISTORY')))
        = (public.perm_bit('VIEW_CHANNEL') | public.perm_bit('READ_HISTORY'))
  ),
  q as (select btrim(coalesce(p_query, '')) as text)
  select m.* from messages m, q
  where m.channel_id in (select channel_id from readable)
    and (p_server is null or m.server_id = p_server)
    and (p_channel is null or m.channel_id = p_channel)
    and (p_author is null or m.author_id = p_author)
    and (q.text = ''
         or m.tsv @@ websearch_to_tsquery('simple', q.text)
         or m.content ilike '%' || replace(replace(replace(q.text, '\', '\\'), '%', '\%'), '_', '\_') || '%')
    and (p_has is null
         or (p_has = 'file' and jsonb_array_length(m.attachments) > 0)
         or (p_has = 'image' and exists (select 1 from jsonb_array_elements(m.attachments) a where a->>'type' like 'image/%'))
         or (p_has = 'video' and exists (select 1 from jsonb_array_elements(m.attachments) a where a->>'type' like 'video/%'))
         or (p_has = 'sound' and exists (select 1 from jsonb_array_elements(m.attachments) a where a->>'type' like 'audio/%'))
         or (p_has = 'link' and m.content ~* 'https?://')
         or (p_has = 'poll' and m.poll is not null)
         or (p_has = 'sticker' and cardinality(m.sticker_ids) > 0))
    and (p_mentions is null or p_mentions = any(m.mentions))
    and (p_before is null or m.created_at < p_before)
    and (p_after is null or m.created_at > p_after)
    and (p_pinned is null or m.pinned = p_pinned)
    and m.type in ('default', 'reply', 'forward', 'command')
  order by m.created_at desc
  limit least(greatest(coalesce(p_limit, 25), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0)
$$;

create or replace function public.search_files(p_query text default '', p_server uuid default null, p_limit integer default 30)
returns setof public.attachments language sql stable security definer set search_path = public as $$
  select a.* from attachments a
  where a.channel_id in (select p.channel_id from public.my_channel_perms() p
                         where (p.perms & public.perm_bit('READ_HISTORY')) <> 0)
    and (p_server is null or a.channel_id in (select id from channels where server_id = p_server))
    and (coalesce(btrim(p_query), '') = '' or a.name ilike '%' || btrim(p_query) || '%')
  order by a.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100)
$$;

-- Reports (moderators of the server, or platform admins)
create or replace function public.resolve_report(rid uuid, p_status text, p_resolution text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  rep record;
begin
  perform require_uid();
  select * into rep from reports where id = rid;
  if not found then raise exception 'That report doesn''t exist'; end if;
  if not (is_platform_admin() or (rep.server_id is not null and has_server_perm(rep.server_id, 'MANAGE_MESSAGES'))) then
    raise exception 'You can''t review this report' using errcode = 'GX403';
  end if;
  if p_status not in ('resolved', 'dismissed', 'open') then raise exception 'Unknown status'; end if;
  update reports set status = p_status, resolution = p_resolution, resolved_by = auth.uid() where id = rid;
  if rep.server_id is not null then
    perform log_action(rep.server_id, 'report.' || p_status, 'report', rid::text, p_resolution);
  end if;
end $$;
