-- v157：收回 anon 寫入權限 + 刪除舊用戶備份表
-- 背景：v155 已鎖 public.catches 嘅 anon；v156 留畀 feat/lb-top10-review。
-- 1) _users_legacy_backup 由 migration-email-magic-link.sql 建立，冇任何 view/function/FK/trigger/policy/前端引用，
--    而且 anon 可以經 REST 讀到（含舊 PIN 欄位），所以直接刪除。
-- 2) 前端寫入 users / fishing_trips 全部係登入後（authenticated）；species_limits 前端唔寫；
--    verify-whatsapp-otp 用 service_role。sbRegister（anon 寫 users）已 DEPRECATED 而且冇人呼叫。
-- RLS policy 一律唔改。

drop table if exists public._users_legacy_backup;

revoke insert, update, delete, truncate on public.users, public.fishing_trips, public.species_limits from anon;
revoke truncate on public.users, public.fishing_trips, public.species_limits from authenticated;
