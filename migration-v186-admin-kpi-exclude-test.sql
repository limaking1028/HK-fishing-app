-- v186：後台 KPI 排除測試／審核帳戶（public.founders_excluded）
-- 以 prod 2026-11-01 嘅 pg_get_functiondef 為底，只加 founders_excluded 條件；簽名、SECURITY DEFINER、search_path、is_admin 檢查不變。
-- admin_daily_counts：app_daily_counts（share_open／share_entry／new_visitor）係匿名每日總數，冇 user_id，無法排除；只排除 signups 同 first_catches。
-- admin_user_stats：單一用戶詳情，數字照舊（排除咗會變 0 誤導），只加 founders_excluded 旗。
-- 唔改創始釣友邏輯、排行榜、founders。可以重複執行（CREATE OR REPLACE）。

CREATE OR REPLACE FUNCTION public.admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb; today date := (now() at time zone 'Asia/Hong_Kong')::date;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'users_total',   (select count(*) from auth.users where not exists (select 1 from public.founders_excluded fx where fx.user_id = id)),
    'users_7d',      (select count(*) from auth.users where not exists (select 1 from public.founders_excluded fx where fx.user_id = id) and created_at > now() - interval '7 days'),
    'users_active_7d', (select count(*) from auth.users where not exists (select 1 from public.founders_excluded fx where fx.user_id = id) and last_sign_in_at > now() - interval '7 days'),
    'catches_total', (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id)),
    'catches_today', (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and (created_at at time zone 'Asia/Hong_Kong')::date = today),
    'catches_7d',    (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at > now() - interval '7 days'),
    'with_photo',    (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and photo_url is not null and photo_url <> ''),
    'eligible_total',(select count(*) from public.catches where leaderboard_eligible and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id)),
    'trips_total',   (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id)),
    'pending_reviews',((select count(*) from public.lb_review_queue) + (select count(*) from public.lb_pending_ids())),
    'excluded_total',(select count(*) from public.catches where admin_excluded and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id)),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'n', n) order by n desc)
                from (select ineligible_reason as reason, count(*) n from public.catches
                       where not leaderboard_eligible and user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and ineligible_reason is not null
                         and created_at > now() - interval '30 days' group by 1) q), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'n', n, 'u', u) order by d)
                from (select (created_at at time zone 'Asia/Hong_Kong')::date d, count(*) n, count(distinct user_id) u
                        from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at > now() - interval '14 days' group by 1) q), '[]'::jsonb)
  ) into r;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_daily_counts(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  v_n int := greatest(1, least(coalesce(p_days, 30), 90));
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    with d as (select generate_series(v_today - (v_n - 1), v_today, interval '1 day')::date as day),
    c as (select day, event, src, n from public.app_daily_counts where day >= v_today - (v_n - 1)),
    su as (select (u.created_at at time zone 'Asia/Hong_Kong')::date as day, count(*)::int as n
             from public.users u where not exists (select 1 from public.founders_excluded fx where fx.user_id = u.id) group by 1),
    fc as (select (x.f at time zone 'Asia/Hong_Kong')::date as day, count(*)::int as n
             from (select c2.user_id, min(c2.created_at) as f from public.catches c2
                    join public.users u on u.id = c2.user_id
                   where not c2.is_test and not exists (select 1 from public.founders_excluded fx where fx.user_id = c2.user_id) group by c2.user_id) x group by 1)
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', d.day,
             'share_open', coalesce((select sum(n) from c where c.day = d.day and c.event = 'share_open'), 0),
             'share_entry', coalesce((select sum(n) from c where c.day = d.day and c.event = 'share_entry'), 0),
             'new_visitor', coalesce((select sum(n) from c where c.day = d.day and c.event = 'new_visitor'), 0),
             'signups', coalesce((select n from su where su.day = d.day), 0),
             'first_catches', coalesce((select n from fc where fc.day = d.day), 0),
             'by_src', coalesce((select jsonb_object_agg(c.event || ':' || c.src, c.n) from c where c.day = d.day), '{}'::jsonb))
           order by d.day desc), '[]'::jsonb)
      from d);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_insights()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  since timestamptz := now() - interval '30 days';
  since_d date := (now() at time zone 'Asia/Hong_Kong')::date - 29;
  r jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;

  with reg as (   -- 每位用戶最新一次興趣登記
    select distinct on (f.user_id) f.user_id, f.message, f.created_at
      from public.feedback f
     where not exists (select 1 from public.founders_excluded fx where fx.user_id = f.user_id) and f.message like '【進階分析興趣登記】%'
     order by f.user_id, f.created_at desc
  ), parsed as (
    select user_id, created_at, message,
           nullif(btrim(substring(message from '想要：([^\n]*)')), '') as feats,
           nullif(btrim(substring(message from '收費：([^\n]*)')), '') as price
      from reg
  ), feat as (
    select btrim(x) as name, count(*) as n
      from parsed, unnest(string_to_array(coalesce(feats, ''), '、')) as x
     where btrim(x) <> '' and btrim(x) <> '未揀'
     group by 1
  ), price as (
    select price as name, count(*) as n from parsed where price is not null and price <> '未揀' group by 1
  ),
  rec as (   -- 近 30 日有記錄（魚獲或行程）嘅用戶
    select user_id from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at >= since
    union
    select user_id from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since
  ), consent as (
    select user_id from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at >= since and opted_in_analytics
    union
    select user_id from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since and start_conditions is not null
  )
  select jsonb_build_object(
    'interest', jsonb_build_object(
      'users', (select count(*) from parsed),
      'features', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc, name) from feat), '[]'::jsonb),
      'prices', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc, name) from price), '[]'::jsonb),
      'recent', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
          select jsonb_build_object('user_id', p.user_id, 'display_name', u.display_name, 'email', a.email,
                   'feats', p.feats, 'price', p.price,
                   'note', nullif(btrim(substring(p.message from '其他：(.*)$')), ''),
                   'created_at', p.created_at) x
            from parsed p
            left join public.users u on u.id = p.user_id
            left join auth.users a on a.id = p.user_id
           order by p.created_at desc limit 20) z), '[]'::jsonb)),
    'data', jsonb_build_object(
      'since', since_d,
      'recording_users', (select count(*) from rec),
      'consent_users',   (select count(*) from consent where user_id in (select user_id from rec)),
      'catches',         (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at >= since),
      'catches_stats',   (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at >= since and stats is not null),
      'catches_weather', (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and created_at >= since
                            and stats->'weather'->>'source' = 'open-meteo'),
      'trips',           (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since),
      'trips_ended',     (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since and ended_at is not null),
      'trips_start',     (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since and start_conditions is not null),
      'trips_end',       (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since and end_conditions is not null),
      'trips_empty',     (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and started_at >= since and ended_at is not null
                            and coalesce(catch_count, 0) = 0),
      'trips_stale',     (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and ended_at is null
                            and started_at < now() - interval '24 hours'),
      'all_catches_stats', (select count(*) from public.catches where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = catches.user_id) and stats is not null),
      'all_trips_snap',    (select count(*) from public.fishing_trips where user_id is not null and not exists (select 1 from public.founders_excluded fx where fx.user_id = fishing_trips.user_id) and start_conditions is not null))
  ) into r;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_tester_progress(p_start date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  hk_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  s date := coalesce(p_start, (now() at time zone 'Asia/Hong_Kong')::date - 13);
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    with days as (
      select distinct user_id, day from public.app_usage
       where day >= s and day <= hk_today and seconds > 0 and not exists (select 1 from public.founders_excluded fx where fx.user_id = app_usage.user_id)
    ),
    grp as (
      -- 連續日數：日期減去行號，同一組即係連續
      select user_id, day, day - (row_number() over (partition by user_id order by day))::int as g from days
    ),
    streaks as (
      select user_id, count(*) as streak, max(day) as streak_end from grp group by user_id, g
    ),
    best as (
      select user_id, max(streak) as best_streak, max(streak_end) as last_day from streaks group by user_id
    ),
    totals as (
      select user_id, count(*) as active_days from days group by user_id
    )
    select jsonb_build_object(
      'start',        s,
      'today',        hk_today,
      'days_elapsed', hk_today - s + 1,
      'qualified',    (select count(*) from best where best_streak >= 14),
      'users', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', b.user_id,
                 'display_name', coalesce(p.display_name, split_part(a.email, '@', 1)),
                 'email', a.email,
                 'best_streak', b.best_streak,
                 'active_days', t.active_days,
                 'last_day', b.last_day)
               order by b.best_streak desc, t.active_days desc)
          from best b
          join totals t using (user_id)
          left join public.users p on p.id = b.user_id
          left join auth.users a on a.id = b.user_id
      ), '[]'::jsonb)
    )
  );
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_user_stats(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'user_id',        p_user,
    'display_name',   (select display_name from public.users where id = p_user),
    'is_admin',       exists (select 1 from public.admins where user_id = p_user),
    'founders_excluded', exists (select 1 from public.founders_excluded where user_id = p_user),   -- v186：測試／審核帳戶（後台 KPI 唔計）
    'catch_count',    (select count(*) from public.catches where user_id = p_user),
    'excluded_count', (select count(*) from public.catches where user_id = p_user and admin_excluded),
    'trip_count',     (select count(*) from public.fishing_trips where user_id = p_user),
    'open_trip_count',(select count(*) from public.fishing_trips where user_id = p_user and ended_at is null),
    'first_catch_at', (select min(created_at) from public.catches where user_id = p_user),
    'last_catch_at',  (select max(created_at) from public.catches where user_id = p_user)
  );
end $function$
;

revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated, service_role;
revoke all on function public.admin_insights() from public, anon;
grant execute on function public.admin_insights() to authenticated, service_role;
revoke all on function public.admin_tester_progress(date) from public, anon;
grant execute on function public.admin_tester_progress(date) to authenticated, service_role;
revoke all on function public.admin_daily_counts(integer) from public, anon;
grant execute on function public.admin_daily_counts(integer) to authenticated, service_role;
revoke all on function public.admin_user_stats(uuid) from public, anon;
grant execute on function public.admin_user_stats(uuid) to authenticated, service_role;
