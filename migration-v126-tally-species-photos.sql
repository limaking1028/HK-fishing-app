-- ============================================================
-- v126：快速計數可為每個魚種加相（最多 2 張）
--   trip_tallies.photos：該魚種嘅相片網址
-- 只可存取自己（沿用 v124 RLS）。可重複執行。
-- ============================================================
alter table public.trip_tallies add column if not exists photos text[] not null default '{}';
alter table public.trip_tallies drop constraint if exists trip_tallies_photos_max;
alter table public.trip_tallies add constraint trip_tallies_photos_max
  check (coalesce(array_length(photos, 1), 0) <= 2);
