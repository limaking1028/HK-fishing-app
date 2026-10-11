-- ============================================================
-- v120：後台第二期 —— 使用時間統計 + 熱門魚種／釣點
--
--   * app_usage：每位用戶、每日、每個鐘頭嘅「前景使用秒數」（只記時間，唔記做咗乜）
--   * track_usage(p_seconds)：App 每約 60 秒回報一次（只可寫自己，每次上限 120 秒）
--   * admin_usage()：每日活躍人數／總分鐘、平均每人、時段分佈、前 10 名用戶（近 7 日）
--   * admin_trends()：近 30 日熱門魚種、熱門釣點、每週魚獲趨勢
--
-- 可重複執行。需要先執行 v112。
-- ============================================================

create table if not exists public.app_usage (
  user_id uuid not null,
  day     date not null,
  hour    smallint not null check (hour between 0 and 23),
  seconds integer not null default 0 check (seconds >= 0),
  primary key (user_id, day, hour)
);
alter table public.app_usage enable row level security;   -- 無 policy：只經函數存取
revoke all on public.app_usage from anon, authenticated;
create index if not exists app_usage_day_idx on public.app_usage (day);

create or replace function public.track_usage(p_seconds integer)
returns void language plpgsql security definer set search_path = public as $$
declare hk timestamp := now() at time zone 'Asia/Hong_Kong'; s integer;
begin
  if auth.uid() is null then return; end if;
  s := least(greatest(coalesce(p_seconds, 0), 0), 120);   -- 單次上限 120 秒，防止亂報
  if s = 0 then return; end if;
  insert into public.app_usage (user_id, day, hour, seconds)
  values (auth.uid(), hk::date, extract(hour from hk)::smallint, s)
  on conflict (user_id, day, hour)
  do update set seconds = least(public.app_usage.seconds + s, 3600);   -- 每個鐘頭最多 3600 秒
  if random() < 0.01 then   -- 順便清走超過 12 個月嘅記錄（私隱政策保留期）
    delete from public.app_usage where day < (hk::date - 365);
  end if;
end $$;
revoke all on function public.track_usage(integer) from public, anon;
grant execute on function public.track_usage(integer) to authenticated;

create or replace function public.admin_usage()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Hong_Kong')::date; r jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'tracking_since', (select min(day) from public.app_usage),
    'dau_today',  (select count(distinct user_id) from public.app_usage where day = today),
    'wau',        (select count(distinct user_id) from public.app_usage where day > today - 7),
    'mau',        (select count(distinct user_id) from public.app_usage where day > today - 30),
    'avg_min_per_active_7d', (select coalesce(round(sum(seconds) / 60.0 / nullif(count(distinct user_id), 0), 1), 0)
                                from public.app_usage where day > today - 7),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'u', u, 'min', m) order by d)
               from (select day d, count(distinct user_id) u, round(sum(seconds) / 60.0, 1) m
                       from public.app_usage where day > today - 14 group by day) q), '[]'::jsonb),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('h', h, 'min', m) order by h)
               from (select hour h, round(sum(seconds) / 60.0, 1) m
                       from public.app_usage where day > today - 30 group by hour) q), '[]'::jsonb),
    'top_users', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'display_name', dn, 'min', m, 'days', dd) order by m desc)
               from (select u.user_id id, coalesce(p.display_name, split_part(a.email, '@', 1)) dn,
                            round(sum(u.seconds) / 60.0, 1) m, count(distinct u.day) dd
                       from public.app_usage u
                       left join auth.users a on a.id = u.user_id
                       left join public.users p on p.id = u.user_id
                      where u.day > today - 7
                      group by u.user_id, 2 order by m desc limit 10) q), '[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.admin_trends()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'species', coalesce((select jsonb_agg(jsonb_build_object('name', species, 'n', n, 'u', u) order by n desc)
                from (select species, count(*) n, count(distinct user_id) u from public.catches
                       where user_id is not null and species is not null and created_at > now() - interval '30 days'
                       group by species order by n desc limit 10) q), '[]'::jsonb),
    'spots', coalesce((select jsonb_agg(jsonb_build_object('name', spot, 'n', n, 'u', u) order by n desc)
                from (select spot, count(*) n, count(distinct user_id) u from public.catches
                       where user_id is not null and spot is not null and spot <> '' and created_at > now() - interval '30 days'
                       group by spot order by n desc limit 10) q), '[]'::jsonb),
    'weekly', coalesce((select jsonb_agg(jsonb_build_object('w', w, 'n', n) order by w)
                from (select date_trunc('week', created_at at time zone 'Asia/Hong_Kong')::date w, count(*) n
                        from public.catches where user_id is not null and created_at > now() - interval '8 weeks'
                        group by 1) q), '[]'::jsonb)
  );
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_usage()','admin_trends()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 刪除帳戶時一併刪除使用時間記錄（沿用 v107 嘅邏輯，加多一行）
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  delete from public.app_usage     where user_id = uid;
  delete from public.catches       where user_id = uid;
  delete from public.fishing_trips where user_id = uid;
  delete from public.users         where id = uid;
  delete from auth.users           where id = uid;
end;
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
