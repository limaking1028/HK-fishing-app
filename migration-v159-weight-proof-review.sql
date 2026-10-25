-- ============================================================
-- v159：重量王者 = 磅／尺相 + 每條人手審核；所有排行榜只顯示頭 10 名；「我的排名」
--
-- 主人決定（2026-10-25）：
--   * 重量王者：上榜魚獲一定要有一張獨立嘅磅／尺相（catches.proof_path，私人 bucket catch-proof），
--     而且每條都要管理員批准（取代 v156「只審頭 10 名／紀錄」）。只用已批准魚獲排名，每個時段最多 10 名。
--     批准會記低當時嘅魚種、重量、磅相；之後改任何一樣就要重新審核。
--     舊批准（v156，冇 proof_path）即時唔再計，用戶補磅相後重新入審核清單。
--   * 超過 species_limits.max_kg 唔再自動拒絕，只喺審核清單標記「超重」（over_limit）。
--   * 數量王者 / 品種王者：唔使逐條審，沿用 >30 條人手審核（lb_review_queue），只顯示頭 10 名。
--   * lb_my_rank：三個榜都可以查自己嘅名次同差距（只回傳自己，按 auth.uid()）。
-- 拒絕：沿用 admin_set_excluded。紅點（admin_badges / admin_overview）照計 lb_pending_ids，唔使改。
--   * 追加（主人 17:03 批准）：榜上顯示主相（重量 = 該魚獲主相；數量／品種 = 用戶揀嘅代表相，
--     冇揀就用最重一條有相魚獲，同重就最新）；讚（每人每項一次，可取消）。磅相永遠唔會喺任何公開 RPC／view 出現。
-- 可重複執行。需要先執行 v156、v157。
-- ============================================================

-- 1) 欄位
alter table public.catches add column if not exists proof_path text;          -- catch-proof bucket 內路徑：<user_id>/<檔名>
alter table public.lb_catch_approval add column if not exists proof_path text; -- 批准時嘅磅相；舊批准 = null = 唔再計

-- 2) 上榜判定 trigger：檢查 proof_path；超重唔再拒絕（其餘同 prod 現行版本一樣）
CREATE OR REPLACE FUNCTION public.catches_set_eligibility()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  ref_date date;
  lim      numeric;
  reason   text;
begin
  -- v159：磅／尺相路徑只可以係自己嘅 catch-proof/<user_id>/ 資料夾（任何 INSERT / UPDATE 都檢查）
  if new.proof_path is not null and (
       new.user_id is null
       or new.proof_path !~ ('^' || new.user_id::text || '/[A-Za-z0-9._-]+$')
       or position('..' in new.proof_path) > 0) then
    raise exception 'invalid proof_path';
  end if;

  -- admin_excluded 只有管理員（或 SQL Editor）可以改
  if TG_OP = 'INSERT' then
    new.admin_excluded := false;
  elsif auth.uid() is not null and not public.is_admin() then
    new.admin_excluded := old.admin_excluded;
  end if;

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
       and new.admin_excluded is not distinct from old.admin_excluded
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

  if new.admin_excluded then
    reason := 'admin_excluded';
  elsif new.user_id is null then
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
    elsif new.weight_kg is null then
      reason := 'weight_too_high';
    end if;
    -- v159：超過 species_limits.max_kg 唔再自動拒絕，只喺後台審核清單標記「超重」
  end if;

  new.leaderboard_eligible := (reason is null);
  new.ineligible_reason    := reason;
  new.verified             := (reason is null);
  return new;
end;
$$;

-- 3) 重量王者候選（只供內部用）：符合上榜條件 + 有磅相；ok = 有對應（魚種、重量、磅相都一樣）嘅批准
create or replace function public.lb_weight_cand()
returns table (id uuid, user_id uuid, species text, weight_kg numeric, date date, created_at timestamptz, ok boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.user_id, c.species, c.weight_kg, c.date, c.created_at,
         exists (select 1 from public.lb_catch_approval a
                  where a.catch_id = c.id and a.species = c.species and a.weight_kg = c.weight_kg
                    and a.proof_path = c.proof_path) as ok
    from public.catches c
   where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
     and c.proof_path is not null;
$$;
revoke all on function public.lb_weight_cand() from public, anon, authenticated;

-- 4) 待審核 = 所有未批准嘅重量王者候選（取代 v156 頭 10 名規則）
create or replace function public.lb_pending_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.lb_weight_cand() where not ok;
$$;
revoke all on function public.lb_pending_ids() from public, anon, authenticated;

