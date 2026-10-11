-- ============================================================
-- v111：排行榜防作弊
--
--   1. 相片唔可以重複：同一張相（SHA-256 指紋）只計一次（全站）
--   2. 數量王者 / 品種王者：魚獲必須屬於自己嘅行程，而且喺行程時間內建立
--   3. 數量王者 / 品種王者：同一用戶兩條計數魚獲最少相隔 1 分鐘
--   4. 同一行程 + 同一魚種超過 30 條：需要人手審核（批准後先計）
--   重量王者唔受 2、3、4 影響。
--
-- 人手審核：喺 SQL Editor 睇 view lb_review_queue，然後 upsert lb_review（見檔尾）
-- 可重複執行。需要先執行 v108、v109。
-- ============================================================

alter table public.catches add column if not exists photo_hash text;
create index if not exists catches_photo_hash_idx on public.catches (photo_hash) where photo_hash is not null;

create or replace function public.catches_set_eligibility()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ref_date date;
  lim      numeric;
  reason   text;
begin
  -- UPDATE：只有關鍵欄位改變先重新判定，否則保留原判定（防止用戶自行改 verified / eligible）
  if TG_OP = 'UPDATE' then
    if new.photo_url is not distinct from old.photo_url
       and new.photo_age_sec is not distinct from old.photo_age_sec
       and new.latitude is not distinct from old.latitude
       and new.longitude is not distinct from old.longitude
       and new.date is not distinct from old.date
       and new.species is not distinct from old.species
       and new.weight_kg is not distinct from old.weight_kg
       and new.photo_hash is not distinct from old.photo_hash
       and new.user_id is not distinct from old.user_id then
      new.leaderboard_eligible := old.leaderboard_eligible;
      new.ineligible_reason    := old.ineligible_reason;
      new.verified             := old.verified;
      return new;
    end if;
    ref_date := (old.created_at at time zone 'Asia/Hong_Kong')::date;   -- 以建立當日計，避免日子過咗先失效
  else
    ref_date := (now() at time zone 'Asia/Hong_Kong')::date;
  end if;

  if new.user_id is null then
    reason := 'demo';
  elsif new.photo_url is null or new.photo_url = '' then
    reason := 'no_photo';
  elsif position('/catch-photos/' || new.user_id::text || '/' in new.photo_url) = 0 then
    reason := 'photo_invalid';
  elsif new.photo_hash is null or new.photo_hash = '' then
    reason := 'photo_invalid';
  elsif exists (select 1 from public.catches o
                 where o.photo_hash = new.photo_hash and o.id is distinct from new.id) then
    reason := 'photo_duplicate';
  elsif new.photo_age_sec is null or new.photo_age_sec > 1800 or new.photo_age_sec < -60 then
    reason := 'photo_not_fresh';
  elsif new.latitude is null or new.longitude is null then
    reason := 'no_gps';
  elsif not (new.latitude between 22.15 and 22.56 and new.longitude between 113.85 and 114.45) then
    reason := 'outside_hk';
  elsif new.date > ref_date then
    reason := 'date_future';
  elsif new.date < ref_date - 7 then
    reason := 'date_old';
  else
    select max_kg into lim from public.species_limits where species = new.species;
    if lim is null then
      reason := 'species_not_listed';
    elsif new.weight_kg is null or new.weight_kg > lim then
      reason := 'weight_too_high';
    end if;
  end if;

  new.leaderboard_eligible := (reason is null);
  new.ineligible_reason    := reason;
  new.verified             := (reason is null);
  return new;
end;
$$;


-- 審核表（無 policy = 一般用戶讀唔到，只有 SQL Editor / 函數可用）
create table if not exists public.lb_review (
  trip_id     uuid not null references public.fishing_trips(id) on delete cascade,
  species     text not null,
  status      text not null check (status in ('approved','rejected')),
  note        text,
  reviewed_at timestamptz not null default now(),
  primary key (trip_id, species)
);
alter table public.lb_review enable row level security;
revoke all on public.lb_review from anon, authenticated;

-- 計數用魚獲：合資格 + 屬於自己行程 + 喺行程時間內
create or replace view public.lb_countable as
  select c.id, c.user_id, c.trip_id, c.species, c.spot, c.weight_kg, c.date, c.created_at
    from public.catches c
    join public.fishing_trips t on t.id = c.trip_id and t.user_id = c.user_id
   where c.leaderboard_eligible and c.user_id is not null
     and c.created_at >= t.started_at
     and (t.ended_at is null or c.created_at <= t.ended_at + interval '10 minutes');
revoke all on public.lb_countable from anon, authenticated;

-- 待審核：同一行程 + 魚種 > 30 條，而且未有審核結果
create or replace view public.lb_review_queue as
  select g.trip_id, g.species, g.n as catch_count, t.user_id, u.display_name, t.started_at, t.spot
    from (select trip_id, species, count(*) n from public.lb_countable group by 1,2 having count(*) > 30) g
    join public.fishing_trips t on t.id = g.trip_id
    left join public.users u on u.id = t.user_id
    left join public.lb_review r on r.trip_id = g.trip_id and r.species = g.species
   where r.trip_id is null
   order by g.n desc;
revoke all on public.lb_review_queue from anon, authenticated;

-- 數量王者 / 品種王者
create or replace function public.lb_stats(p_period text default 'all', p_sort text default 'quantity')
returns table (
  pos int, display_name text, is_mine boolean,
  catch_count int, species_count int, spot_count int, biggest_kg numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select c.*,
           count(*) over (partition by c.trip_id, c.species) as grp_n,
           lag(c.created_at) over (partition by c.user_id order by c.created_at, c.id) as prev_at
      from public.lb_countable c
     where c.date >= public.lb_period_start(p_period)
  ),
  ok as (
    select b.* from base b
      left join public.lb_review r on r.trip_id = b.trip_id and r.species = b.species
     where (b.grp_n <= 30 or r.status = 'approved')
       and (b.prev_at is null or b.created_at - b.prev_at >= interval '1 minute')
  ),
  agg as (
    select o.user_id,
           count(*)::int                  as catch_count,
           count(distinct o.species)::int as species_count,
           count(distinct o.spot)::int    as spot_count,
           max(o.weight_kg)               as biggest_kg
      from ok o
     group by o.user_id
  )
  select (row_number() over (
            order by case when p_sort = 'species' then a.species_count else a.catch_count end desc,
                     case when p_sort = 'species' then a.biggest_kg else a.species_count end desc,
                     a.user_id))::int,
         u.display_name, (a.user_id = auth.uid()),
         a.catch_count, a.species_count, a.spot_count, a.biggest_kg
    from agg a
    left join public.users u on u.id = a.user_id
   order by 1
   limit 100;
$$;
revoke all on function public.lb_stats(text, text)    from public, anon;
grant execute on function public.lb_stats(text, text) to authenticated;

-- ===== 人手審核用法（SQL Editor）=====
-- 1) 睇待審核：   select * from public.lb_review_queue;
-- 2) 批准：       insert into public.lb_review (trip_id, species, status, note)
--                 values ('<trip_id>', '<species>', 'approved', '睇過相冇問題')
--                 on conflict (trip_id, species) do update set status = excluded.status, note = excluded.note, reviewed_at = now();
-- 3) 拒絕：同上，status 改為 'rejected'
