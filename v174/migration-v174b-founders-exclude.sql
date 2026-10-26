-- v174b 創始釣友：永久剔走主人指定嘅測試帳戶（⚠️ 未套用，要主人批准）
-- 主人：「補號選 B：剔走 10月14日測試94、10月14日測試02FP、釣友testuser」
-- 冇呢個檔，嗰 3 個帳戶將來記魚仍然會攞到號（trigger 只睇 is_test）。
-- 冇停用 trigger、冇 LOCK；只係 CREATE OR REPLACE 派號函數多一行檢查。冇新 anon 權限。
begin;
create table if not exists public.founders_excluded (user_id uuid primary key, note text, created_at timestamptz not null default now());
alter table public.founders_excluded enable row level security;
revoke all on public.founders_excluded from public, anon, authenticated;
insert into public.founders_excluded (user_id, note) values
  ('aa69deb9-356b-42e8-87c5-403c0ccb1474', '10月14日測試94'),
  ('783f2018-d810-4ede-a0f1-385f9b4a2585', '10月14日測試02FP'),
  ('10c5090e-b9dd-445c-8a77-30e3cefb4fe3', '釣友testuser')
on conflict do nothing;
create or replace function public.founders_assign()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_no int; i int := 0;
begin
  if new.user_id is null or coalesce(new.is_test, false) then return new; end if;
  if exists (select 1 from public.founders where user_id = new.user_id) then return new; end if;
  if exists (select 1 from public.founders_excluded where user_id = new.user_id) then return new; end if;   -- v174b
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
commit;
