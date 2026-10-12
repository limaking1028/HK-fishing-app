-- ============================================================
-- v143：後台「付費準備」
--   admin_insights()：
--     1. 進階分析興趣登記（App v142「我有興趣」送去意見箱嗰啲）
--        - 登記人數、每項功能幾多人想要、可接受價錢分佈、最近登記
--        - 同一個用戶登記多次只計最新一次
--     2. 分析數據儲備（近 30 日）
--        - 有記錄嘅用戶之中，幾多個開咗匿名統計
--        - 魚獲有環境數據／天氣嘅比例；行程有開始／結束快照嘅比例
--        - 空軍率（已結束但冇魚嘅行程）、忘記結束嘅行程（開咗超過 24 小時）
--   只有管理員可用（SECURITY DEFINER + is_admin()）。只回傳統計數字同登記內容，唔回傳座標。
-- 可重複執行。需要先執行 v112、v139、v141。
-- ============================================================
create or replace function public.admin_insights()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare
  since timestamptz := now() - interval '30 days';
  since_d date := (now() at time zone 'Asia/Hong_Kong')::date - 29;
  r jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;

  with reg as (   -- 每位用戶最新一次興趣登記
    select distinct on (f.user_id) f.user_id, f.message, f.created_at
      from public.feedback f
     where f.message like '【進階分析興趣登記】%'
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
    select user_id from public.catches where user_id is not null and created_at >= since
    union
    select user_id from public.fishing_trips where user_id is not null and started_at >= since
  ), consent as (
    select user_id from public.catches where user_id is not null and created_at >= since and opted_in_analytics
    union
    select user_id from public.fishing_trips where user_id is not null and started_at >= since and start_conditions is not null
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
      'catches',         (select count(*) from public.catches where user_id is not null and created_at >= since),
      'catches_stats',   (select count(*) from public.catches where user_id is not null and created_at >= since and stats is not null),
      'catches_weather', (select count(*) from public.catches where user_id is not null and created_at >= since
                            and stats->'weather'->>'source' = 'open-meteo'),
      'trips',           (select count(*) from public.fishing_trips where user_id is not null and started_at >= since),
      'trips_ended',     (select count(*) from public.fishing_trips where user_id is not null and started_at >= since and ended_at is not null),
      'trips_start',     (select count(*) from public.fishing_trips where user_id is not null and started_at >= since and start_conditions is not null),
      'trips_end',       (select count(*) from public.fishing_trips where user_id is not null and started_at >= since and end_conditions is not null),
      'trips_empty',     (select count(*) from public.fishing_trips where user_id is not null and started_at >= since and ended_at is not null
                            and coalesce(catch_count, 0) = 0),
      'trips_stale',     (select count(*) from public.fishing_trips where user_id is not null and ended_at is null
                            and started_at < now() - interval '24 hours'),
      'all_catches_stats', (select count(*) from public.catches where user_id is not null and stats is not null),
      'all_trips_snap',    (select count(*) from public.fishing_trips where user_id is not null and start_conditions is not null))
  ) into r;
  return r;
end $$;
revoke all on function public.admin_insights() from public, anon;
grant execute on function public.admin_insights() to authenticated;

-- ---------- 驗證（用管理員帳戶喺 App 後台睇，SQL Editor 冇登入身份會顯示 forbidden）----------
-- select proname from pg_proc where proname = 'admin_insights';
