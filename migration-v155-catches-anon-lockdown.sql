-- ============================================================
-- v155：catches 表收緊 anon（未登入）權限
--
-- 背景：即時資料庫有 3 條唔喺任何 migration 入面嘅 anon policy，
--   令未登入者可以讀晒所有魚獲（包括 user_id、GPS），
--   亦可以用任何 user_id 新增／修改魚獲，繞過排行榜檢查。
-- App 所有 catches 讀寫都需要登入（state.user），排行榜用
-- SECURITY DEFINER 函數 lb_biggest / lb_stats（只授權 authenticated），
-- 所以移除後唔影響正常使用。
-- 只改 catches 嘅 anon 權限，其他 policy 不變。可重複執行。
-- ============================================================

drop policy if exists anon_read_catches       on public.catches;
drop policy if exists anon_insert_catches     on public.catches;
drop policy if exists anon_update_own_catches on public.catches;

revoke insert, update, delete, truncate on public.catches from anon;
revoke truncate on public.catches from authenticated;

-- 驗證（應該冇 anon policy；anon 冇寫入權限）
-- select policyname, roles, cmd from pg_policies where tablename = 'catches';
-- select grantee, privilege_type from information_schema.role_table_grants
--  where table_schema = 'public' and table_name = 'catches' and grantee in ('anon','authenticated');
