-- v172 rollback: restore pre-v172 functions, drop new objects
begin;
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
           count(distinct o.species)::int as species_count,
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
                     case when p_sort = 'species' then a.biggest_kg else a.species_count end desc,
                     a.user_id))::int,
         a.user_id, a.catch_count, a.species_count, a.spot_count, a.biggest_kg
    from agg a;
$function$;

CREATE OR REPLACE FUNCTION public.lb_my_rank(p_board text DEFAULT 'biggest'::text, p_period text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    select exists (select 1 from public.lb_review_queue q
                    where q.user_id = me
                      and exists (select 1 from public.lb_countable c
                                   where c.trip_id = q.trip_id and c.species = q.species
                                     and c.date >= public.lb_period_start(p_period))) into v_pending;
  else
    raise exception 'bad board';
  end if;
  return jsonb_build_object('board', p_board, 'period', p_period, 'rank', v_rank, 'value', v_val,
                            'gap', case when v_rank > 1 then v_above - v_val end,
                            'total', v_total, 'pending', coalesce(v_pending, false));
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
    'pending_reviews', ((select count(*) from public.lb_review_queue) + (select count(*) from public.lb_pending_ids())),
    'new_feedback',    (select count(*) from public.feedback where status = 'new'));
end $function$;
drop function if exists public.admin_species_review_set(uuid, text, uuid, text, text);
drop function if exists public.admin_species_pending();
drop function if exists public.lb_species_pending();
drop table if exists public.lb_species_review;
commit;
