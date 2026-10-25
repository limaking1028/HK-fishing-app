-- ============================================================
-- v156：重量王者「頭 10 名／魚種紀錄」人手審核
--
--   * 以「全期」計，每人最大一條有效魚獲排頭 10 名，或者係某魚種最重嘅一條，
--     如果未經管理員批准，就屬於「待審核」：
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
create or replace function public.lb_pending_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with cand as (
    select c.* from public.catches c
     where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
  ),
  best as (
    select distinct on (c.user_id) c.* from cand c
     order by c.user_id, c.weight_kg desc, c.date asc, c.created_at asc
  ),
  top10 as (
    select b.id from best b order by b.weight_kg desc, b.date asc, b.created_at asc limit 10
  ),
  rec as (
    select c.id from cand c
     where c.weight_kg = (select max(x.weight_kg) from cand x where x.species = c.species)
  )
  select c.id
    from cand c
   where c.id in (select id from top10 union select id from rec)
     and not exists (select 1 from public.lb_catch_approval a
                      where a.catch_id = c.id and a.species = c.species and a.weight_kg = c.weight_kg);
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
