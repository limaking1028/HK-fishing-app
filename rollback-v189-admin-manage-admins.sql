-- 撤回 v189：只刪兩個新函數；唔郁 admins／founders_excluded 嘅資料。
begin;
drop function if exists public.admin_set_admin(uuid, boolean);
drop function if exists public.admin_admins_list();
commit;
