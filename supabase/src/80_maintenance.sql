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
