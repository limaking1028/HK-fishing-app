-- ============================================================
-- catches 表加 stats JSONB 欄位 — Route L+ 統計維度
--
-- 每筆魚獲的隱性數據（用戶不需手動輸入）：
--   temporal.hour/weekday/month/season
--   moon.phaseName/illuminationPct
--   sun.phaseOfDay/isGoldenHour
--   tide.station/heightM/trend/tideType (spring/medium/neap)
--   geo.area/nearestTideStation/distanceToStationKm
--   weather (僅當日魚獲)
--
-- 設 nullable，向後相容所有現有魚獲（舊 catch.stats = null）
-- ============================================================

alter table catches
  add column if not exists stats jsonb;

create index if not exists catches_stats_hour_idx
  on catches ((stats->'temporal'->>'hour'))
  where stats is not null;

create index if not exists catches_stats_tide_type_idx
  on catches ((stats->'tide'->>'tideType'))
  where stats is not null;

create index if not exists catches_stats_moon_phase_idx
  on catches ((stats->'moon'->>'phaseName'))
  where stats is not null;

-- 驗證
-- select column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'catches' and column_name = 'stats';

-- 範例查詢（未來可用）：
-- -- 哪個時段中魚最多？
-- select
--   (stats->'temporal'->>'hour')::int as hour,
--   count(*) as catches,
--   avg(weight) as avg_weight
-- from catches
-- where user_id = 'xxx' and stats is not null
-- group by hour order by hour;

-- -- 大潮 vs 小潮成功率
-- select
--   stats->'tide'->>'tideType' as tide_type,
--   count(*) as catches,
--   avg(weight) as avg_weight
-- from catches
-- where user_id = 'xxx' and stats is not null
-- group by tide_type;