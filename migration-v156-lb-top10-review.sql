-- ============================================================
-- v156：重量王者「頭 10 名／魚種紀錄」人手審核
--
--   * 未經管理員批准、會擠入公開頭 10 名或者會成為魚種紀錄嘅魚獲 = 「待審核」（規則見 lb_pending_ids）：
--       - 其他用戶喺重量王者睇唔到（該用戶改為顯示佢下一條已可公開嘅魚獲）
--       - 魚獲主人自己仍然睇到，lb_biggest 多回傳 pending = true，App 顯示「待審核」
--   * 批准：admin_lb_approve（記低批准時嘅魚種同重量；之後改魚種或重量要重新審核）
--   * 排除：沿用 admin_set_excluded
--   * 數量王者 / 品種王者唔變。
-- 可重複執行。需要先執行 v112、v133、v139。
-- ============================================================

create table if not exists public.lb_catch_approval (
  catch_id    uuid primary key references public.catches(id) on delete cascade,
  species     text not null,
  weight_kg   numeric not null,
  approved_by uuid,
  approved_at timestamptz not null default now()
);
alter table public.lb_catch_approval enable row level security;   -- 無 policy
revoke all on public.lb_catch_approval from anon, authenticated;

-- 待審核魚獲 id（只供 SECURITY DEFINER 函數內部用）
-- 規則（唔會用未批准嘅魚獲「補位」）：
--   頭 10 名：每個時段（全期／年／季／月）用「已批准」魚獲排每人最佳，第 10 名重量 = 門檻 T。
--     未批准而重量 >= T 嘅魚獲 = 待審核；已批准唔夠 10 個人時，該時段所有未批准魚獲都係待審核。
--     所以公開榜頭 10 名一定全部係已批准，可能少過 10 個。
--   魚種紀錄：該魚種最重嘅「已批准」魚獲 = 紀錄 R。未批准而重過 R = 待審核；
--     未有已批准時，最重嗰條（或並列）未批准 = 待審核。
create or replace function public.lb_pending_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with cand as (
    select c.id, c.user_id, c.species, c.weight_kg, c.date,
           exists (select 1 from public.lb_catch_approval a
                    where a.catch_id = c.id and a.species = c.species and a.weight_kg = c.weight_kg) as ok
      from public.catches c
     where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
  ),
  per as (
    select p, public.lb_period_start(p) as s from unnest(array['all','year','quarter','month']) p
  ),
  abest as (
    select distinct on (per.p, c.user_id) per.p, c.weight_kg
      from per join cand c on c.ok and c.date >= per.s
     order by per.p, c.user_id, c.weight_kg desc
  ),
  thr as (
    select per.p, per.s,
           (select a.weight_kg from abest a where a.p = per.p order by a.weight_kg desc offset 9 limit 1) as t
      from per
  ),
  rec as (
    select species, max(weight_kg) filter (where ok) as r, max(weight_kg) filter (where not ok) as u
      from cand group by species
  )
  select c.id from cand c join thr on c.date >= thr.s
   where not c.ok and (thr.t is null or c.weight_kg >= thr.t)
  union
  select c.id from cand c join rec on rec.species = c.species
   where not c.ok and ((rec.r is null and c.weight_kg = rec.u) or c.weight_kg > rec.r);
$$;
revoke all on function public.lb_pending_ids() from public, anon, authenticated;

-- 重量王者：加 pending 欄位，返回欄位改變所以要 DROP 再重建
drop function if exists public.lb_biggest(text);
create function public.lb_biggest(p_period text default 'all')
returns table (
  pos int, catch_id uuid, display_name text, is_mine boolean,
  species text, species_icon text, weight_kg numeric, catch_date date, catch_time time, pending boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with pend as (select id from public.lb_pending_ids() id),
  best as (
    select distinct on (c.user_id) c.*, (c.id in (select id from pend)) as is_pending
      from public.catches c
     where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
       and c.date >= public.lb_period_start(p_period)
       and (c.user_id = auth.uid() or c.id not in (select id from pend))
     order by c.user_id, c.weight_kg desc, c.date asc, c.created_at asc
  )
  select (row_number() over (order by b.weight_kg desc, b.date asc, b.created_at asc))::int,
         b.id, u.display_name, (b.user_id = auth.uid()),
         b.species, b.species_icon, b.weight_kg, b.date, b.time, b.is_pending
    from best b
    left join public.users u on u.id = b.user_id
   order by 1
   limit 100;
$$;
revoke all on function public.lb_biggest(text) from public, anon;
grant execute on function public.lb_biggest(text) to authenticated;

-- 後台：待審核列表
create or replace function public.admin_lb_pending()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
           'id', c.id, 'photo_url', c.photo_url, 'species', c.species, 'weight_kg', c.weight_kg,
           'max_kg', (select max_kg from public.species_limits s where s.species = c.species),
           'date', c.date, 'created_at', c.created_at, 'user_id', c.user_id, 'display_name', u.display_name)
           order by c.weight_kg desc)
    from public.catches c
    left join public.users u on u.id = c.user_id
   where c.id in (select public.lb_pending_ids())), '[]'::jsonb);
end $$;

-- 後台：批准（寫入操作記錄）
create or replace function public.admin_lb_approve(p_catch uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.catches;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into r from public.catches where id = p_catch;
  if r.id is null then raise exception 'not found'; end if;
  insert into public.lb_catch_approval (catch_id, species, weight_kg, approved_by)
  values (r.id, r.species, r.weight_kg, auth.uid())
  on conflict (catch_id) do update set species = excluded.species, weight_kg = excluded.weight_kg,
                                       approved_by = excluded.approved_by, approved_at = now();
  perform public.admin_log('approve_lb_catch', 'catch', p_catch::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_reason,''), 200), ''), 'species', r.species, 'weight_kg', r.weight_kg,
                       'owner', (select display_name from public.users where id = r.user_id)));
end $$;

revoke all on function public.admin_lb_pending() from public, anon;
revoke all on function public.admin_lb_approve(uuid, text) from public, anon;
grant execute on function public.admin_lb_pending() to authenticated;
grant execute on function public.admin_lb_approve(uuid, text) to authenticated;

-- 審核中心紅點：計埋重量王者待審核（其他內容同 v139 一樣）

create or replace function public.admin_badges()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'pending_reviews', ((select count(*) from public.lb_review_queue) + (select count(*) from public.lb_pending_ids())),
    'new_feedback',    (select count(*) from public.feedback where status = 'new'));
end $function$;

create or replace function public.admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'pending_reviews',((select count(*) from public.lb_review_queue) + (select count(*) from public.lb_pending_ids())),
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
end $function$;
