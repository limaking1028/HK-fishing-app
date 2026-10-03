-- ============================================================
-- catches 表加 opted_in_analytics 旗標 — Route M 用戶隱私同意
--
-- 用途：
--   記錄「這筆魚獲被記錄時,用戶是否同意匿名化統計用於產品改進」
--   向後相容:舊魚獲預設為 false(等於明確「未同意」)
--   法務依據:PDPA / GDPR 「明確同意」(opt-in) 原則
--
-- 用戶同意與否存於 localStorage('hk-fishing-analytics-consent'),
-- 每次寫入魚獲時帶到雲端作為稽核軌跡(audit trail)。
-- ============================================================

alter table catches
  add column if not exists opted_in_analytics boolean default false;

-- 部分索引:方便日後查「所有已同意用戶」的整體規律(未同意的不納入分析)
-- 注意:catches 表沒有 caught_at 欄位,用 date 替代
create index if not exists catches_opted_in_idx
  on catches (opted_in_analytics, date desc)
  where opted_in_analytics = true;

-- 驗證
-- select column_name, data_type, column_default
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'catches' and column_name = 'opted_in_analytics';

-- 範例:看用戶同意率
-- select
--   opted_in_analytics,
--   count(*) as n,
--   min(caught_at) as first_catch,
--   max(caught_at) as latest_catch
-- from catches
-- group by opted_in_analytics;
