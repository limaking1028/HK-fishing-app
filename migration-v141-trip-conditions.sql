-- ============================================================
-- migration-v141：行程環境快照（為將來個人釣魚分析儲數據）
--
-- fishing_trips 加兩個 JSONB 欄位：
--   start_conditions：開始行程時嘅時間／月相／太陽／潮汐／天氣
--   end_conditions  ：結束行程時嘅同一組資料
--
-- 只喺用戶同意「匿名統計」時由 App 寫入（同 catches.stats 一樣）。
-- 冇魚獲嘅行程（空軍）都會有快照，日後先計得到「成功率」。
--
-- 全部 nullable，舊行程唔受影響；App 喺未跑呢個 migration 時會自動略過，唔會出錯。
-- 可以重複執行。
-- ============================================================

alter table public.fishing_trips add column if not exists start_conditions jsonb;
alter table public.fishing_trips add column if not exists end_conditions   jsonb;

-- 防濫用：每個快照限 8KB 以內，而且一定要係 JSON 物件
alter table public.fishing_trips drop constraint if exists fishing_trips_start_conditions_chk;
alter table public.fishing_trips add constraint fishing_trips_start_conditions_chk
  check (start_conditions is null
         or (jsonb_typeof(start_conditions) = 'object' and pg_column_size(start_conditions) <= 8192));

alter table public.fishing_trips drop constraint if exists fishing_trips_end_conditions_chk;
alter table public.fishing_trips add constraint fishing_trips_end_conditions_chk
  check (end_conditions is null
         or (jsonb_typeof(end_conditions) = 'object' and pg_column_size(end_conditions) <= 8192));

-- RLS 唔使改：沿用 v107「trips manage own」，用戶只可以寫自己嘅行程。

-- ---------- 驗證 ----------
-- select column_name, data_type from information_schema.columns
--  where table_schema = 'public' and table_name = 'fishing_trips'
--    and column_name in ('start_conditions', 'end_conditions');
