-- v201：後台個人行程摘要及按需詳情。只讀，不修改 App、舊 RPC 或正式資料。
-- 需要既有行程、使用者、快速計數／照片、環境快照及重量欄位 migration。
-- admin_user_trip_summaries：個人行程摘要；逐筆魚獲和快速計數分開，不相加。
create or replace function public.admin_user_trip_summaries(p_user uuid, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.started_at desc nulls last,q.id desc) from (
    select t.id,t.user_id,t.started_at,t.ended_at,t.spot,t.spot_area,t.method,t.bait,
      case when coalesce(t.ended_at,now())>=t.started_at then extract(epoch from (coalesce(t.ended_at,now())-t.started_at))::bigint end as duration_seconds,
      (select count(*) from public.catches c where c.trip_id=t.id and c.user_id=t.user_id) as catch_count,
      (select sum(coalesce(c.weight_kg,c.weight*0.60479)) from public.catches c where c.trip_id=t.id and c.user_id=t.user_id) as total_weight_kg,
      (select sum(q.qty) from public.trip_tallies q where q.trip_id=t.id and q.user_id=t.user_id) as tally_qty
    from public.fishing_trips t where t.user_id=p_user
      and not exists(select 1 from public.founders_excluded fx where fx.user_id=t.user_id)
    order by t.started_at desc nulls last,t.id desc
    limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
  ) q),'[]'::jsonb);
end $$;

-- admin_trip_detail：限定用戶和行程，分頁讀魚獲，並讀取計數、相片及白名單環境欄位。
-- 不回傳 GPS、備註或完整環境 JSON。舊重量（斤）依 App 規則換算公斤。
create or replace function public.admin_trip_detail(p_user uuid, p_trip uuid, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.fishing_trips%rowtype;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into t from public.fishing_trips x where x.id=p_trip and x.user_id=p_user
    and not exists(select 1 from public.founders_excluded fx where fx.user_id=x.user_id);
  if not found then raise exception 'trip not found'; end if;
  return jsonb_build_object(
    'id',t.id,'user_id',t.user_id,
    'catches_total',(select count(*) from public.catches c where c.trip_id=t.id and c.user_id=t.user_id),
    'catches',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc nulls last,q.id desc) from (
      select c.id,c.created_at,c.date,c.time,c.species,coalesce(c.weight_kg,c.weight*0.60479) as weight_kg,
        c.photo_url,c.leaderboard_eligible as eligible,c.ineligible_reason as reason,c.admin_excluded as excluded
      from public.catches c where c.trip_id=t.id and c.user_id=t.user_id
      order by c.created_at desc nulls last,c.id desc
      limit least(greatest(coalesce(p_limit,50),1),50) offset greatest(coalesce(p_offset,0),0)
    ) q),'[]'::jsonb),
    'tallies',coalesce((select jsonb_agg(jsonb_build_object('species',q.species,'qty',q.qty,'photos',q.photos) order by q.species)
      from public.trip_tallies q where q.trip_id=t.id and q.user_id=t.user_id),'[]'::jsonb),
    'haul_photos',coalesce(to_jsonb(t.haul_photos),'[]'::jsonb),
    'conditions',(select jsonb_object_agg(s.phase,case when s.snap is null then null else jsonb_build_object(
      'weather',(select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) from jsonb_each(case when jsonb_typeof(s.snap->'weather')='object' then s.snap->'weather' else '{}'::jsonb end) e where e.key=any(array['source','airTempC','humidityPct','precipitationMm','windSpeedKmh','windDirDeg','pressureHpa','cloudCoverPct']) and jsonb_typeof(e.value) in ('string','number','boolean','null')),
      'moon',(select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) from jsonb_each(case when jsonb_typeof(s.snap->'moon')='object' then s.snap->'moon' else '{}'::jsonb end) e where e.key=any(array['phaseName','illuminationPct','moonAgeDays']) and jsonb_typeof(e.value) in ('string','number','boolean','null')),
      'sun',(select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) from jsonb_each(case when jsonb_typeof(s.snap->'sun')='object' then s.snap->'sun' else '{}'::jsonb end) e where e.key=any(array['sunrise','sunset','phaseOfDay']) and jsonb_typeof(e.value) in ('string','number','boolean','null')),
      'tide',(select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) from jsonb_each(case when jsonb_typeof(s.snap->'tide')='object' then s.snap->'tide' else '{}'::jsonb end) e where e.key=any(array['station','heightM','trend','tidalRangeM','tideType','hoursToNextHigh','hoursToNextLow']) and jsonb_typeof(e.value) in ('string','number','boolean','null'))
    ) end) from (values ('start',t.start_conditions),('end',case when t.ended_at is null then null else t.end_conditions end)) s(phase,snap))
  );
end $$;

revoke all on function public.admin_user_trip_summaries(uuid,integer,integer) from public, anon;
grant execute on function public.admin_user_trip_summaries(uuid,integer,integer) to authenticated;
revoke all on function public.admin_trip_detail(uuid,uuid,integer,integer) from public, anon;
grant execute on function public.admin_trip_detail(uuid,uuid,integer,integer) to authenticated;
