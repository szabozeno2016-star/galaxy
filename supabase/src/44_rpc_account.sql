-- =====================================================================
--  Account: sessions, export, deletion
-- =====================================================================

create or replace function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = public as $$
  select lower(btrim(p_username)) ~ '^[a-z0-9_.]{2,32}$'
     and not exists (select 1 from profiles where username = lower(btrim(p_username)) and id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
$$;

create or replace function public.my_sessions()
returns table (id uuid, created_at timestamptz, updated_at timestamptz, user_agent text, ip text, is_current boolean)
language sql stable security definer set search_path = public, auth as $$
  select s.id, s.created_at, s.updated_at, s.user_agent, host(s.ip),
         s.id::text = coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'session_id', '')
  from auth.sessions s
  where s.user_id = auth.uid()
  order by s.updated_at desc nulls last
$$;

create or replace function public.revoke_session(p_session uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  perform require_uid();
  delete from auth.sessions where id = p_session and user_id = auth.uid();
end $$;

create or replace function public.export_my_data()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_uid();
begin
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from profiles p where p.id = me),
    'settings', (select to_jsonb(s) from user_settings s where s.user_id = me),
    'friends', coalesce((select jsonb_agg(jsonb_build_object('user_id', f.friend_id, 'username', p.username, 'since', f.created_at))
                         from friends f join profiles p on p.id = f.friend_id where f.user_id = me), '[]'::jsonb),
    'blocked', coalesce((select jsonb_agg(b.blocked_id) from blocks b where b.user_id = me), '[]'::jsonb),
    'servers', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'owner', s.owner_id = me,
                                                             'nickname', m.nickname, 'joined_at', m.joined_at))
                         from members m join servers s on s.id = m.server_id where m.user_id = me), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(x) from (
                           select jsonb_build_object('id', id, 'channel_id', channel_id, 'server_id', server_id,
                                                     'content', content, 'attachments', attachments, 'created_at', created_at,
                                                     'edited_at', edited_at) as x
                           from messages where author_id = me order by created_at desc limit 20000) t), '[]'::jsonb),
    'reports_filed', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'target_type', target_type, 'reason', reason,
                                                                   'status', status, 'created_at', created_at))
                               from reports where reporter_id = me), '[]'::jsonb),
    'bots', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at))
                      from bot_apps where owner_id = me), '[]'::jsonb)
  );
end $$;

-- Deletes the account for good: profile, servers you own, memberships,
-- friends and settings. Messages you sent stay but show "Deleted user".
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := require_uid();
begin
  delete from profiles where id in (select id from bot_apps where owner_id = me);
  delete from auth.users where id = me;
  delete from profiles where id = me;
end $$;
