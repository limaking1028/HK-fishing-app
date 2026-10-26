-- v174 舊帳戶補號（⚠️ 未套用；主人揀一個方案先跑，只可以喺 migration 之後跑一次）
-- 次序：每個帳戶第一條「非測試」魚獲嘅時間（早→遲）。只計 public.users 仲存在嘅帳戶。
-- 已刪除帳戶（孤兒魚獲）同冇擁有者嘅魚獲唔派號。

-- 方案 A：全部現有帳戶照第一條魚次序派號
-- insert into public.founders (user_id, no, first_catch_at)
-- select user_id, row_number() over (order by f, user_id), f from (
--   select c.user_id, min(c.created_at) f from public.catches c join public.users u on u.id = c.user_id
--    where not coalesce(c.is_test, false) group by c.user_id) x
-- order by f limit 100
-- on conflict do nothing;

-- 方案 B：同 A 一樣，但剔走主人指定嘅測試／示範帳戶（將 id 填入 excluded）
-- with excluded(id) as (values ('00000000-0000-0000-0000-000000000000'::uuid))
-- insert into public.founders (user_id, no, first_catch_at)
-- select user_id, row_number() over (order by f, user_id), f from (
--   select c.user_id, min(c.created_at) f from public.catches c join public.users u on u.id = c.user_id
--    where not coalesce(c.is_test, false) and c.user_id not in (select id from excluded) group by c.user_id) x
-- order by f limit 100
-- on conflict do nothing;

-- 方案 C：唔補號，由 migration 上線後第一條魚開始計（舊帳戶下次記魚先攞號）
