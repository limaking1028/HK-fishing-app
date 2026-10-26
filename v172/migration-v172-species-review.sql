-- v172 品種王者：每人每個新魚種審一次（主人：「每人每個新魚種審一次」）
-- * 新表 lb_species_review(user_id, species) = approved / rejected；RLS 開、冇 policy、anon/authenticated 冇權限 → 只可經 SECURITY DEFINER + is_admin() 改。
-- * lb_species_pending()：每個 (用戶, 魚種) 未批准、而且有可計魚獲（lb_countable）嘅最早一條（被拒絕就由拒絕嗰條之後嘅下一條再排隊）。內部用，唔畀 anon/authenticated 執行。
-- * lb_stats_rows：species_count 只計已批准魚種；數量王者排序改用原本魚種數 species_raw → 數量王者唔變；品種榜唔列 0 種嘅人。
-- * lb_my_rank：品種榜 pending 包括自己待審核新魚種，另回 pending_species 數。
-- * admin_species_pending() / admin_species_review_set()：is_admin() 先用得。admin_badges 加埋待審數。
-- * 舊資料：本 migration 唔 backfill（預設＝所有現有魚種都要重新審核）；如果主人揀 A，另外跑 v172/backfill-v172-option-A.sql。
begin;

create table if not exists public.lb_species_review (
  user_id uuid not null,
  species text not null,
  status text not null check (status in ('approved', 'rejected')),
  catch_id uuid,
  note text,
  reviewed_by uuid,
  reviewed_at timestamptz not null default now(),
  primary key (user_id, species)
);
alter table public.lb_species_review enable row level security;
revoke all on public.lb_species_review from public, anon, authenticated;

create or replace function public.lb_species_pending()
 returns table(user_id uuid, species text, catch_id uuid, photo_url text, date date, created_at timestamptz)
 language sql stable security definer set search_path to 'public'
as $function$
  select distinct on (c.user_id, c.species) c.user_id, c.species, c.id, x.photo_url, c.date, c.created_at
    from public.lb_countable c
    join public.catches x on x.id = c.id
    left join public.lb_species_review r on r.user_id = c.user_id and r.species = c.species
    left join public.catches rc on rc.id = r.catch_id
   where (r.user_id is null
          or (r.status = 'rejected' and c.created_at > coalesce(rc.created_at, r.reviewed_at)))
   order by c.user_id, c.species, c.created_at, c.id;
$function$;
revoke all on function public.lb_species_pending() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lb_stats_rows(p_period text DEFAULT 'all'::text, p_sort text DEFAULT 'quantity'::text)
 RETURNS TABLE(pos integer, user_id uuid, catch_count integer, species_count integer, spot_count integer, biggest_kg numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           count(distinct o.species) filter (where exists (select 1 from public.lb_species_review sr
                                      where sr.user_id = o.user_id and sr.species = o.species and sr.status = 'approved'))::int as species_count,   -- v172：每人每個新魚種要審核一次
           count(distinct o.species)::int as species_raw,   -- v172：數量王者排序照用原本魚種數（唔受審核影響）
           count(distinct o.spot)::int    as spot_count,
           max(o.weight_kg) filter (where sl.max_kg is null or o.weight_kg <= sl.max_kg
                                    or exists (select 1 from public.lb_catch_approval a
                                                where a.catch_id = o.id and a.weight_kg = o.weight_kg)) as biggest_kg   -- v159：未批准嘅超重唔計
      from ok o
      left join public.species_limits sl on sl.species = o.species
     group by o.user_id
  )
  select (row_number() over (
            order by case when p_sort = 'species' then a.species_count else a.catch_count end desc,
                     case when p_sort = 'species' then a.biggest_kg else a.species_raw end desc,
                     a.user_id))::int,
         a.user_id, a.catch_count, a.species_count, a.spot_count, a.biggest_kg
    from agg a
   where p_sort <> 'species' or a.species_count > 0;   -- v172：品種榜唔顯示 0 個已批准魚種
$function$;

CREATE OR REPLACE FUNCTION public.lb_my_rank(p_board text DEFAULT 'biggest'::text, p_period text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := auth.uid();
  v_rank int; v_val numeric; v_above numeric; v_total int; v_pending boolean; v_pending_sp int := 0;
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
    select exists (select 1 from public.lb_review_queue q
                    where q.user_id = me
                      and exists (select 1 from public.lb_countable c
                                   where c.trip_id = q.trip_id and c.species = q.species
                                     and c.date >= public.lb_period_start(p_period))) into v_pending;
    if p_board = 'species' then   -- v172：新魚種待審核（只計自己）
      select count(*)::int into v_pending_sp from public.lb_species_pending() p where p.user_id = me;
      v_pending := coalesce(v_pending, false) or v_pending_sp > 0;
    end if;
  else
    raise exception 'bad board';
  end if;
  return jsonb_build_object('board', p_board, 'period', p_period, 'rank', v_rank, 'value', v_val,
                            'gap', case when v_rank > 1 then v_above - v_val end,
                            'total', v_total, 'pending', coalesce(v_pending, false), 'pending_species', v_pending_sp);
end $function$;

CREATE OR REPLACE FUNCTION public.admin_badges()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'pending_reviews', ((select count(*) from public.lb_review_queue) + (select count(*) from public.lb_pending_ids())
                         + (select count(*) from public.lb_species_pending())),   -- v172
    'new_feedback',    (select count(*) from public.feedback where status = 'new'));
end $function$;

create or replace function public.admin_species_pending()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
           'user_id', p.user_id, 'species', p.species, 'catch_id', p.catch_id, 'photo_url', p.photo_url,
           'date', p.date, 'created_at', p.created_at, 'display_name', u.display_name,
           'rejected_before', exists (select 1 from public.lb_species_review r where r.user_id = p.user_id and r.species = p.species))
           order by p.created_at)
    from public.lb_species_pending() p left join public.users u on u.id = p.user_id), '[]'::jsonb);
end $function$;

create or replace function public.admin_species_review_set(p_user uuid, p_species text, p_catch uuid, p_status text, p_note text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status = 'pending' then
    delete from public.lb_species_review where user_id = p_user and species = p_species;
  elsif p_status in ('approved', 'rejected') then
    if not exists (select 1 from public.catches where id = p_catch and user_id = p_user and species = p_species) then
      raise exception 'catch does not match user/species';
    end if;
    insert into public.lb_species_review (user_id, species, status, catch_id, note, reviewed_by)
    values (p_user, p_species, p_status, p_catch, nullif(left(coalesce(p_note, ''), 200), ''), auth.uid())
    on conflict (user_id, species) do update set status = excluded.status, catch_id = excluded.catch_id,
      note = excluded.note, reviewed_by = excluded.reviewed_by, reviewed_at = now();
  else
    raise exception 'bad status';
  end if;
  perform public.admin_log('species_review_' || p_status, 'catch', coalesce(p_catch::text, ''),
    jsonb_build_object('species', p_species, 'owner', (select display_name from public.users where id = p_user),
                       'reason', nullif(left(coalesce(p_note, ''), 200), '')));
end $function$;

revoke all on function public.admin_species_pending() from public, anon;
revoke all on function public.admin_species_review_set(uuid, text, uuid, text, text) from public, anon;
grant execute on function public.admin_species_pending() to authenticated;
grant execute on function public.admin_species_review_set(uuid, text, uuid, text, text) to authenticated;

commit;
