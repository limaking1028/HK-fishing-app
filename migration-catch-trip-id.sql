-- ============================================================
-- catches 表加 trip_id 欄位 — Route H
-- 把原本扁平的「一筆 catch = 一次出釣」改為「catch 可屬於某 trip」
-- 設 nullable，向後相容所有現有魚獲
-- ============================================================
-- 在 Supabase 專案 → SQL Editor → New query 貼上並執行
-- ============================================================

alter table catches
  add column if not exists trip_id uuid references fishing_trips(id) on delete set null;

create index if not exists catches_trip_id_idx on catches(trip_id) where trip_id is not null;

-- 驗證
-- select column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'catches' and column_name = 'trip_id';