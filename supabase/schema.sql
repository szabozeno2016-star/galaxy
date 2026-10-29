-- GENERATED from supabase/src/*.sql by scripts/build-schema.sh — edit those files, not this one.

-- ---- 00_setup.sql ----
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

-- ---- 10_tables.sql ----
-- =====================================================================
--  Tables
-- =====================================================================

-- Public profile. Humans get one automatically when they sign up
-- (trigger on auth.users); bots get one when they are created.
create table if not exists public.profiles (
  id                        uuid primary key,
  username                  text not null,
  display_name              text,
  avatar_url                text,
  banner_url                text,
  banner_color              text default '#8F5BFF',
  accent_color              text,
  theme_colors              text[],
  bio                       text not null default '',
  pronouns                  text not null default '',
  status                    text not null default 'online',
  custom_status             text,
  custom_status_emoji       text,
  custom_status_expires_at  timestamptz,
  avatar_decoration         text,
  profile_effect            text,
  nameplate                 text,
  name_style                jsonb not null default '{}'::jsonb,
  widgets                   jsonb not null default '{}'::jsonb,
  is_bot                    boolean not null default false,
  bot_owner_id              uuid,
  is_admin                  boolean not null default false,
  created_at                timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[a-z0-9_.]{2,32}$'),
  constraint profiles_display_name_len check (display_name is null or char_length(display_name) between 1 and 32),
  constraint profiles_bio_len check (char_length(bio) <= 2000),
  constraint profiles_pronouns_len check (char_length(pronouns) <= 40),
  constraint profiles_status_check check (status in ('online','idle','dnd','invisible')),
  constraint profiles_custom_status_len check (custom_status is null or char_length(custom_status) <= 128)
);
create unique index if not exists profiles_username_key on public.profiles (username);

-- Private per-user settings (only the owner can read them).
create table if not exists public.user_settings (
  user_id               uuid primary key references public.profiles(id) on delete cascade,
  allow_dms             text not null default 'everyone' check (allow_dms in ('everyone','friends','servers')),
  friend_requests_from  text not null default 'everyone' check (friend_requests_from in ('everyone','mutual','none')),
  read_receipts         boolean not null default true,
  show_activity         boolean not null default true,
  appearance            jsonb not null default '{}'::jsonb,
  notifications         jsonb not null default '{}'::jsonb,
  voice                 jsonb not null default '{}'::jsonb,
  favorites             jsonb not null default '{}'::jsonb,
  keybinds              jsonb not null default '{}'::jsonb,
  updated_at            timestamptz not null default now()
);

create table if not exists public.friend_requests (
  id          uuid primary key default gen_random_uuid(),
  from_id     uuid not null references public.profiles(id) on delete cascade,
  to_id       uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (from_id, to_id),
  check (from_id <> to_id)
);
create index if not exists friend_requests_to on public.friend_requests (to_id);

create table if not exists public.friends (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  friend_id   uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id)
);

create table if not exists public.blocks (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  blocked_id  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, blocked_id)
);

create table if not exists public.servers (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null check (char_length(name) between 2 and 100),
  icon_url               text,
  banner_url             text,
  description            text not null default '' check (char_length(description) <= 1000),
  owner_id               uuid not null references public.profiles(id) on delete cascade,
  is_public              boolean not null default false,
  category               text not null default 'community',
  tags                   text[] not null default '{}',
  vanity                 text unique check (vanity is null or vanity ~ '^[a-z0-9-]{3,32}$'),
  rules                  text not null default '' check (char_length(rules) <= 4000),
  require_approval       boolean not null default false,
  join_questions         jsonb not null default '[]'::jsonb,
  system_channel_id      uuid,
  welcome_enabled        boolean not null default true,
  welcome_message        text not null default 'Welcome to the server, {user}!',
  levels_enabled         boolean not null default false,
  level_up_messages      boolean not null default true,
  automod_words          text[] not null default '{}',
  automod_block_invites  boolean not null default false,
  theme                  jsonb not null default '{}'::jsonb,
  default_notifications  text not null default 'all' check (default_notifications in ('all','mentions')),
  member_count           integer not null default 0,
  created_at             timestamptz not null default now()
);
create index if not exists servers_public on public.servers (is_public, member_count desc);

create table if not exists public.roles (
  id              uuid primary key default gen_random_uuid(),
  server_id       uuid not null references public.servers(id) on delete cascade,
  name            text not null check (char_length(name) between 1 and 100),
  color           text,
  permissions     bigint not null default 0,
  position        integer not null default 1,
  hoist           boolean not null default false,
  mentionable     boolean not null default false,
  is_default      boolean not null default false,
  managed_by_bot  uuid,
  icon            text,
  created_at      timestamptz not null default now()
);
create unique index if not exists roles_one_default on public.roles (server_id) where is_default;
create index if not exists roles_server on public.roles (server_id);

create table if not exists public.members (
  server_id      uuid not null references public.servers(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  nickname       text check (nickname is null or char_length(nickname) between 1 and 32),
  avatar_url     text,
  joined_at      timestamptz not null default now(),
  timeout_until  timestamptz,
  xp             integer not null default 0,
  level          integer not null default 0,
  last_xp_at     timestamptz,
  primary key (server_id, user_id)
);
create index if not exists members_user on public.members (user_id);

create table if not exists public.member_roles (
  server_id  uuid not null,
  user_id    uuid not null,
  role_id    uuid not null references public.roles(id) on delete cascade,
  primary key (user_id, role_id),
  foreign key (server_id, user_id) references public.members(server_id, user_id) on delete cascade
);
create index if not exists member_roles_member on public.member_roles (server_id, user_id);
create index if not exists member_roles_role on public.member_roles (role_id);

create table if not exists public.channels (
  id                  uuid primary key default gen_random_uuid(),
  server_id           uuid references public.servers(id) on delete cascade,
  parent_id           uuid references public.channels(id) on delete cascade,
  type                text not null check (type in ('text','voice','announcement','forum','media','category','thread','dm','group_dm')),
  name                text check (name is null or char_length(name) between 1 and 100),
  topic               text check (topic is null or char_length(topic) <= 1024),
  position            integer not null default 0,
  synced              boolean not null default true,
  slowmode            integer not null default 0 check (slowmode between 0 and 21600),
  nsfw                boolean not null default false,
  user_limit          integer not null default 0 check (user_limit between 0 and 99),
  video_quality       text not null default 'auto' check (video_quality in ('auto','720p','1080p')),
  temporary           boolean not null default false,
  expires_at          timestamptz,
  owner_id            uuid references public.profiles(id) on delete set null,
  icon_url            text,
  dm_key              text unique,
  starter_message_id  uuid,
  archived            boolean not null default false,
  locked              boolean not null default false,
  forum_tags          jsonb not null default '[]'::jsonb,
  applied_tags        text[] not null default '{}',
  last_message_at     timestamptz,
  message_count       integer not null default 0,
  created_at          timestamptz not null default now(),
  constraint channels_dm_has_no_server check ((type in ('dm','group_dm')) = (server_id is null))
);
create index if not exists channels_server on public.channels (server_id, position);
create index if not exists channels_parent on public.channels (parent_id);

create table if not exists public.channel_overrides (
  channel_id   uuid not null references public.channels(id) on delete cascade,
  server_id    uuid not null references public.servers(id) on delete cascade,
  target_type  text not null check (target_type in ('role','member')),
  target_id    uuid not null,
  allow        bigint not null default 0,
  deny         bigint not null default 0,
  primary key (channel_id, target_id)
);
create index if not exists channel_overrides_target on public.channel_overrides (target_id);

create table if not exists public.channel_recipients (
  channel_id  uuid not null references public.channels(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  accepted    boolean not null default true,
  closed      boolean not null default false,
  joined_at   timestamptz not null default now(),
  primary key (channel_id, user_id)
);
create index if not exists channel_recipients_user on public.channel_recipients (user_id);

create table if not exists public.messages (
  id                uuid primary key default gen_random_uuid(),
  channel_id        uuid not null references public.channels(id) on delete cascade,
  server_id         uuid references public.servers(id) on delete cascade,
  author_id         uuid references public.profiles(id) on delete set null,
  webhook_id        uuid,
  webhook_name      text,
  webhook_avatar    text,
  type              text not null default 'default'
                    check (type in ('default','reply','join','pin','thread','call','level_up','system','forward','command')),
  content           text not null default '',
  reply_to          uuid references public.messages(id) on delete set null,
  attachments       jsonb not null default '[]'::jsonb,
  embeds            jsonb not null default '[]'::jsonb,
  sticker_ids       uuid[] not null default '{}',
  mentions          uuid[] not null default '{}',
  mention_roles     uuid[] not null default '{}',
  mention_everyone  boolean not null default false,
  poll              jsonb,
  forwarded         jsonb,
  interaction       jsonb,
  thread_id         uuid references public.channels(id) on delete set null,
  pinned            boolean not null default false,
  pinned_at         timestamptz,
  flags             integer not null default 0,
  edited_at         timestamptz,
  created_at        timestamptz not null default now(),
  tsv               tsvector generated always as (to_tsvector('simple', coalesce(content, ''))) stored,
  constraint messages_content_len check (char_length(content) <= 4000)
);
create index if not exists messages_channel_created on public.messages (channel_id, created_at desc, id desc);
create index if not exists messages_author_created on public.messages (author_id, created_at desc);
create index if not exists messages_server_created on public.messages (server_id, created_at desc);
create index if not exists messages_tsv on public.messages using gin (tsv);
create index if not exists messages_pinned on public.messages (channel_id) where pinned;

create table if not exists public.message_edits (
  id          bigint generated always as identity primary key,
  message_id  uuid not null references public.messages(id) on delete cascade,
  content     text not null,
  edited_at   timestamptz not null default now()
);
create index if not exists message_edits_message on public.message_edits (message_id);

-- One row per uploaded file, for storage accounting, file search and
-- access checks on the private "attachments" storage bucket.
create table if not exists public.attachments (
  id            uuid primary key default gen_random_uuid(),
  message_id    uuid not null references public.messages(id) on delete cascade,
  channel_id    uuid not null references public.channels(id) on delete cascade,
  uploader_id   uuid references public.profiles(id) on delete set null,
  path          text not null,
  name          text not null,
  size          bigint not null default 0,
  content_type  text,
  created_at    timestamptz not null default now()
);
create index if not exists attachments_path on public.attachments (path);
create index if not exists attachments_uploader on public.attachments (uploader_id);
create index if not exists attachments_channel on public.attachments (channel_id, created_at desc);

create table if not exists public.reactions (
  message_id  uuid not null references public.messages(id) on delete cascade,
  channel_id  uuid not null references public.channels(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  emoji       text not null check (char_length(emoji) between 1 and 64),
  created_at  timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
create index if not exists reactions_message on public.reactions (message_id);

create table if not exists public.poll_votes (
  message_id  uuid not null references public.messages(id) on delete cascade,
  channel_id  uuid not null references public.channels(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  answer_id   integer not null,
  created_at  timestamptz not null default now(),
  primary key (message_id, user_id, answer_id)
);

create table if not exists public.emojis (
  id          uuid primary key default gen_random_uuid(),
  server_id   uuid not null references public.servers(id) on delete cascade,
  name        text not null check (name ~ '^[A-Za-z0-9_]{2,32}$'),
  url         text not null,
  animated    boolean not null default false,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (server_id, name)
);

create table if not exists public.stickers (
  id           uuid primary key default gen_random_uuid(),
  server_id    uuid not null references public.servers(id) on delete cascade,
  name         text not null check (char_length(name) between 2 and 30),
  description  text not null default '' check (char_length(description) <= 100),
  url          text not null,
  format       text not null default 'png',
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

create table if not exists public.sounds (
  id          uuid primary key default gen_random_uuid(),
  server_id   uuid not null references public.servers(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 32),
  emoji       text,
  url         text not null,
  volume      real not null default 1 check (volume between 0 and 1),
  duration    real,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.invites (
  code        text primary key default public.random_code(8),
  server_id   uuid not null references public.servers(id) on delete cascade,
  channel_id  uuid references public.channels(id) on delete set null,
  created_by  uuid references public.profiles(id) on delete set null,
  max_uses    integer not null default 0 check (max_uses >= 0),
  uses        integer not null default 0,
  expires_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists invites_server on public.invites (server_id);

create table if not exists public.bans (
  server_id   uuid not null references public.servers(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  reason      text,
  banned_by   uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (server_id, user_id)
);

create table if not exists public.ban_appeals (
  id           uuid primary key default gen_random_uuid(),
  server_id    uuid not null references public.servers(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  reason       text not null check (char_length(reason) between 1 and 2000),
  status       text not null default 'pending' check (status in ('pending','accepted','denied')),
  reviewed_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

create table if not exists public.join_requests (
  server_id   uuid not null references public.servers(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  answers     jsonb not null default '[]'::jsonb,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at  timestamptz not null default now(),
  primary key (server_id, user_id)
);

create table if not exists public.warnings (
  id            uuid primary key default gen_random_uuid(),
  server_id     uuid not null references public.servers(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  moderator_id  uuid references public.profiles(id) on delete set null,
  reason        text not null check (char_length(reason) between 1 and 1000),
  created_at    timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id           bigint generated always as identity primary key,
  server_id    uuid references public.servers(id) on delete cascade,
  actor_id     uuid references public.profiles(id) on delete set null,
  action       text not null,
  target_type  text,
  target_id    text,
  changes      jsonb not null default '{}'::jsonb,
  reason       text,
  created_at   timestamptz not null default now()
);
create index if not exists audit_logs_server on public.audit_logs (server_id, created_at desc);
create index if not exists audit_logs_actor on public.audit_logs (actor_id, created_at desc);

create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references public.profiles(id) on delete set null,
  server_id    uuid references public.servers(id) on delete cascade,
  target_type  text not null check (target_type in ('message','user','server','attachment')),
  target_id    text not null,
  snapshot     jsonb not null default '{}'::jsonb,
  reason       text not null check (char_length(reason) between 1 and 100),
  details      text not null default '' check (char_length(details) <= 2000),
  status       text not null default 'open' check (status in ('open','resolved','dismissed')),
  resolved_by  uuid references public.profiles(id) on delete set null,
  resolution   text,
  created_at   timestamptz not null default now()
);
create index if not exists reports_server on public.reports (server_id, status);

create table if not exists public.read_states (
  user_id       uuid not null references public.profiles(id) on delete cascade,
  channel_id    uuid not null references public.channels(id) on delete cascade,
  last_read_at  timestamptz not null default now(),
  primary key (user_id, channel_id)
);

create table if not exists public.notification_settings (
  user_id            uuid not null references public.profiles(id) on delete cascade,
  target_id          uuid not null,
  level              text not null default 'default' check (level in ('default','all','mentions','none')),
  muted_until        timestamptz,
  suppress_everyone  boolean not null default false,
  primary key (user_id, target_id)
);

create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        text not null,
  actor_id    uuid references public.profiles(id) on delete cascade,
  server_id   uuid references public.servers(id) on delete cascade,
  channel_id  uuid references public.channels(id) on delete cascade,
  message_id  uuid references public.messages(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create unique index if not exists notifications_dedupe on public.notifications (user_id, type, message_id) where message_id is not null;
create index if not exists notifications_user on public.notifications (user_id, created_at desc);
create index if not exists notifications_channel on public.notifications (user_id, channel_id) where not read;

create table if not exists public.events (
  id           uuid primary key default gen_random_uuid(),
  server_id    uuid not null references public.servers(id) on delete cascade,
  channel_id   uuid references public.channels(id) on delete set null,
  location     text check (location is null or char_length(location) <= 200),
  name         text not null check (char_length(name) between 1 and 100),
  description  text not null default '' check (char_length(description) <= 1000),
  image_url    text,
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  status       text not null default 'scheduled' check (status in ('scheduled','active','completed','canceled')),
  created_by   uuid references public.profiles(id) on delete set null,
  reminded     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists events_server on public.events (server_id, starts_at);

create table if not exists public.event_rsvps (
  event_id    uuid not null references public.events(id) on delete cascade,
  server_id   uuid not null references public.servers(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  status      text not null default 'going' check (status in ('going','interested')),
  created_at  timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table if not exists public.bot_apps (
  id           uuid primary key references public.profiles(id) on delete cascade,
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  name         text not null check (char_length(name) between 2 and 32),
  description  text not null default '' check (char_length(description) <= 400),
  is_public    boolean not null default false,
  permissions  bigint not null default 0,
  token_hash   text not null,
  token_hint   text not null default '',
  created_at   timestamptz not null default now()
);

create table if not exists public.bot_commands (
  id           uuid primary key default gen_random_uuid(),
  bot_id       uuid not null references public.bot_apps(id) on delete cascade,
  name         text not null check (name ~ '^[a-z0-9_-]{1,32}$'),
  description  text not null default '' check (char_length(description) <= 100),
  options      jsonb not null default '[]'::jsonb,
  unique (bot_id, name)
);

create table if not exists public.interactions (
  id                   uuid primary key default gen_random_uuid(),
  bot_id               uuid not null references public.bot_apps(id) on delete cascade,
  user_id              uuid not null references public.profiles(id) on delete cascade,
  channel_id           uuid not null references public.channels(id) on delete cascade,
  server_id            uuid references public.servers(id) on delete cascade,
  command              text not null,
  options              jsonb not null default '{}'::jsonb,
  status               text not null default 'pending' check (status in ('pending','delivered','done','expired')),
  response_message_id  uuid,
  created_at           timestamptz not null default now()
);
create index if not exists interactions_bot on public.interactions (bot_id, status, created_at);

create table if not exists public.webhooks (
  id          uuid primary key default gen_random_uuid(),
  server_id   uuid not null references public.servers(id) on delete cascade,
  channel_id  uuid not null references public.channels(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80),
  avatar_url  text,
  token_hash  text not null,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- Counters for abuse protection on expensive or spammable actions.
create table if not exists public.rate_limits (
  user_id       uuid not null,
  bucket        text not null,
  window_start  timestamptz not null default now(),
  count         integer not null default 0,
  primary key (user_id, bucket)
);

-- ---- 20_permissions.sql ----
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

-- ---- 30_triggers.sql ----
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

-- ---- 40_rpc_social.sql ----
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

-- ---- 41_rpc_servers.sql ----
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

-- ---- 42_rpc_messages.sql ----
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

-- ---- 43_rpc_bots.sql ----
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

-- ---- 44_rpc_account.sql ----
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

-- ---- 50_policies.sql ----
-- =====================================================================
--  Row level security
--  Every table is locked down; these policies open exactly what each
--  person is allowed to see or change. Anything more involved goes
--  through the functions above.
-- =====================================================================

do $$
declare
  r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
  end loop;
end $$;

-- Profiles & settings
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy settings_own on public.user_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Friends & blocks
create policy friend_requests_read on public.friend_requests for select to authenticated
  using (from_id = auth.uid() or to_id = auth.uid());
create policy friends_read on public.friends for select to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());
create policy blocks_read on public.blocks for select to authenticated
  using (user_id = auth.uid());

-- Servers
create policy servers_read on public.servers for select to authenticated
  using (public.is_member(id));
create policy servers_update on public.servers for update to authenticated
  using (public.has_server_perm(id, 'MANAGE_SERVER')) with check (public.has_server_perm(id, 'MANAGE_SERVER'));
create policy servers_delete on public.servers for delete to authenticated
  using (owner_id = auth.uid());

create policy roles_read on public.roles for select to authenticated
  using (public.is_member(server_id));
create policy roles_insert on public.roles for insert to authenticated
  with check (not is_default and public.can_edit_role(server_id, position, permissions));
create policy roles_update on public.roles for update to authenticated
  using (public.can_edit_role(server_id, position, null))
  with check (public.can_edit_role(server_id, position, permissions));
create policy roles_delete on public.roles for delete to authenticated
  using (not is_default and managed_by_bot is null and public.can_edit_role(server_id, position, null));

create policy members_read on public.members for select to authenticated
  using (public.is_member(server_id));
create policy members_update on public.members for update to authenticated
  using (public.can_edit_member(server_id, user_id) or user_id = auth.uid())
  with check (public.can_edit_member(server_id, user_id) or user_id = auth.uid());

create policy member_roles_read on public.member_roles for select to authenticated
  using (public.is_member(server_id));
create policy member_roles_insert on public.member_roles for insert to authenticated
  with check (public.can_assign_role(server_id, user_id, role_id));
create policy member_roles_delete on public.member_roles for delete to authenticated
  using (public.can_assign_role(server_id, user_id, role_id));

-- Channels
create policy channels_read on public.channels for select to authenticated
  using (public.can_view_channel(id));
create policy channels_update on public.channels for update to authenticated
  using (
    (server_id is not null and public.has_channel_perm(id, 'MANAGE_CHANNELS'))
    or (type = 'thread' and owner_id = auth.uid())
    or (type = 'group_dm' and public.is_recipient(id)))
  with check (
    (server_id is not null and public.has_channel_perm(id, 'MANAGE_CHANNELS'))
    or (type = 'thread' and owner_id = auth.uid())
    or (type = 'group_dm' and public.is_recipient(id)));
create policy channels_delete on public.channels for delete to authenticated
  using (server_id is not null and (public.has_channel_perm(id, 'MANAGE_CHANNELS')
                                    or (temporary and owner_id = auth.uid())));

create policy overrides_read on public.channel_overrides for select to authenticated
  using (public.is_member(server_id));
create policy overrides_insert on public.channel_overrides for insert to authenticated
  with check (public.has_server_perm(server_id, 'MANAGE_ROLES') or public.has_channel_perm(channel_id, 'MANAGE_ROLES'));
create policy overrides_update on public.channel_overrides for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_ROLES') or public.has_channel_perm(channel_id, 'MANAGE_ROLES'))
  with check (public.has_server_perm(server_id, 'MANAGE_ROLES') or public.has_channel_perm(channel_id, 'MANAGE_ROLES'));
create policy overrides_delete on public.channel_overrides for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_ROLES') or public.has_channel_perm(channel_id, 'MANAGE_ROLES'));

create policy recipients_read on public.channel_recipients for select to authenticated
  using (user_id = auth.uid() or public.is_recipient(channel_id));
create policy recipients_update_own on public.channel_recipients for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Messages
create policy messages_read on public.messages for select to authenticated
  using (public.can_read_channel(channel_id));
create policy messages_insert on public.messages for insert to authenticated
  with check (author_id = auth.uid() and webhook_id is null and type in ('default', 'reply')
              and public.has_channel_perm(channel_id, 'SEND_MESSAGES'));
create policy messages_update_own on public.messages for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy messages_delete on public.messages for delete to authenticated
  using (author_id = auth.uid() or public.has_channel_perm(channel_id, 'MANAGE_MESSAGES'));

create policy message_edits_read on public.message_edits for select to authenticated
  using (exists (select 1 from public.messages m where m.id = message_id
                 and (m.author_id = auth.uid() or public.has_channel_perm(m.channel_id, 'MANAGE_MESSAGES'))));

create policy attachments_read on public.attachments for select to authenticated
  using (public.can_read_channel(channel_id));

create policy reactions_read on public.reactions for select to authenticated
  using (public.can_read_channel(channel_id));
create policy reactions_insert on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and public.has_channel_perm(channel_id, 'ADD_REACTIONS'));
create policy reactions_delete on public.reactions for delete to authenticated
  using (user_id = auth.uid() or public.has_channel_perm(channel_id, 'MANAGE_MESSAGES'));

create policy poll_votes_read on public.poll_votes for select to authenticated
  using (public.can_read_channel(channel_id));
create policy poll_votes_insert on public.poll_votes for insert to authenticated
  with check (user_id = auth.uid() and public.can_read_channel(channel_id));
create policy poll_votes_delete on public.poll_votes for delete to authenticated
  using (user_id = auth.uid());

-- Expressions: usable everywhere (no paywall), managed per server
create policy emojis_read on public.emojis for select to authenticated using (true);
create policy emojis_write on public.emojis for insert to authenticated
  with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy emojis_update on public.emojis for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS')) with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy emojis_delete on public.emojis for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));

create policy stickers_read on public.stickers for select to authenticated using (true);
create policy stickers_write on public.stickers for insert to authenticated
  with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy stickers_update on public.stickers for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS')) with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy stickers_delete on public.stickers for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));

create policy sounds_read on public.sounds for select to authenticated using (true);
create policy sounds_write on public.sounds for insert to authenticated
  with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy sounds_update on public.sounds for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS')) with check (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));
create policy sounds_delete on public.sounds for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EXPRESSIONS'));

-- Invites & moderation records
create policy invites_read on public.invites for select to authenticated
  using (created_by = auth.uid() or public.has_server_perm(server_id, 'MANAGE_SERVER'));
create policy invites_insert on public.invites for insert to authenticated
  with check (created_by = auth.uid() and public.has_server_perm(server_id, 'CREATE_INVITE'));
create policy invites_delete on public.invites for delete to authenticated
  using (created_by = auth.uid() or public.has_server_perm(server_id, 'MANAGE_SERVER'));

create policy bans_read on public.bans for select to authenticated
  using (public.has_server_perm(server_id, 'BAN_MEMBERS'));
create policy appeals_read on public.ban_appeals for select to authenticated
  using (user_id = auth.uid() or public.has_server_perm(server_id, 'BAN_MEMBERS'));
create policy join_requests_read on public.join_requests for select to authenticated
  using (user_id = auth.uid() or public.has_server_perm(server_id, 'KICK_MEMBERS'));
create policy warnings_read on public.warnings for select to authenticated
  using (user_id = auth.uid() or public.has_server_perm(server_id, 'MODERATE_MEMBERS'));
create policy audit_read on public.audit_logs for select to authenticated
  using ((server_id is not null and public.has_server_perm(server_id, 'VIEW_AUDIT_LOG'))
         or (server_id is null and actor_id = auth.uid()));

create policy reports_insert on public.reports for insert to authenticated
  with check (reporter_id = auth.uid());
create policy reports_read on public.reports for select to authenticated
  using (reporter_id = auth.uid()
         or (server_id is not null and public.has_server_perm(server_id, 'MANAGE_MESSAGES'))
         or public.is_platform_admin());

-- Personal state
create policy read_states_own on public.read_states for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notification_settings_own on public.notification_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_read on public.notifications for select to authenticated
  using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = auth.uid());

-- Events
create policy events_read on public.events for select to authenticated
  using (public.is_member(server_id));
create policy events_insert on public.events for insert to authenticated
  with check (created_by = auth.uid() and public.has_server_perm(server_id, 'MANAGE_EVENTS'));
create policy events_update on public.events for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EVENTS') or created_by = auth.uid())
  with check (public.has_server_perm(server_id, 'MANAGE_EVENTS') or created_by = auth.uid());
create policy events_delete on public.events for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_EVENTS') or created_by = auth.uid());

create policy rsvps_read on public.event_rsvps for select to authenticated
  using (public.is_member(server_id));
create policy rsvps_insert on public.event_rsvps for insert to authenticated
  with check (user_id = auth.uid() and public.is_member(server_id)
              and server_id = (select e.server_id from public.events e where e.id = event_id));
create policy rsvps_update on public.event_rsvps for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy rsvps_delete on public.event_rsvps for delete to authenticated
  using (user_id = auth.uid());

-- Developer platform
create policy bots_read on public.bot_apps for select to authenticated
  using (owner_id = auth.uid() or is_public
         or id in (select m.user_id from public.members m where public.is_member(m.server_id)));
create policy bot_commands_read on public.bot_commands for select to authenticated using (true);
create policy bot_commands_insert on public.bot_commands for insert to authenticated
  with check (exists (select 1 from public.bot_apps b where b.id = bot_id and b.owner_id = auth.uid()));
create policy bot_commands_update on public.bot_commands for update to authenticated
  using (exists (select 1 from public.bot_apps b where b.id = bot_id and b.owner_id = auth.uid()))
  with check (exists (select 1 from public.bot_apps b where b.id = bot_id and b.owner_id = auth.uid()));
create policy bot_commands_delete on public.bot_commands for delete to authenticated
  using (exists (select 1 from public.bot_apps b where b.id = bot_id and b.owner_id = auth.uid()));
create policy interactions_read on public.interactions for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.bot_apps b where b.id = bot_id and b.owner_id = auth.uid()));
create policy webhooks_read on public.webhooks for select to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_WEBHOOKS'));
create policy webhooks_update on public.webhooks for update to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_WEBHOOKS')) with check (public.has_server_perm(server_id, 'MANAGE_WEBHOOKS'));
create policy webhooks_delete on public.webhooks for delete to authenticated
  using (public.has_server_perm(server_id, 'MANAGE_WEBHOOKS'));

create policy app_config_read on public.app_config for select to anon, authenticated using (true);
-- rate_limits: no policies — only reachable through functions

-- ---- 60_storage_realtime.sql ----
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

-- ---- 70_grants.sql ----
-- =====================================================================
--  Privileges
--  Row level security decides WHICH rows; these grants decide WHICH
--  columns people may write. Counters, ownership, moderation fields and
--  secrets can only change through the functions above.
-- =====================================================================

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant usage on schema public to anon, authenticated;

grant select on all tables in schema public to authenticated;
revoke select on public.rate_limits from authenticated;
revoke select on public.bot_apps, public.webhooks from authenticated;
grant select (id, owner_id, name, description, is_public, permissions, token_hint, created_at) on public.bot_apps to authenticated;
grant select (id, server_id, channel_id, name, avatar_url, created_by, created_at) on public.webhooks to authenticated;
grant select on public.app_config to anon;

grant update (username, display_name, avatar_url, banner_url, banner_color, accent_color, theme_colors, bio, pronouns,
              status, custom_status, custom_status_emoji, custom_status_expires_at, avatar_decoration, profile_effect,
              nameplate, name_style, widgets)
  on public.profiles to authenticated;

grant insert, update, delete on public.user_settings to authenticated;

grant update (name, icon_url, banner_url, description, is_public, category, tags, vanity, rules, require_approval,
              join_questions, system_channel_id, welcome_enabled, welcome_message, levels_enabled, level_up_messages,
              automod_words, automod_block_invites, theme, default_notifications)
  on public.servers to authenticated;
grant delete on public.servers to authenticated;

grant insert (server_id, name, color, permissions, position, hoist, mentionable, icon) on public.roles to authenticated;
grant update (name, color, permissions, hoist, mentionable, icon) on public.roles to authenticated;
grant delete on public.roles to authenticated;

grant update (nickname, avatar_url) on public.members to authenticated;
grant insert (server_id, user_id, role_id), delete on public.member_roles to authenticated;

grant update (name, topic, position, parent_id, synced, slowmode, nsfw, user_limit, video_quality, icon_url,
              archived, locked, forum_tags, applied_tags)
  on public.channels to authenticated;
grant delete on public.channels to authenticated;

grant insert (channel_id, server_id, target_type, target_id, allow, deny) on public.channel_overrides to authenticated;
grant update (allow, deny) on public.channel_overrides to authenticated;
grant delete on public.channel_overrides to authenticated;

grant update (accepted, closed) on public.channel_recipients to authenticated;

grant insert (id, channel_id, author_id, type, content, reply_to, attachments, sticker_ids, poll, flags)
  on public.messages to authenticated;
grant update (content, attachments, flags) on public.messages to authenticated;
grant delete on public.messages to authenticated;

grant insert (message_id, channel_id, user_id, emoji), delete on public.reactions to authenticated;
grant insert (message_id, channel_id, user_id, answer_id), delete on public.poll_votes to authenticated;

grant insert (server_id, name, url, animated) on public.emojis to authenticated;
grant update (name) on public.emojis to authenticated;
grant delete on public.emojis to authenticated;
grant insert (server_id, name, description, url, format) on public.stickers to authenticated;
grant update (name, description) on public.stickers to authenticated;
grant delete on public.stickers to authenticated;
grant insert (server_id, name, emoji, url, volume, duration) on public.sounds to authenticated;
grant update (name, emoji, volume) on public.sounds to authenticated;
grant delete on public.sounds to authenticated;

grant insert (server_id, channel_id, created_by, max_uses, expires_at), delete on public.invites to authenticated;

grant insert (reporter_id, server_id, target_type, target_id, reason, details) on public.reports to authenticated;

grant insert, update, delete on public.read_states to authenticated;
grant insert, update, delete on public.notification_settings to authenticated;
grant update (read), delete on public.notifications to authenticated;

grant insert (server_id, channel_id, location, name, description, image_url, starts_at, ends_at, status, created_by)
  on public.events to authenticated;
grant update (channel_id, location, name, description, image_url, starts_at, ends_at, status) on public.events to authenticated;
grant delete on public.events to authenticated;
grant insert (event_id, server_id, user_id, status), update (status), delete on public.event_rsvps to authenticated;

grant insert (bot_id, name, description, options), update (name, description, options), delete
  on public.bot_commands to authenticated;
grant update (name, avatar_url), delete on public.webhooks to authenticated;

-- Functions: signed-in users only, except the bot/webhook API and invite previews
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.bot_me(text), public.bot_channels(text, uuid),
  public.bot_send_message(text, uuid, text, jsonb, uuid), public.bot_read_messages(text, uuid, timestamptz, integer),
  public.bot_set_commands(text, jsonb), public.bot_poll_interactions(text), public.bot_respond(text, uuid, text, jsonb),
  public.execute_webhook(uuid, text, text, text, text, jsonb), public.invite_info(text)
  to anon;
-- Internal helpers that should never be called directly
revoke execute on function public.make_friends(uuid, uuid), public.add_member(uuid, uuid),
  public.notify_moderation(uuid, uuid, text, text, jsonb), public.log_action(uuid, text, text, text, text, jsonb),
  public.unique_username(text), public.check_rate_limit(text, integer, integer)
  from authenticated;

-- ---- 80_maintenance.sql ----
-- =====================================================================
--  Housekeeping (runs every 5 minutes with pg_cron when available)
-- =====================================================================

create or replace function public.galaxy_maintenance()
returns void language plpgsql security definer set search_path = public as $$
begin
  -- Event reminders 15 minutes before start
  insert into notifications (user_id, type, server_id, channel_id, data)
  select r.user_id, 'event', e.server_id, e.channel_id,
         jsonb_build_object('event_id', e.id, 'name', e.name, 'starts_at', e.starts_at)
  from events e join event_rsvps r on r.event_id = e.id
  where e.status = 'scheduled' and not e.reminded
    and e.starts_at between now() and now() + interval '15 minutes';
  update events set reminded = true
   where status = 'scheduled' and not reminded and starts_at <= now() + interval '15 minutes';
  update events set status = 'active' where status = 'scheduled' and starts_at <= now();
  update events set status = 'completed'
   where status = 'active' and coalesce(ends_at, starts_at + interval '3 hours') < now();

  delete from invites where expires_at is not null and expires_at < now() - interval '1 day';
  delete from channels where temporary and expires_at is not null and expires_at < now();
  update channels set archived = true
   where type = 'thread' and not archived and coalesce(last_message_at, created_at) < now() - interval '7 days';
  update profiles set custom_status = null, custom_status_emoji = null, custom_status_expires_at = null
   where custom_status_expires_at is not null and custom_status_expires_at < now();
  update interactions set status = 'expired'
   where status in ('pending', 'delivered') and created_at < now() - interval '15 minutes';
  delete from rate_limits where window_start < now() - interval '2 days';
  delete from notifications where read and created_at < now() - interval '60 days';
end $$;

revoke execute on function public.galaxy_maintenance() from public, anon, authenticated;

do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.unschedule(jobid) from cron.job where jobname = 'galaxy-maintenance';
  perform cron.schedule('galaxy-maintenance', '*/5 * * * *', 'select public.galaxy_maintenance()');
exception when others then
  raise notice 'pg_cron is not available (%). Event reminders and cleanup will not run automatically.', sqlerrm;
end $$;
