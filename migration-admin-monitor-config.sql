-- ============================================================
-- 管理後台第三期：測試進度 + 公告橫幅 + 客戶端錯誤紀錄
--
--   1. admin_tester_progress(p_start)      近期 App 活躍連續日數（Play 封閉測試 14 日進度）
--   2. app_config 表 + get_announcement()  公告橫幅（所有用戶可讀；未登入都可以）
--      admin_set_announcement(...)         管理員開關／修改公告，寫入操作記錄
--   3. client_errors 表 + log_client_error()  App 客戶端錯誤（限流，30 日自動清理）
--      admin_client_errors(p_days)         按錯誤訊息分組顯示
--
-- 需要先執行 v112（is_admin／admin_log）、v120（app_usage）。
-- 可重複執行。
-- ============================================================

-- ===== 1. 測試進度（App 活躍連續日數）=====
create or replace function public.admin_tester_progress(p_start date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  hk_today date := (now() at time zone 'Asia/Hong_Kong')::date;
  s date := coalesce(p_start, (now() at time zone 'Asia/Hong_Kong')::date - 13);
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    with days as (
      select distinct user_id, day from public.app_usage
       where day >= s and day <= hk_today and seconds > 0
    ),
    grp as (
      -- 連續日數：日期減去行號，同一組即係連續
      select user_id, day, day - (row_number() over (partition by user_id order by day))::int as g from days
    ),
    streaks as (
      select user_id, count(*) as streak, max(day) as streak_end from grp group by user_id, g
    ),
    best as (
      select user_id, max(streak) as best_streak, max(streak_end) as last_day from streaks group by user_id
    ),
    totals as (
      select user_id, count(*) as active_days from days group by user_id
    )
    select jsonb_build_object(
      'start',        s,
      'today',        hk_today,
      'days_elapsed', hk_today - s + 1,
      'qualified',    (select count(*) from best where best_streak >= 14),
      'users', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', b.user_id,
                 'display_name', coalesce(p.display_name, split_part(a.email, '@', 1)),
                 'email', a.email,
                 'best_streak', b.best_streak,
                 'active_days', t.active_days,
                 'last_day', b.last_day)
               order by b.best_streak desc, t.active_days desc)
          from best b
          join totals t using (user_id)
          left join public.users p on p.id = b.user_id
          left join auth.users a on a.id = b.user_id
      ), '[]'::jsonb)
    )
  );
end $$;

-- ===== 2. 公告橫幅 =====
create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.app_config enable row level security;   -- 無 policy：只經函數存取
revoke all on public.app_config from anon, authenticated;

insert into public.app_config (key, value) values ('announcement', '{"enabled": false}')
on conflict (key) do nothing;

-- 公開函數：返回有效公告，無則返回 null。id 用更新時間，用戶關閉後，新公告會再次顯示
create or replace function public.get_announcement()
returns jsonb language sql stable security definer set search_path = public as $$
  select case
           when (value->>'enabled')::boolean is true
            and (value->>'until' is null or (value->>'until')::timestamptz > now())
           then jsonb_build_object(
                  'id',      extract(epoch from updated_at)::bigint,
                  'message', coalesce(value->>'message', ''),
                  'level',   coalesce(value->>'level', 'info'))
           else null
         end
    from public.app_config
   where key = 'announcement';
$$;

create or replace function public.admin_set_announcement(
  p_enabled boolean,
  p_message text default null,
  p_level   text default 'info',
  p_until   timestamptz default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare msg text := left(btrim(coalesce(p_message, '')), 200);
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_level not in ('info', 'warn', 'bad') then raise exception 'invalid_level'; end if;
  if coalesce(p_enabled, false) and msg = '' then raise exception 'message_required'; end if;

  update public.app_config
     set value = jsonb_build_object('enabled', coalesce(p_enabled, false), 'message', msg,
                                    'level', p_level, 'until', p_until),
         updated_at = now()
   where key = 'announcement';

  perform public.admin_log(
    case when coalesce(p_enabled, false) then 'announcement_on' else 'announcement_off' end,
    'config', 'announcement',
    jsonb_build_object('message', msg, 'level', p_level, 'until', p_until));

  return (select value from public.app_config where key = 'announcement');
end $$;

create or replace function public.admin_get_announcement()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (select value from public.app_config where key = 'announcement');
end $$;

-- ===== 3. 客戶端錯誤紀錄 =====
create table if not exists public.client_errors (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid,
  app_version text,
  message     text not null,
  stack       text,
  source      text,
  url         text
);
alter table public.client_errors enable row level security;   -- 無 policy：只經函數寫入（管理員讀取）
revoke all on public.client_errors from anon, authenticated;
create index if not exists client_errors_created_idx on public.client_errors (created_at desc);

-- App 內以 anon 或 authenticated 身份呼叫；全局限流：每分鐘最多 200 條
create or replace function public.log_client_error(
  p_message text,
  p_stack   text default null,
  p_source  text default null,
  p_version text default null,
  p_url     text default null
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_message is null or btrim(p_message) = '' then return; end if;
  if (select count(*) from public.client_errors where created_at > now() - interval '1 minute') >= 200 then
    return;
  end if;
  insert into public.client_errors (user_id, app_version, message, stack, source, url)
  values (auth.uid(), left(p_version, 20), left(p_message, 500), left(p_stack, 2000),
          left(p_source, 60), left(p_url, 200));
  if random() < 0.01 then   -- 約每 100 次寫入清理一次，保留 30 日
    delete from public.client_errors where created_at < now() - interval '30 days';
  end if;
end $$;

create or replace function public.admin_client_errors(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'message', q.message, 'count', q.n, 'users', q.users,
             'versions', q.versions, 'last_at', q.last_at,
             'source', q.source, 'sample_stack', q.sample_stack)
           order by q.n desc)
      from (
        select left(message, 200) as message,
               count(*) as n,
               count(distinct user_id) as users,
               array_agg(distinct app_version) filter (where app_version is not null) as versions,
               max(created_at) as last_at,
               min(source) as source,
               min(stack) as sample_stack
          from public.client_errors
         where created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 30)))
         group by left(message, 200)
      ) q
  ), '[]'::jsonb);
end $$;

-- ===== 權限 =====
-- 公開：公告讀取、錯誤回報（未登入都可能出錯）
grant execute on function public.get_announcement() to anon, authenticated;
grant execute on function public.log_client_error(text, text, text, text, text) to anon, authenticated;

-- 管理員專用
do $$
declare f text;
begin
  foreach f in array array[
    'admin_tester_progress(date)',
    'admin_set_announcement(boolean,text,text,timestamptz)',
    'admin_get_announcement()',
    'admin_client_errors(integer)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
