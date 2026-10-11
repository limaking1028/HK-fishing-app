-- ============================================================
-- v124：快速計數（連續上魚時唔使逐條記錄）
--
--   * trip_tallies：每個行程、每個魚種一行數量（只可存取自己）
--   * fishing_trips.haul_photos：行程嘅「收成相」網址（建議 1–3 張）
--
-- 計數唔會影響任何排行榜（只用於個人記錄／統計）。
-- 刪除行程或帳戶時會連帶刪除（on delete cascade）。可重複執行。
-- ============================================================

alter table public.fishing_trips add column if not exists haul_photos text[] not null default '{}';

create table if not exists public.trip_tallies (
  trip_id    uuid not null references public.fishing_trips(id) on delete cascade,
  user_id    uuid not null,
  species    text not null check (char_length(species) between 1 and 40),
  qty        integer not null check (qty between 0 and 9999),
  updated_at timestamptz not null default now(),
  primary key (trip_id, species)
);
create index if not exists trip_tallies_user_idx on public.trip_tallies (user_id);

alter table public.trip_tallies enable row level security;
drop policy if exists "tallies read own" on public.trip_tallies;
create policy "tallies read own" on public.trip_tallies
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "tallies write own" on public.trip_tallies;
create policy "tallies write own" on public.trip_tallies
  for all to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.fishing_trips t where t.id = trip_id and t.user_id = auth.uid())
  );
revoke all on public.trip_tallies from anon;
grant select, insert, update, delete on public.trip_tallies to authenticated;

create or replace function public.trip_tallies_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists trip_tallies_touch on public.trip_tallies;
create trigger trip_tallies_touch before insert or update on public.trip_tallies
  for each row execute function public.trip_tallies_touch();

-- 收成相最多 3 張
alter table public.fishing_trips drop constraint if exists fishing_trips_haul_photos_max;
alter table public.fishing_trips add constraint fishing_trips_haul_photos_max
  check (coalesce(array_length(haul_photos, 1), 0) <= 3);
