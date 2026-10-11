-- ============================================================
-- v112：管理後台（admin.html）所需嘅資料庫部分
--
--   * admins 名單：只有名單內嘅帳戶可以用後台函數
--   * catches.admin_excluded：管理員可以將單條魚獲標為「不計排行榜」
--   * 停用帳戶：用 Supabase Auth 嘅 banned_until，被停用者唔再出現喺排行榜
--   * admin_* 函數（SECURITY DEFINER，每個都先檢查 is_admin()）
--
-- 可重複執行。需要先執行 v108、v109、v111。
-- 最後要手動加你自己做管理員（見檔尾）。
-- ============================================================

create table if not exists public.admins (
  user_id    uuid primary key,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;     -- 無 policy
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create or replace function public.is_banned(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from auth.users a where a.id = p_uid and a.banned_until is not null and a.banned_until > now());
$$;
revoke all on function public.is_banned(uuid) from public, anon, authenticated;

alter table public.catches add column if not exists admin_excluded boolean not null default false;

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



-- 計數用魚獲：加入「已停用帳戶唔計」
create or replace view public.lb_countable as
  select c.id, c.user_id, c.trip_id, c.species, c.spot, c.weight_kg, c.date, c.created_at
    from public.catches c
    join public.fishing_trips t on t.id = c.trip_id and t.user_id = c.user_id
   where c.leaderboard_eligible and c.user_id is not null
     and not public.is_banned(c.user_id)
     and c.created_at >= t.started_at
     and (t.ended_at is null or c.created_at <= t.ended_at + interval '10 minutes');
revoke all on public.lb_countable from anon, authenticated;

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
     where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
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


-- ===== 後台函數 =====
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; today date := (now() at time zone 'Asia/Hong_Kong')::date;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'users_total',   (select count(*) from auth.users),
    'users_7d',      (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'users_active_7d', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'catches_total', (select count(*) from public.catches where user_id is not null),
    'catches_today', (select count(*) from public.catches where user_id is not null and (created_at at time zone 'Asia/Hong_Kong')::date = today),
    'catches_7d',    (select count(*) from public.catches where user_id is not null and created_at > now() - interval '7 days'),
    'with_photo',    (select count(*) from public.catches where user_id is not null and photo_url is not null and photo_url <> ''),
    'eligible_total',(select count(*) from public.catches where leaderboard_eligible),
    'trips_total',   (select count(*) from public.fishing_trips where user_id is not null),
    'pending_reviews',(select count(*) from public.lb_review_queue),
    'excluded_total',(select count(*) from public.catches where admin_excluded),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'n', n) order by n desc)
                from (select ineligible_reason as reason, count(*) n from public.catches
                       where not leaderboard_eligible and user_id is not null and ineligible_reason is not null
                         and created_at > now() - interval '30 days' group by 1) q), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'n', n, 'u', u) order by d)
                from (select (created_at at time zone 'Asia/Hong_Kong')::date d, count(*) n, count(distinct user_id) u
                        from public.catches where user_id is not null and created_at > now() - interval '14 days' group by 1) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.admin_review_queue()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'trip_id', q.trip_id, 'species', q.species, 'catch_count', q.catch_count,
      'user_id', q.user_id, 'display_name', q.display_name, 'started_at', q.started_at, 'spot', q.spot,
      'catches', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', c.id, 'photo_url', c.photo_url, 'created_at', c.created_at, 'weight_kg', c.weight_kg,
                    'spot', c.spot, 'latitude', c.latitude, 'longitude', c.longitude) order by c.created_at), '[]'::jsonb)
                    from public.catches c where c.trip_id = q.trip_id and c.species = q.species and c.leaderboard_eligible)
    ) order by q.catch_count desc)
    from public.lb_review_queue q), '[]'::jsonb);
end $$;

