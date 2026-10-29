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