-- 5) 重量王者：見第 12 節（加主相同讚）

-- 6) 數量 / 品種王者：排名邏輯原封不動搬入內部函數（多回傳 user_id，冇上限）；公開函數只顯示頭 10 名
create or replace function public.lb_stats_rows(p_period text default 'all', p_sort text default 'quantity')
returns table (pos int, user_id uuid, catch_count int, species_count int, spot_count int, biggest_kg numeric)
language sql stable security definer set search_path = public as $$
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
         a.user_id, a.catch_count, a.species_count, a.spot_count, a.biggest_kg
    from agg a;
$$;
revoke all on function public.lb_stats_rows(text, text) from public, anon, authenticated;

-- 公開 lb_stats：見第 12 節（加代表相同讚）

-- 7) 我的排名：只回傳 auth.uid() 自己嘅名次、數值、同上一名嘅差距（第 1 名 gap = null）
--    重量：每人最佳一條已批准魚獲；同重量早釣先排（同 lb_biggest）。pending = 自己喺呢個時段有未批准嘅候選。
--    數量 / 品種：同 lb_stats 排名一樣；pending = 自己有行程喺 >30 條人手審核隊列。
create or replace function public.lb_my_rank(p_board text default 'biggest', p_period text default 'all')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_rank int; v_val numeric; v_above numeric; v_total int; v_pending boolean;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_board = 'biggest' then
    with best as (
      select distinct on (w.user_id) w.user_id, w.weight_kg, w.date, w.created_at
        from public.lb_weight_cand() w
       where w.ok and w.date >= public.lb_period_start(p_period)
       order by w.user_id, w.weight_kg desc, w.date asc, w.created_at asc
    ), r as (
      select b.user_id, b.weight_kg as v,
             row_number() over (order by b.weight_kg desc, b.date asc, b.created_at asc)::int as pos
        from best b
    )
    select m.pos, m.v, (select r2.v from r r2 where r2.pos = m.pos - 1), (select count(*)::int from r)
      into v_rank, v_val, v_above, v_total
      from r m where m.user_id = me;
    if v_total is null then select count(distinct w.user_id)::int into v_total from public.lb_weight_cand() w
                             where w.ok and w.date >= public.lb_period_start(p_period); end if;
    select exists (select 1 from public.lb_weight_cand() w
                    where w.user_id = me and not w.ok and w.date >= public.lb_period_start(p_period)) into v_pending;
  elsif p_board in ('quantity', 'species') then
    with r as (
      select s.user_id, s.pos,
             (case when p_board = 'species' then s.species_count else s.catch_count end)::numeric as v
        from public.lb_stats_rows(p_period, p_board) s
    )
    select m.pos, m.v, (select r2.v from r r2 where r2.pos = m.pos - 1), (select count(*)::int from r)
      into v_rank, v_val, v_above, v_total
      from r m where m.user_id = me;
    if v_total is null then select count(*)::int into v_total from public.lb_stats_rows(p_period, p_board); end if;
    select exists (select 1 from public.lb_review_queue q where q.user_id = me) into v_pending;
  else
    raise exception 'bad board';
  end if;
  return jsonb_build_object('board', p_board, 'period', p_period, 'rank', v_rank, 'value', v_val,
                            'gap', case when v_rank > 1 then v_above - v_val end,
                            'total', v_total, 'pending', coalesce(v_pending, false));
end $$;
revoke all on function public.lb_my_rank(text, text) from public, anon;
grant execute on function public.lb_my_rank(text, text) to authenticated;

-- 8) 後台：待審核列表（多回傳磅相路徑同超重標記）
create or replace function public.admin_lb_pending()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
           'id', c.id, 'photo_url', c.photo_url, 'proof_path', c.proof_path,
           'species', c.species, 'weight_kg', c.weight_kg, 'max_kg', s.max_kg,
           'over_limit', (s.max_kg is not null and c.weight_kg > s.max_kg),
           'date', c.date, 'created_at', c.created_at, 'user_id', c.user_id, 'display_name', u.display_name)
           order by c.created_at)
    from public.catches c
    left join public.users u on u.id = c.user_id
    left join public.species_limits s on s.species = c.species
   where c.id in (select public.lb_pending_ids())), '[]'::jsonb);
