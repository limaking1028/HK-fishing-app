-- ============================================================
-- v109：排行榜上榜條件 + 多人排行榜
--
-- 上榜條件（由資料庫 trigger 判定，App 無法自行決定）：
--   1. 附照片（路徑必須喺自己嘅 catch-photos/<user_id>/ 之下）
--   2. 照片係即時影（App 回報嘅 photo_age_sec ≤ 1800 秒）
--   3. 有 GPS，而且喺香港範圍（緯度 22.15–22.56、經度 113.85–114.45）
--   4. 日期唔係未來，亦唔早過 7 日前（以香港日期計）
--   5. 魚種喺 species_limits 列表內
--   6. 重量唔超過該魚種上限
--
-- 排行榜用 SECURITY DEFINER 函數回傳：只有顯示名稱、魚種、重量、釣點、日期，
-- 唔會洩露其他用戶嘅 user_id、座標、電郵。
-- 可重複執行。請在 Supabase SQL Editor 執行（需要先執行過 v108）。
-- ============================================================

-- 1) 欄位
alter table public.catches add column if not exists photo_age_sec         integer;
alter table public.catches add column if not exists leaderboard_eligible  boolean not null default false;
alter table public.catches add column if not exists ineligible_reason     text;
create index if not exists catches_lb_idx on public.catches (date) where leaderboard_eligible;

-- 2) 魚種重量上限（公斤）
create table if not exists public.species_limits (
  species text primary key,
  max_kg  numeric(6,2) not null check (max_kg > 0 and max_kg < 61)
);
alter table public.species_limits enable row level security;   -- 無 policy = 只有 trigger / 函數可讀
insert into public.species_limits (species, max_kg) values
  ('泥鯭', 1.5),
  ('石狗公', 2),
  ('釘公', 1.5),
  ('黃腳鱲', 3),
  ('雞泡', 2),
  ('沙鯭', 0.8),
  ('黑鱲', 6),
  ('牛屎鱲', 3),
  ('三鬚', 1.5),
  ('梳羅', 4),
  ('牛鰍', 8),
  ('油蠟', 3),
  ('紅衫魚', 1),
  ('盲鰽', 1),
  ('金鼓', 1.5),
  ('烏頭', 8),
  ('沙鑽', 0.5),
  ('沙巴龍躉', 20),
  ('赤鱲', 15),
  ('火點', 3),
  ('牙點', 0.5),
  ('左口', 10),
  ('石蚌', 2),
  ('坑鰜', 2),
  ('連尖', 30),
  ('哨牙妹', 0.3),
  ('紅鮋', 2),
  ('三刀', 5),
  ('細鱗', 1.5),
  ('白鬚公', 8),
  ('海狼', 3),
  ('煙仔', 0.8),
  ('馬友', 10),
  ('花鱸', 10),
  ('星鱸', 5),
  ('黃立鯧', 8),
  ('石剎', 0.5),
  ('黃花', 3),
  ('䱛仔', 2),
  ('雞魚', 3),
  ('牛廣GT', 59),
  ('魔鬼魚', 59),
  ('青斑', 20),
  ('芝麻斑', 30),
  ('白鱲', 3),
  ('星點泥鯭', 1.5)
on conflict (species) do update set max_kg = excluded.max_kg;

-- 3) 舊資料：全部標記為不符（冇相片拍攝時間資料）。必須喺建立 trigger 之前執行
update public.catches
   set leaderboard_eligible = false,
       verified = false,
       ineligible_reason = case when user_id is null then 'demo' else 'legacy' end
 where ineligible_reason is null and leaderboard_eligible = false;

-- 4) 上榜判定 trigger
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

drop trigger if exists catches_eligibility on public.catches;
create trigger catches_eligibility
  before insert or update on public.catches
  for each row execute function public.catches_set_eligibility();

-- 5) 排行榜函數
create or replace function public.lb_period_start(p_period text)
returns date
language sql
stable
as $$
  select case p_period
    when 'year'    then date_trunc('year',    now() at time zone 'Asia/Hong_Kong')::date
    when 'quarter' then date_trunc('quarter', now() at time zone 'Asia/Hong_Kong')::date
    when 'month'   then date_trunc('month',   now() at time zone 'Asia/Hong_Kong')::date
    else date '1900-01-01'
  end;
$$;

-- 重量王者：每個用戶最大嘅一條有效魚獲
create or replace function public.lb_biggest(p_period text default 'all')
returns table (
  pos int, catch_id uuid, display_name text, is_mine boolean,
  species text, species_icon text, weight_kg numeric, spot text, catch_date date, catch_time time
)
language sql
stable
security definer
set search_path = public
as $$
  with best as (
    select distinct on (c.user_id) c.*
      from public.catches c
     where c.leaderboard_eligible and c.user_id is not null
       and c.date >= public.lb_period_start(p_period)
     order by c.user_id, c.weight_kg desc, c.date asc, c.created_at asc
  )
  select (row_number() over (order by b.weight_kg desc, b.date asc, b.created_at asc))::int,
         b.id, u.display_name, (b.user_id = auth.uid()),
         b.species, b.species_icon, b.weight_kg, b.spot, b.date, b.time
    from best b
    left join public.users u on u.id = b.user_id
   order by 1
   limit 100;
$$;

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
  with agg as (
    select c.user_id,
           count(*)::int                  as catch_count,
           count(distinct c.species)::int as species_count,
           count(distinct c.spot)::int    as spot_count,
           max(c.weight_kg)               as biggest_kg
      from public.catches c
     where c.leaderboard_eligible and c.user_id is not null
       and c.date >= public.lb_period_start(p_period)
     group by c.user_id
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

revoke all on function public.lb_biggest(text)        from public, anon;
revoke all on function public.lb_stats(text, text)    from public, anon;
grant execute on function public.lb_biggest(text)     to authenticated;
grant execute on function public.lb_stats(text, text) to authenticated;
