-- v172 OPTION A（可選，預設唔跑）：將現有已計入品種王者嘅 (用戶, 魚種) 當已批准
-- 要喺 migration-v172-species-review.sql 之後先跑；跑之前要主人揀 A。
begin;
insert into public.lb_species_review (user_id, species, status, catch_id, note, reviewed_by)
select p.user_id, p.species, 'approved', p.catch_id, 'v172 backfill (option A)', null
  from public.lb_species_pending() p
on conflict (user_id, species) do nothing;
commit;
-- OPTION B = 唔跑呢個檔（全部重新排隊審核）
