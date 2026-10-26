-- v173 rollback：刪走計數表同函數（計數數據會一齊冇咗）
begin;
drop function if exists public.admin_daily_counts(integer);
drop function if exists public.track_event(text, text);
drop table if exists public.app_daily_counts;
commit;