create or replace function public.admin_review_done()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'reviewed_at') desc) from (
    select jsonb_build_object('trip_id', r.trip_id, 'species', r.species, 'status', r.status, 'note', r.note,
                              'reviewed_at', r.reviewed_at, 'display_name', u.display_name) x
      from public.lb_review r
      join public.fishing_trips t on t.id = r.trip_id
      left join public.users u on u.id = t.user_id
     order by r.reviewed_at desc limit 50) z), '[]'::jsonb);
end $$;

create or replace function public.admin_review_set(p_trip uuid, p_species text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status = 'pending' then
    delete from public.lb_review where trip_id = p_trip and species = p_species;
  elsif p_status in ('approved','rejected') then
    insert into public.lb_review (trip_id, species, status, note) values (p_trip, p_species, p_status, p_note)
    on conflict (trip_id, species) do update set status = excluded.status, note = excluded.note, reviewed_at = now();
  else
    raise exception 'bad status';
  end if;
end $$;

create or replace function public.admin_photos(p_limit int default 40, p_before timestamptz default null, p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', c.id, 'photo_url', c.photo_url, 'created_at', c.created_at,
             'user_id', c.user_id, 'display_name', u.display_name, 'species', c.species, 'weight_kg', c.weight_kg,
             'spot', c.spot, 'date', c.date, 'eligible', c.leaderboard_eligible, 'reason', c.ineligible_reason,
             'excluded', c.admin_excluded, 'trip_id', c.trip_id) x
      from public.catches c left join public.users u on u.id = c.user_id
     where c.user_id is not null and c.photo_url is not null and c.photo_url <> ''
       and (p_before is null or c.created_at < p_before)
       and (p_user is null or c.user_id = p_user)
     order by c.created_at desc
     limit least(greatest(p_limit, 1), 100)) z), '[]'::jsonb);
end $$;

create or replace function public.admin_set_excluded(p_catch uuid, p_excluded boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.catches;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.catches set admin_excluded = p_excluded where id = p_catch returning * into r;
  return jsonb_build_object('id', r.id, 'eligible', r.leaderboard_eligible, 'reason', r.ineligible_reason, 'excluded', r.admin_excluded);
end $$;

create or replace function public.admin_users(p_limit int default 100, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', a.id, 'email', a.email, 'display_name', u.display_name,
             'created_at', a.created_at, 'last_sign_in_at', a.last_sign_in_at,
             'banned', (a.banned_until is not null and a.banned_until > now()),
             'is_admin', exists (select 1 from public.admins ad where ad.user_id = a.id),
             'catch_count', (select count(*) from public.catches c where c.user_id = a.id),
             'eligible_count', (select count(*) from public.catches c where c.user_id = a.id and c.leaderboard_eligible),
             'trip_count', (select count(*) from public.fishing_trips t where t.user_id = a.id)) x
      from auth.users a left join public.users u on u.id = a.id
     where p_search is null or p_search = ''
        or a.email ilike '%' || p_search || '%' or u.display_name ilike '%' || p_search || '%'
     order by a.created_at desc
     limit least(greatest(p_limit, 1), 300)) z), '[]'::jsonb);
end $$;

create or replace function public.admin_set_ban(p_user uuid, p_banned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_user = auth.uid() or exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'cannot ban admin';
  end if;
  update auth.users set banned_until = case when p_banned then now() + interval '100 years' else null end where id = p_user;
end $$;

do $$
declare f text;
begin
  foreach f in array array['admin_overview()','admin_review_queue()','admin_review_done()',
    'admin_review_set(uuid,text,text,text)','admin_photos(int,timestamptz,uuid)',
    'admin_set_excluded(uuid,boolean)','admin_users(int,text)','admin_set_ban(uuid,boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

revoke all on function public.lb_biggest(text) from public, anon;
grant execute on function public.lb_biggest(text) to authenticated;

-- ===== 最後一步：將你自己加為管理員 =====
-- 把下面電郵改成你登入 App 用嘅電郵，然後單獨執行呢一句：
-- insert into public.admins (user_id) select id from auth.users where email = '你登入App嘅電郵';
