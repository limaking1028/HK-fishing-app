-- v173 新用戶計數（主人：「做新用戶流程檢查同計數」）
-- * app_daily_counts：每日每個事件每個來源一個總數（香港日期）。冇 IP、冇位置、冇用戶 id、冇任何識別碼。
--   RLS 開、冇 policy、anon/authenticated 冇任何表權限 → 讀唔到、改唔到。
-- * track_event(p_event, p_src)：唯一寫入途徑。SECURITY DEFINER，只可以 +1；
--   事件白名單 share_open（Worker）/ share_entry（由分享連結入 App）/ new_visitor（新訪客，本機旗仔）；
--   來源白名單 fb/ig/yt/wa/threads/tg/x/other，冇標籤 = direct；每格每日上限 50000（之後唔再加）。冇回傳任何數據。
--   ⚠️ anon 可以執行 = 新 anon 權限（要主人批准）。
-- * admin_daily_counts(p_days)：只限 is_admin()。註冊同第一條魚由現有 users / catches 計（唔使 client 事件）。
begin;

create table if not exists public.app_daily_counts (
  day date not null,
  event text not null,
  src text not null,
  n integer not null default 0,
  primary key (day, event, src)
);
alter table public.app_daily_counts enable row level security;
revoke all on public.app_daily_counts from public, anon, authenticated;

create or replace function public.track_event(p_event text, p_src text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_src text := lower(coalesce(nullif(btrim(p_src), ''), 'direct'));
  v_day date := (now() at time zone 'Asia/Hong_Kong')::date;
begin
  if p_event is null or p_event not in ('share_open', 'share_entry', 'new_visitor') then return; end if;
  if v_src not in ('direct', 'fb', 'ig', 'yt', 'wa', 'threads', 'tg', 'x', 'other') then v_src := 'other'; end if;
  insert into public.app_daily_counts (day, event, src, n) values (v_day, p_event, v_src, 1)
  on conflict (day, event, src) do update set n = public.app_daily_counts.n + 1
   where public.app_daily_counts.n < 50000;
end $function$;
revoke all on function public.track_event(text, text) from public;
grant execute on function public.track_event(text, text) to anon, authenticated;

create or replace function public.admin_daily_counts(p_days integer default 30)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  v_n int := greatest(1, least(coalesce(p_days, 30), 90));
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    with d as (select generate_series(v_today - (v_n - 1), v_today, interval '1 day')::date as day),
    c as (select day, event, src, n from public.app_daily_counts where day >= v_today - (v_n - 1)),
    su as (select (u.created_at at time zone 'Asia/Hong_Kong')::date as day, count(*)::int as n
             from public.users u group by 1),
    fc as (select (x.f at time zone 'Asia/Hong_Kong')::date as day, count(*)::int as n
             from (select c2.user_id, min(c2.created_at) as f from public.catches c2
                    join public.users u on u.id = c2.user_id
                   where not c2.is_test group by c2.user_id) x group by 1)
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', d.day,
             'share_open', coalesce((select sum(n) from c where c.day = d.day and c.event = 'share_open'), 0),
             'share_entry', coalesce((select sum(n) from c where c.day = d.day and c.event = 'share_entry'), 0),
             'new_visitor', coalesce((select sum(n) from c where c.day = d.day and c.event = 'new_visitor'), 0),
             'signups', coalesce((select n from su where su.day = d.day), 0),
             'first_catches', coalesce((select n from fc where fc.day = d.day), 0),
             'by_src', coalesce((select jsonb_object_agg(c.event || ':' || c.src, c.n) from c where c.day = d.day), '{}'::jsonb))
           order by d.day desc), '[]'::jsonb)
      from d);
end $function$;
revoke all on function public.admin_daily_counts(integer) from public, anon;
grant execute on function public.admin_daily_counts(integer) to authenticated;

commit;
