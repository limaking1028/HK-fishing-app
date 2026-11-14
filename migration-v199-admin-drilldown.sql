-- v199: read-only admin drilldown. Do not run against production automatically.
-- Last usage is an HK hourly bucket, not an exact event timestamp.
-- admin_users_usage: searchable users with HK usage totals and optional KPI filters.
create or replace function public.admin_users_usage(p_limit int default 100, p_search text default null, p_filter text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'last_usage_at') desc nulls last, x->>'id') from (
    select jsonb_build_object('id', a.id, 'email', a.email, 'display_name', u.display_name,
             'usage_min_30d', (select coalesce(sum(seconds),0)/60 from public.app_usage x where x.user_id=a.id and x.day >= (now() at time zone 'Asia/Hong_Kong')::date-29),
             'active_days_30d', (select count(distinct day) from public.app_usage x where x.user_id=a.id and x.day >= (now() at time zone 'Asia/Hong_Kong')::date-29),
             'usage_min_7d', (select coalesce(sum(seconds),0)/60 from public.app_usage x where x.user_id=a.id and x.day >= (now() at time zone 'Asia/Hong_Kong')::date-6),
             'active_7d', exists(select 1 from public.app_usage x where x.user_id=a.id and x.day >= (now() at time zone 'Asia/Hong_Kong')::date-6),
             'last_usage_at', (select max((x.day + make_interval(hours=>x.hour)) at time zone 'Asia/Hong_Kong') from public.app_usage x where x.user_id=a.id),
             'kpi_excluded', exists(select 1 from public.founders_excluded fx where fx.user_id=a.id),
             'created_at', a.created_at, 'last_sign_in_at', a.last_sign_in_at,
             'banned', (a.banned_until is not null and a.banned_until > now()),
             'is_admin', exists (select 1 from public.admins ad where ad.user_id = a.id),
             'catch_count', (select count(*) from public.catches c where c.user_id = a.id),
             'eligible_count', (select count(*) from public.catches c where c.user_id = a.id and c.leaderboard_eligible),
             'trip_count', (select count(*) from public.fishing_trips t where t.user_id = a.id)) x
      from auth.users a left join public.users u on u.id = a.id
     where (p_search is null or p_search = '' or a.email ilike '%' || p_search || '%' or u.display_name ilike '%' || p_search || '%')
       and (p_filter is null or not exists(select 1 from public.founders_excluded fx where fx.user_id=a.id))
       and (p_filter is distinct from 'registered7' or a.created_at > now()-interval '7 days')
       and (p_filter is distinct from 'active7' or exists(select 1 from public.app_usage x where x.user_id=a.id and x.day >= (now() at time zone 'Asia/Hong_Kong')::date-6))
     order by (select max(x.day + make_interval(hours=>x.hour)) from public.app_usage x where x.user_id=a.id) desc nulls last, a.id
     limit least(greatest(p_limit, 1), 300)) z), '[]'::jsonb);
end $$;


-- admin_catches_list: stable paged catch drilldowns using existing eligibility reasons.
create or replace function public.admin_catches_list(p_filter text default null, p_days integer default null,
 p_reason text default null, p_date date default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
 if not public.is_admin() then raise exception 'forbidden'; end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc, q.id desc) from (
  select c.id, c.created_at, c.user_id, u.display_name, c.species, c.weight_kg, c.spot,
   c.photo_url, c.leaderboard_eligible as eligible, c.ineligible_reason as reason,
   c.admin_excluded as excluded, c.trip_id
  from public.catches c left join public.users u on u.id=c.user_id
  where c.user_id is not null
   and not exists(select 1 from public.founders_excluded fx where fx.user_id=c.user_id)
   and (p_filter is distinct from 'photo' or nullif(c.photo_url,'') is not null)
   and (p_filter is distinct from 'ineligible' or not c.leaderboard_eligible)
   and (p_filter is distinct from 'excluded' or c.admin_excluded)
   and (p_days is null or c.created_at > now()-make_interval(days=>greatest(1,least(p_days,365))))
   and (p_reason is null or (not c.leaderboard_eligible and c.ineligible_reason=p_reason))
   and (p_date is null or (c.created_at at time zone 'Asia/Hong_Kong')::date=p_date)
  order by c.created_at desc,c.id desc limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
 ) q),'[]'::jsonb);
end $$;

-- admin_trips_list: paged trips with users, start/end times and linked catch counts.
create or replace function public.admin_trips_list(p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
 if not public.is_admin() then raise exception 'forbidden'; end if;
 return coalesce((select jsonb_agg(to_jsonb(q) order by q.started_at desc,q.id desc) from (
  select t.id,t.user_id,u.display_name,t.started_at,t.ended_at,
   (select count(*) from public.catches c where c.trip_id=t.id) as catch_count
  from public.fishing_trips t left join public.users u on u.id=t.user_id
  where t.user_id is not null and not exists(select 1 from public.founders_excluded fx where fx.user_id=t.user_id)
  order by t.started_at desc,t.id desc limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
 ) q),'[]'::jsonb);
end $$;

-- admin_overview_drilldown: existing KPIs plus gap-free daily stats and reason demographics.
create or replace function public.admin_overview_drilldown()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Hong_Kong')::date;
begin
 if not public.is_admin() then raise exception 'forbidden'; end if;
 return public.admin_overview() || jsonb_build_object(
  'users_active_7d',(select count(distinct x.user_id) from public.app_usage x join auth.users a on a.id=x.user_id
    where x.day>=today-6 and not exists(select 1 from public.founders_excluded fx where fx.user_id=x.user_id)),
  'daily', (select jsonb_agg(jsonb_build_object('d',d.day,
    'n',(select count(*) from public.catches c where c.user_id is not null and (c.created_at at time zone 'Asia/Hong_Kong')::date=d.day and not exists(select 1 from public.founders_excluded fx where fx.user_id=c.user_id)),
    'new_users',(select count(*) from auth.users a where (a.created_at at time zone 'Asia/Hong_Kong')::date=d.day and not exists(select 1 from public.founders_excluded fx where fx.user_id=a.id)),
    'active_users',(select count(distinct x.user_id) from public.app_usage x join auth.users a on a.id=x.user_id where x.day=d.day and not exists(select 1 from public.founders_excluded fx where fx.user_id=x.user_id))) order by d.day)
    from (select today-i as day from generate_series(0,13) i) d),
  'reasons',coalesce((select jsonb_agg(to_jsonb(q) order by q.n desc,q.reason) from (
    select c.ineligible_reason as reason,count(*) as n,count(distinct c.user_id) as users,
      count(distinct c.user_id) filter(where c.created_at>=a.created_at and c.created_at<a.created_at+interval '7 days') as new_users
    from public.catches c join auth.users a on a.id=c.user_id
    where not c.leaderboard_eligible and c.ineligible_reason is not null and c.created_at>now()-interval '30 days'
      and not exists(select 1 from public.founders_excluded fx where fx.user_id=c.user_id)
    group by c.ineligible_reason) q),'[]'::jsonb));
end $$;

revoke all on function public.admin_users_usage(integer,text,text) from public, anon;
grant execute on function public.admin_users_usage(integer,text,text) to authenticated;

revoke all on function public.admin_catches_list(text,integer,text,date,integer,integer) from public, anon;
grant execute on function public.admin_catches_list(text,integer,text,date,integer,integer) to authenticated;

revoke all on function public.admin_trips_list(integer,integer) from public, anon;
grant execute on function public.admin_trips_list(integer,integer) to authenticated;

revoke all on function public.admin_overview_drilldown() from public, anon;
grant execute on function public.admin_overview_drilldown() to authenticated;