end $$;

-- 9) 後台：批准（一定要有磅相；記低魚種、重量、磅相）
create or replace function public.admin_lb_approve(p_catch uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.catches;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into r from public.catches where id = p_catch;
  if r.id is null then raise exception 'not found'; end if;
  if r.proof_path is null then raise exception 'no proof photo'; end if;
  insert into public.lb_catch_approval (catch_id, species, weight_kg, proof_path, approved_by)
  values (r.id, r.species, r.weight_kg, r.proof_path, auth.uid())
  on conflict (catch_id) do update set species = excluded.species, weight_kg = excluded.weight_kg,
                                       proof_path = excluded.proof_path,
                                       approved_by = excluded.approved_by, approved_at = now();
  perform public.admin_log('approve_lb_catch', 'catch', p_catch::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_reason,''), 200), ''), 'species', r.species, 'weight_kg', r.weight_kg,
                       'owner', (select display_name from public.users where id = r.user_id)));
end $$;
revoke all on function public.admin_lb_pending() from public, anon;
revoke all on function public.admin_lb_approve(uuid, text) from public, anon;
grant execute on function public.admin_lb_pending() to authenticated;
grant execute on function public.admin_lb_approve(uuid, text) to authenticated;

-- 10) 私人 bucket：磅／尺相（5MB，只收圖片）。本人只可以上載／讀自己資料夾；管理員可以讀全部
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('catch-proof', 'catch-proof', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false;

drop policy if exists "own upload catch proof" on storage.objects;
create policy "own upload catch proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'catch-proof' and (storage.foldername(name))[1] = (auth.uid())::text);
drop policy if exists "own or admin read catch proof" on storage.objects;
create policy "own or admin read catch proof" on storage.objects for select to authenticated
  using (bucket_id = 'catch-proof' and ((storage.foldername(name))[1] = (auth.uid())::text or public.is_admin()));

-- 11) 代表相（數量／品種王者）：每人一行，只可以揀自己、未被排除、有自己 catch-photos 主相嘅魚獲
create table if not exists public.lb_rep_photo (
  user_id  uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  catch_id uuid not null references public.catches(id) on delete cascade,
  updated_at timestamptz not null default now()
);
alter table public.lb_rep_photo enable row level security;
revoke all on public.lb_rep_photo from anon, authenticated;
grant select, insert, update, delete on public.lb_rep_photo to authenticated;
drop policy if exists "rep photo own" on public.lb_rep_photo;
create policy "rep photo own" on public.lb_rep_photo for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.lb_rep_photo_check()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.catches c
                  where c.id = new.catch_id and c.user_id = new.user_id and not c.admin_excluded
                    and position('/catch-photos/' || new.user_id::text || '/' in coalesce(c.photo_url, '')) > 0) then
    raise exception 'not your catch photo';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_lb_rep_photo_check on public.lb_rep_photo;
create trigger trg_lb_rep_photo_check before insert or update on public.lb_rep_photo
  for each row execute function public.lb_rep_photo_check();

-- 公開顯示用主相（只會係 catch-photos 公開 URL）：揀咗就用揀嗰張，否則最重一條（同重取最新）
create or replace function public.lb_user_photo(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.photo_url from public.lb_rep_photo r join public.catches c on c.id = r.catch_id
      where r.user_id = p_user and c.user_id = p_user and not c.admin_excluded
        and position('/catch-photos/' || p_user::text || '/' in coalesce(c.photo_url, '')) > 0),
    (select c.photo_url from public.lb_countable lc join public.catches c on c.id = lc.id
      where c.user_id = p_user and position('/catch-photos/' || p_user::text || '/' in coalesce(c.photo_url, '')) > 0
      order by c.weight_kg desc nulls last, c.created_at desc limit 1));
$$;
revoke all on function public.lb_user_photo(uuid) from public, anon, authenticated;

