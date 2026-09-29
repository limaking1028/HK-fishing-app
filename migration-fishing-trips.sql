-- ============================================================
-- 釣魚行程表 (FishingTrip) — Route H
-- 一次出釣 = 一個 trip，可包含多條 catch（catches.trip_id 外鍵）
-- 行程獨立於 catch 之外，只存 header 資訊（時間/釣點/備註/統計快照）
-- ============================================================
-- 在 Supabase 專案 → SQL Editor → New query 貼上並執行
-- ============================================================

create table if not exists fishing_trips (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references users(id) on delete cascade,  -- NULL = 示範
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,                                  -- NULL = 進行中
  spot          text,                                         -- 釣點名稱
  spot_area     text,                                         -- 地區
  latitude      numeric(9,6),
  longitude     numeric(9,6),
  notes         text,                                         -- 行程整體備註
  catch_count   int default 0,                               -- 結束時 cache 統計
  total_weight  numeric(8,2) default 0,                      -- 結束時 cache 統計
  created_at    timestamptz default now()
);

-- Indexes
create index if not exists trips_user_id_idx on fishing_trips(user_id);
create index if not exists trips_started_at_idx on fishing_trips(started_at desc);
create index if not exists trips_active_idx on fishing_trips(user_id, ended_at) where ended_at is null;

-- RLS（與 catches 一致：暫時關閉，app code 做權限檢查）
alter table fishing_trips disable row level security;

-- 驗證
-- select table_name, column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'fishing_trips'
-- order by ordinal_position;