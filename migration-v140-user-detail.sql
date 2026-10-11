-- ============================================================
-- v140：後台「單一用戶全部紀錄」
--   admin_user_detail(p_user)：返回該用戶嘅帳戶資料、登入方式（有冇密碼）、魚獲、行程、
--   快速計數、近 30 日使用時間、意見回饋、相關管理操作記錄。
--   只有管理員可用（SECURITY DEFINER + is_admin()）。唔回傳座標同備註內容。
-- 可重複執行。需要先執行 v112、v120、v124、v139。
-- ============================================================
create or replace function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'user not found'; end if;
  select jsonb_build_object(
    'profile', (select jsonb_build_object(
        'id', a.id, 'email', a.email, 'display_name', u.display_name,
        'created_at', a.created_at, 'last_sign_in_at', a.last_sign_in_at,
        'banned', (a.banned_until is not null and a.banned_until > now()),
        'is_admin', exists (select 1 from public.admins ad where ad.user_id = a.id),
        'has_password', (a.encrypted_password is not null and a.encrypted_password <> ''),
        'providers', coalesce((select jsonb_agg(i.provider order by i.provider) from auth.identities i where i.user_id = a.id), '[]'::jsonb))
      from auth.users a left join public.users u on u.id = a.id where a.id = p_user),
    'totals', jsonb_build_object(
        'catches', (select count(*) from public.catches c where c.user_id = p_user),
        'eligible', (select count(*) from public.catches c where c.user_id = p_user and c.leaderboard_eligible),
        'excluded', (select count(*) from public.catches c where c.user_id = p_user and c.admin_excluded),
        'with_photo', (select count(*) from public.catches c where c.user_id = p_user and c.photo_url is not null and c.photo_url <> ''),
        'trips', (select count(*) from public.fishing_trips t where t.user_id = p_user),
        'tally_qty', (select coalesce(sum(qty), 0) from public.trip_tallies q where q.user_id = p_user),
        'usage_min_30d', (select coalesce(sum(seconds), 0) / 60 from public.app_usage x where x.user_id = p_user and x.day >= (now() at time zone 'Asia/Hong_Kong')::date - 29),
        'active_days_30d', (select count(distinct day) from public.app_usage x where x.user_id = p_user and x.day >= (now() at time zone 'Asia/Hong_Kong')::date - 29)),
    'catches', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
        select jsonb_build_object('id', c.id, 'species', c.species, 'weight_kg', c.weight_kg, 'spot', c.spot,
                 'date', c.date, 'time', c.time, 'method', c.method, 'photo_url', c.photo_url,
                 'eligible', c.leaderboard_eligible, 'reason', c.ineligible_reason, 'excluded', c.admin_excluded,
                 'trip_id', c.trip_id, 'created_at', c.created_at) x
          from public.catches c where c.user_id = p_user order by c.created_at desc limit 100) z), '[]'::jsonb),
    'trips', coalesce((select jsonb_agg(x order by (x->>'started_at') desc) from (
        select jsonb_build_object('id', t.id, 'spot', t.spot, 'started_at', t.started_at, 'ended_at', t.ended_at,
                 'catch_count', t.catch_count, 'total_weight_kg', t.total_weight_kg,
                 'haul_photos', coalesce(t.haul_photos, '{}'::text[]),
                 'tally', coalesce((select jsonb_object_agg(q.species, q.qty) from public.trip_tallies q where q.trip_id = t.id), '{}'::jsonb)) x
          from public.fishing_trips t where t.user_id = p_user order by t.started_at desc limit 50) z), '[]'::jsonb),
    'usage_daily', coalesce((select jsonb_agg(x order by (x->>'day')) from (
        select jsonb_build_object('day', day, 'min', round(sum(seconds) / 60.0, 1)) x
          from public.app_usage where user_id = p_user and day >= (now() at time zone 'Asia/Hong_Kong')::date - 29 group by day) z), '[]'::jsonb),
    'feedback', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
        select jsonb_build_object('id', f.id, 'category', f.category, 'message', f.message, 'status', f.status, 'created_at', f.created_at) x
          from public.feedback f where f.user_id = p_user order by f.created_at desc limit 20) z), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
        select jsonb_build_object('action', l.action, 'admin_email', l.admin_email, 'detail', l.detail, 'created_at', l.created_at) x
          from public.admin_audit l
         where l.target_id = p_user::text
            or (l.target_type = 'catch' and l.target_id in (select c.id::text from public.catches c where c.user_id = p_user))
         order by l.created_at desc limit 30) z), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
