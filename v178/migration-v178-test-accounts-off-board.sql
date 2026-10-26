-- v178 測試帳戶嘅魚唔上任何排行榜（主人：「測試帳戶嘅魚唔好上排行榜」）
-- 範圍：重用 v174b 嘅 founders_excluded 名單（10月14日測試94、10月14日測試02FP、釣友testuser）。
-- 只改兩個「榜根」：lb_weight_cand()（重量榜／lb_my_rank／讚好檢查／待審）同 lb_countable view（數量／品種王者／lb_my_rank／品種待審／代表相）。
-- 所有榜 function（lb_biggest、lb_stats、lb_stats_rows、lb_my_rank、lb_pending_ids、lb_species_pending、lb_user_photo、
-- lb_likes_check、admin_badges、share_catch_get 排名）都經呢兩個讀，所以一齊生效；舊魚新魚都一樣。
-- 唔郁 catches、eligibility trigger、leaderboard_eligible 欄；冇停 trigger、冇 LOCK；冇新權限（ACL 保留）。
-- 管理員都睇唔到測試帳戶上榜（唔似 is_test 咁對 admin 開放）。
begin;
comment on table public.founders_excluded is '測試帳戶：唔派創始號（v174b）、唔上排行榜（v178）。admin-only，冇 anon/authenticated 權限。';

CREATE OR REPLACE FUNCTION public.lb_weight_cand()
 RETURNS TABLE(id uuid, user_id uuid, species text, weight_kg numeric, date date, created_at timestamp with time zone, ok boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.user_id, c.species, c.weight_kg, c.date, c.created_at,
         exists (select 1 from public.lb_catch_approval a
                  where a.catch_id = c.id and a.species = c.species and a.weight_kg = c.weight_kg
                    and a.proof_path = c.proof_path and a.photo_url is not distinct from c.photo_url) as ok
    from public.catches c
   where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
     and c.proof_path is not null
     and (not c.is_test or public.is_admin())
     and not exists (select 1 from public.founders_excluded e where e.user_id = c.user_id);   -- v178
$function$;

CREATE OR REPLACE VIEW public.lb_countable AS
 SELECT c.id,
    c.user_id,
    c.trip_id,
    c.species,
    c.spot,
    c.weight_kg,
    c.date,
    c.created_at
   FROM (catches c
     JOIN fishing_trips t ON (((t.id = c.trip_id) AND (t.user_id = c.user_id))))
  WHERE (c.leaderboard_eligible AND (c.user_id IS NOT NULL) AND (NOT is_banned(c.user_id)) AND (c.created_at >= t.started_at) AND ((t.ended_at IS NULL) OR (c.created_at <= (t.ended_at + '00:10:00'::interval))) AND ((NOT c.is_test) OR is_admin())
    AND (NOT (EXISTS (SELECT 1 FROM founders_excluded e WHERE (e.user_id = c.user_id)))));   -- v178
commit;
