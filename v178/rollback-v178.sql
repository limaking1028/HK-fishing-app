-- v178 rollback：還原 lb_weight_cand 同 lb_countable 做 v178 之前嘅定義（同 backup-pre-v178.sql 一樣）
-- 唔郁 founders_excluded（佢屬於 v174b）。
begin;
comment on table public.founders_excluded is null;

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
     and (not c.is_test or public.is_admin());
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
  WHERE (c.leaderboard_eligible AND (c.user_id IS NOT NULL) AND (NOT is_banned(c.user_id)) AND (c.created_at >= t.started_at) AND ((t.ended_at IS NULL) OR (c.created_at <= (t.ended_at + '00:10:00'::interval))) AND ((NOT c.is_test) OR is_admin()));
commit;
