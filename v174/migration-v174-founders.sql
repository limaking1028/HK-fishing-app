-- v174 創始釣友（主人：「做創始釣友開幕活動」）
-- 頭 100 個記錄第一條（非測試）魚獲嘅帳戶，永久得到「創始釣友 #N」。
-- * founders：RLS 開、冇 policy、anon/authenticated 冇表權限 → 用戶改唔到、刪唔到。一個帳戶一個號（user_id PK），號碼唯一 1..100。
--   冇 FK：帳戶刪除後號碼都唔會再派（永久）。
-- * catches AFTER INSERT trigger 派號：唔停用任何 trigger、唔用 LOCK TABLE；用 max+1 + unique_violation 重試。
--   派號出錯都唔會令記錄魚獲失敗（exception 食咗）。
-- * founder_remaining()：剩幾多名額（一個數字）。⚠️ anon 可以執行 = 新 anon 權限（要主人批准），俾登入前嘅開幕橫幅用。
-- * my_founder_no()：自己嘅號（authenticated）。
-- * lb_founder_nos(uuid[])：排行榜 id（catch_id 或 public_id）→ 號碼（authenticated，最多 200 個）。
-- 舊帳戶點派號（補號）係另一個檔 v174/seed-v174-options.sql，主人揀咗先用。
begin;

create table if not exists public.founders (
  user_id uuid primary key,
  no integer not null unique check (no between 1 and 100),
  first_catch_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.founders enable row level security;
revoke all on public.founders from public, anon, authenticated;

create or replace function public.founders_assign()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_no int; i int := 0;
begin
  if new.user_id is null or coalesce(new.is_test, false) then return new; end if;
  if exists (select 1 from public.founders where user_id = new.user_id) then return new; end if;
  if not exists (select 1 from public.users where id = new.user_id) then return new; end if;
  loop
    i := i + 1;
    select coalesce(max(no), 0) + 1 into v_no from public.founders;
    if v_no > 100 then return new; end if;
    begin
      insert into public.founders (user_id, no, first_catch_at) values (new.user_id, v_no, coalesce(new.created_at, now()));
      return new;
    exception when unique_violation then
      if exists (select 1 from public.founders where user_id = new.user_id) or i >= 10 then return new; end if;
    end;
  end loop;
exception when others then
  return new;   -- 派號失敗都唔阻記錄魚獲
end $function$;
revoke all on function public.founders_assign() from public, anon, authenticated;

drop trigger if exists trg_founders_assign on public.catches;
create trigger trg_founders_assign after insert on public.catches
  for each row execute function public.founders_assign();

create or replace function public.founder_remaining()
 returns integer language sql stable security definer set search_path to 'public'
as $function$ select greatest(0, 100 - (select count(*)::int from public.founders)) $function$;
revoke all on function public.founder_remaining() from public;
grant execute on function public.founder_remaining() to anon, authenticated;

create or replace function public.my_founder_no()
 returns integer language sql stable security definer set search_path to 'public'
as $function$ select no from public.founders where user_id = auth.uid() $function$;
revoke all on function public.my_founder_no() from public, anon;
grant execute on function public.my_founder_no() to authenticated;

create or replace function public.lb_founder_nos(p_ids uuid[])
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with ids as (select distinct x from unnest(p_ids[1:200]) x where x is not null)
  select coalesce(jsonb_object_agg(k, no), '{}'::jsonb) from (
    select c.id::text as k, f.no from ids join public.catches c on c.id = ids.x join public.founders f on f.user_id = c.user_id
    union
    select u.public_id::text, f.no from ids join public.users u on u.public_id = ids.x join public.founders f on f.user_id = u.id
  ) t
$function$;
revoke all on function public.lb_founder_nos(uuid[]) from public, anon;
grant execute on function public.lb_founder_nos(uuid[]) to authenticated;

commit;
