-- EXAMPLE ONLY: do not execute automatically. Owner must approve extensions/Vault/cron first.
-- Vault placeholder names (no URLs or credential values):
-- PUSH_EDGE_BASE_URL_PLACEHOLDER: functions/v1 base URL; PUSH_SECRET_PLACEHOLDER: x-push-secret.
-- pg_cron schedules are UTC. No secret is embedded in the job command or headers.
select cron.schedule('push-trip-open-v205','*/15 * * * *',$$select public.push_schedule_trip_open();$$); -- HK every 15 min
select cron.schedule('push-lb-chance-v205','0 11 * * 3',$$select public.push_schedule_lb_chance();$$); -- HK Wed 19:00
select cron.schedule('push-weekly-v205','0 10 * * 0',$$select public.push_schedule_weekly();$$); -- HK Sun 18:00
select cron.schedule('push-tide-v205','50 11 * * *',$job$
 select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name='PUSH_EDGE_BASE_URL_PLACEHOLDER')||'/push-schedule?job=tide',
  headers := jsonb_build_object('Content-Type','application/json','x-push-secret',(select decrypted_secret from vault.decrypted_secrets where name='PUSH_SECRET_PLACEHOLDER')),
  body := '{}'::jsonb);
$job$); -- HK daily 19:50; enqueue for 20:00, expire at 23:00
select cron.schedule('push-inactive-v205','20 11 * * 5',$job$
 select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name='PUSH_EDGE_BASE_URL_PLACEHOLDER')||'/push-schedule?job=inactive',
  headers := jsonb_build_object('Content-Type','application/json','x-push-secret',(select decrypted_secret from vault.decrypted_secrets where name='PUSH_SECRET_PLACEHOLDER')),
  body := '{}'::jsonb);
$job$); -- HK Fri 19:20; enqueue for 19:30
select cron.schedule('push-send-v205','*/5 * * * *',$job$
 select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name='PUSH_EDGE_BASE_URL_PLACEHOLDER')||'/send-push',
  headers := jsonb_build_object('Content-Type','application/json','x-push-secret',(select decrypted_secret from vault.decrypted_secrets where name='PUSH_SECRET_PLACEHOLDER')),
  body := '{}'::jsonb);
$job$); -- HK every 5 min, including cleanup during quiet hours
