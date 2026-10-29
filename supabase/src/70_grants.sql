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