-- 12) 讚：重量王者 target = catch_id；數量／品種王者 target = 該用戶 user_id（每個榜分開，唔分時段）
create table if not exists public.lb_likes (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  board      text not null check (board in ('biggest', 'quantity', 'species')),
  target     uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, board, target)
);
alter table public.lb_likes enable row level security;
revoke all on public.lb_likes from anon, authenticated;
grant select, insert, delete on public.lb_likes to authenticated;      -- 冇 UPDATE
drop policy if exists "likes read own" on public.lb_likes;
create policy "likes read own" on public.lb_likes for select to authenticated using (user_id = auth.uid());
drop policy if exists "likes insert own" on public.lb_likes;
create policy "likes insert own" on public.lb_likes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "likes delete own" on public.lb_likes;
create policy "likes delete own" on public.lb_likes for delete to authenticated using (user_id = auth.uid());

create or replace function public.lb_likes_check()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.created_at := now();
  if new.board = 'biggest' then
    if not exists (select 1 from public.lb_weight_cand() w where w.id = new.target and w.ok) then
      raise exception 'not on board';
    end if;
  elsif not exists (select 1 from public.lb_countable c where c.user_id = new.target) then
    raise exception 'not on board';
  end if;
  return new;
end $$;
drop trigger if exists trg_lb_likes_check on public.lb_likes;
create trigger trg_lb_likes_check before insert on public.lb_likes
  for each row execute function public.lb_likes_check();

-- 讚數只由 count(*) 計（view owner = postgres，略過 RLS；只出 board / target / 數字）
create or replace view public.lb_like_counts as
  select board, target, count(*)::int as likes from public.lb_likes group by board, target;
revoke all on public.lb_like_counts from public, anon, authenticated;
grant select on public.lb_like_counts to anon, authenticated;

-- 公開榜（回傳欄位有變，要先 drop）。永遠唔回傳 proof_path。
drop function if exists public.lb_biggest(text);
create function public.lb_biggest(p_period text default 'all')
returns table (
  pos int, catch_id uuid, display_name text, is_mine boolean,
  species text, species_icon text, weight_kg numeric, catch_date date, catch_time time, pending boolean,
  photo_url text, like_count int, liked boolean
)
language sql stable security definer set search_path = public as $$
  with best as (
    select distinct on (w.user_id) c.*
      from public.lb_weight_cand() w
      join public.catches c on c.id = w.id
     where w.ok and w.date >= public.lb_period_start(p_period)
     order by w.user_id, c.weight_kg desc, c.date asc, c.created_at asc
  )
  select (row_number() over (order by b.weight_kg desc, b.date asc, b.created_at asc))::int,
         b.id, u.display_name, (b.user_id = auth.uid()),
         b.species, b.species_icon, b.weight_kg, b.date, b.time, false,
         case when position('/catch-photos/' || b.user_id::text || '/' in coalesce(b.photo_url, '')) > 0 then b.photo_url end,
         (select count(*)::int from public.lb_likes l where l.board = 'biggest' and l.target = b.id),
         exists (select 1 from public.lb_likes l where l.board = 'biggest' and l.target = b.id and l.user_id = auth.uid())
    from best b
    left join public.users u on u.id = b.user_id
   order by 1
   limit 10;
$$;
revoke all on function public.lb_biggest(text) from public, anon;
grant execute on function public.lb_biggest(text) to authenticated;

drop function if exists public.lb_stats(text, text);
create function public.lb_stats(p_period text default 'all', p_sort text default 'quantity')
returns table (pos int, display_name text, is_mine boolean,
               catch_count int, species_count int, spot_count int, biggest_kg numeric,
               entry_id uuid, photo_url text, like_count int, liked boolean)
language sql stable security definer set search_path = public as $$
  select s.pos, u.display_name, (s.user_id = auth.uid()),
         s.catch_count, s.species_count, s.spot_count, s.biggest_kg,
         s.user_id, public.lb_user_photo(s.user_id),
         (select count(*)::int from public.lb_likes l
           where l.board = (case when p_sort = 'species' then 'species' else 'quantity' end) and l.target = s.user_id),
         exists (select 1 from public.lb_likes l
           where l.board = (case when p_sort = 'species' then 'species' else 'quantity' end) and l.target = s.user_id
             and l.user_id = auth.uid())
    from public.lb_stats_rows(p_period, p_sort) s
    left join public.users u on u.id = s.user_id
   order by s.pos
   limit 10;
$$;
revoke all on function public.lb_stats(text, text) from public, anon;
grant execute on function public.lb_stats(text, text) to authenticated;
