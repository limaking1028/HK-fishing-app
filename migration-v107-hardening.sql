-- ============================================================
-- v107 安全加固 + 刪除帳戶   （在 Supabase → SQL Editor 執行，可重複執行）
-- ============================================================
-- 修正內容：
--  1. fishing_trips 原本沒有開 RLS（任何人可改/刪）→ 只可存取自己的行程
--  2. users 原本全公開可讀（含 email）→ 只可讀自己的資料
--  3. catches 原本全公開可讀（含 GPS）→ 只可讀自己的 + 示範資料(user_id is null)
--  4. 照片儲存：移除 anon 的寫入/刪除權限 → 只有登入用戶可操作自己資料夾 {uid}/...
--  5. 新增 delete_my_account()：App 內「永久刪除帳戶」使用（Google Play 要求）
-- ============================================================

-- ---------- 1. fishing_trips ----------
alter table fishing_trips enable row level security;
drop policy if exists "trips read own or demo" on fishing_trips;
create policy "trips read own or demo" on fishing_trips
  for select to authenticated
  using (user_id = auth.uid() or user_id is null);
drop policy if exists "trips manage own" on fishing_trips;
create policy "trips manage own" on fishing_trips
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------- 2. users ----------
drop policy if exists "users read all" on users;
drop policy if exists "users read own" on users;
create policy "users read own" on users
  for select to authenticated
  using (id = auth.uid());

-- ---------- 3. catches ----------
drop policy if exists "catches read all" on catches;
drop policy if exists "catches read own or demo" on catches;
create policy "catches read own or demo" on catches
  for select to authenticated
  using (user_id = auth.uid() or user_id is null);
-- "catches manage own"（for all, user_id = auth.uid()）已由 migration-email-magic-link.sql 建立

-- ---------- 4. Storage: catch-photos ----------
drop policy if exists "anon upload catch photos" on storage.objects;
drop policy if exists "anon update catch photos" on storage.objects;
drop policy if exists "anon delete catch photos" on storage.objects;

drop policy if exists "own upload catch photos" on storage.objects;
create policy "own upload catch photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'catch-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own update catch photos" on storage.objects;
create policy "own update catch photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'catch-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own delete catch photos" on storage.objects;
create policy "own delete catch photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'catch-photos' and (storage.foldername(name))[1] = auth.uid()::text);
-- 公開讀取：bucket 設為 public 即可（Storage → catch-photos → Public ✓）

-- ---------- 5. 刪除帳戶 ----------
-- 注意：Supabase 不允許用 SQL 直接刪 storage.objects，照片由 App 端先用 Storage API 刪除。
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
  delete from public.catches       where user_id = uid;
  delete from public.fishing_trips where user_id = uid;
  delete from public.users         where id = uid;
  delete from auth.users           where id = uid;
end;
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- 驗證 ----------
-- select tablename, policyname, cmd, roles from pg_policies
--  where schemaname in ('public','storage') order by tablename, policyname;
-- select relname, relrowsecurity from pg_class where relname in ('users','catches','fishing_trips');
