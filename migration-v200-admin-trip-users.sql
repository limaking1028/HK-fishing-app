-- 行程頁按用戶瀏覽。只建立只讀 RPC，不修改既有 admin_trips_list。
-- admin_trip_users：按用戶 ID 彙總行程數、進行中數量及最近行程，先搜尋再分頁。
create or replace function public.admin_trip_users(
  p_search text default null, p_limit integer default 50, p_offset integer default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.last_trip_at desc nulls last, q.user_id) from (
    select t.user_id, u.display_name, count(*) as trip_count,
      count(*) filter (where t.ended_at is null) as open_count, max(t.started_at) as last_trip_at
    from public.fishing_trips t left join public.users u on u.id=t.user_id
    where t.user_id is not null
      and not exists(select 1 from public.founders_excluded fx where fx.user_id=t.user_id)
      and (nullif(btrim(p_search),'') is null or coalesce(nullif(u.display_name,''),'未命名用戶') ilike '%' || btrim(p_search) || '%')
    group by t.user_id, u.display_name
    order by max(t.started_at) desc nulls last, t.user_id
    limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
  ) q),'[]'::jsonb);
end $$;

-- admin_user_trips：只讀取選定用戶的行程，每次最多 50 筆，使用固定次序分頁。
create or replace function public.admin_user_trips(
  p_user uuid, p_limit integer default 50, p_offset integer default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.started_at desc nulls last, q.id desc) from (
    select t.id, t.user_id, t.started_at, t.ended_at,
      (select count(*) from public.catches c where c.trip_id=t.id) as catch_count
    from public.fishing_trips t
    where t.user_id=p_user
      and not exists(select 1 from public.founders_excluded fx where fx.user_id=t.user_id)
    order by t.started_at desc nulls last, t.id desc
    limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
  ) q),'[]'::jsonb);
end $$;

revoke all on function public.admin_trip_users(text,integer,integer) from public, anon;
grant execute on function public.admin_trip_users(text,integer,integer) to authenticated;
revoke all on function public.admin_user_trips(uuid,integer,integer) from public, anon;
grant execute on function public.admin_user_trips(uuid,integer,integer) to authenticated;
