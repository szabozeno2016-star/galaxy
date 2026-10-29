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
