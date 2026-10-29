-- =====================================================================
--  Galaxy — database schema for Supabase (Postgres 15+)
--
--  Safe to run more than once: it creates what is missing and replaces
--  functions, triggers and policies with the current version.
--
--  How to apply: Supabase dashboard → SQL Editor → New query → paste
--  this whole file → Run.  (Or: psql "$DATABASE_URL" -f schema.sql)
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Operator-configurable limits. These apply to every account equally:
-- Galaxy has no paid tiers. Raise them here if your infrastructure
-- (Supabase plan, storage, bandwidth) allows it.
-- ---------------------------------------------------------------------
create table if not exists public.app_config (
  key   text primary key,
  value jsonb not null
);

insert into public.app_config (key, value) values
  ('max_message_length',        '4000'),
  ('max_upload_bytes',          '52428800'),   -- 50 MB (Supabase free plan maximum)
  ('user_storage_quota_bytes',  '524288000'),  -- 500 MB of attachments per account
  ('max_emojis_per_server',     '250'),
  ('max_stickers_per_server',   '60'),
  ('max_sounds_per_server',     '48'),
  ('max_servers_per_user',      '200'),
  ('max_group_dm_size',         '10'),
  ('rate_limit_messages',       '8'),
  ('rate_limit_window_seconds', '5')
on conflict (key) do nothing;

create or replace function public.config_int(k text, fallback integer)
returns integer language sql stable as $$
  select coalesce((select (value #>> '{}')::integer from public.app_config where key = k), fallback)
$$;

-- Short random codes for invites (no look-alike characters).
create or replace function public.random_code(len integer)
returns text language plpgsql volatile security definer set search_path = public as $$
declare
  alphabet constant text := 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea := extensions.gen_random_bytes(len);
  result text := '';
  i integer;
begin
  for i in 0 .. len - 1 loop
    result := result || substr(alphabet, (get_byte(bytes, i) % length(alphabet)) + 1, 1);
  end loop;
  return result;
end $$;

create or replace function public.safe_uuid(t text)
returns uuid language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Permission bits (mirrored in src/lib/perms.ts)
-- ---------------------------------------------------------------------
create or replace function public.perm_bit(p text)
returns bigint language sql immutable parallel safe as $$
  select (1::bigint << (case p
    when 'VIEW_CHANNEL'       then 0
    when 'SEND_MESSAGES'      then 1
    when 'MANAGE_MESSAGES'    then 2
    when 'MANAGE_CHANNELS'    then 3
    when 'MANAGE_ROLES'       then 4
    when 'MANAGE_SERVER'      then 5
    when 'KICK_MEMBERS'       then 6
    when 'BAN_MEMBERS'        then 7
    when 'CREATE_INVITE'      then 8
    when 'ATTACH_FILES'       then 9
    when 'ADD_REACTIONS'      then 10
    when 'MENTION_EVERYONE'   then 11
    when 'CONNECT'            then 12
    when 'SPEAK'              then 13
    when 'VIDEO'              then 14
    when 'MUTE_MEMBERS'       then 15
    when 'MOVE_MEMBERS'       then 16
    when 'MANAGE_EXPRESSIONS' then 17
    when 'MANAGE_EVENTS'      then 18
    when 'MANAGE_WEBHOOKS'    then 19
    when 'MODERATE_MEMBERS'   then 20
    when 'VIEW_AUDIT_LOG'     then 21
    when 'ADMINISTRATOR'      then 22
    when 'READ_HISTORY'       then 23
    when 'CREATE_THREADS'     then 24
    when 'SEND_IN_THREADS'    then 25
    when 'USE_SOUNDBOARD'     then 26
    when 'STREAM'             then 27
    when 'CHANGE_NICKNAME'    then 28
    when 'MANAGE_NICKNAMES'   then 29
  end))
$$;

create or replace function public.perm_all()
returns bigint language sql immutable parallel safe as $$
  select (1::bigint << 30) - 1
$$;

create or replace function public.perm_default()
returns bigint language sql immutable parallel safe as $$
  select public.perm_bit('VIEW_CHANNEL') | public.perm_bit('SEND_MESSAGES') | public.perm_bit('CREATE_INVITE')
       | public.perm_bit('ATTACH_FILES') | public.perm_bit('ADD_REACTIONS') | public.perm_bit('CONNECT')
       | public.perm_bit('SPEAK') | public.perm_bit('VIDEO') | public.perm_bit('READ_HISTORY')
       | public.perm_bit('CREATE_THREADS') | public.perm_bit('SEND_IN_THREADS') | public.perm_bit('USE_SOUNDBOARD')
       | public.perm_bit('STREAM') | public.perm_bit('CHANGE_NICKNAME')
$$;

create or replace function public.perm_dm()
returns bigint language sql immutable parallel safe as $$
  select public.perm_bit('VIEW_CHANNEL') | public.perm_bit('SEND_MESSAGES') | public.perm_bit('ATTACH_FILES')
       | public.perm_bit('ADD_REACTIONS') | public.perm_bit('CONNECT') | public.perm_bit('SPEAK')
       | public.perm_bit('VIDEO') | public.perm_bit('READ_HISTORY') | public.perm_bit('STREAM')
       | public.perm_bit('USE_SOUNDBOARD') | public.perm_bit('MENTION_EVERYONE')
$$;
