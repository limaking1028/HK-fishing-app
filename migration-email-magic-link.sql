-- ============================================================
-- 升級用戶系統:用戶名 + PIN → Email Magic Link
-- ============================================================
-- 適用場景:放棄 WhatsApp OTP(Meta Business 限制)+ 立即可用嘅方案
--
-- 工作流程(用戶視角):
--   1. 用戶輸入 email → 撳「發送登入連結」
--   2. Supabase 透過 auth.users 發送 magic link email
--   3. 用戶撳 email 入面 link → 自動登入
--   4. 第一次登入自動建立 user row + 顯示預設 display_name
--
-- 設計:
--   1. users.id = auth.users.id(改用 Supabase Auth 主鍵)
--   2. RLS 重新啟用,用 auth.uid() 做權限檢查
--   3. Trigger:auth.users 新增時自動喺 users 表加 profile row
--   4. pin_hash / pin_salt 移除(不再需要)
--   5. WhatsApp OTP 欄位保留(可日後升級)
-- ============================================================

-- ============================================================
-- 1. users 表結構:改用 auth.users.id 做 PK
-- ============================================================
-- 先創建 users 表嘅新結構(如果已存在,先 backup 資料)
do $$
declare
  has_old boolean;
begin
  select exists(select 1 from information_schema.tables where table_schema='public' and table_name='users') into has_old;
  if has_old then
    -- 保留舊 users 資料到一個 backup table(以防用戶想還原)
    execute 'create table if not exists _users_legacy_backup as select * from users';
  end if;
end $$;

-- 刪除舊 users 表(如果要重建結構)
drop table if exists users cascade;

-- 新版 users 表 — id 與 auth.users.id 同步
create table users (
  id              uuid        primary key references auth.users(id) on delete cascade,
  email           text        unique not null,
  avatar          text        default '🎣',
  display_name    text,
  phone_e164      text        unique,                  -- 預留 WhatsApp 用
  phone_verified  boolean     default false,
  created_at      timestamptz default now(),
  last_login_at   timestamptz,
  created_via     text        default 'email_magic_link'
);

create index if not exists users_email_idx on users (email);

-- ============================================================
-- 2. Trigger:auth.users 新增時自動同步到 users 表
-- ============================================================
-- 當用戶喺 auth.users 創建時(magic link first time),同步創建 users row
-- 當 auth.users email 更新時,同步更新 users.email
create or replace function public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER  -- 用 owner 權限執行
SET search_path = public, auth
as $$
declare
  email_local text;
  name_default text;
begin
  -- 提取 email local part(去除 @ 後面)
  email_local := split_part(new.email, '@', 1);
  name_default := coalesce(
    new.raw_user_meta_data->>'display_name',
    '釣友' || substr(email_local, 1, 8)
  );

  -- 同步插入 users 表(如果不存在)
  insert into public.users (id, email, avatar, display_name, last_login_at, created_via)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'avatar', '🎣'),
    name_default,
    now(),
    'email_magic_link'
  )
  on conflict (id) do update set
    email = excluded.email,
    last_login_at = excluded.last_login_at;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email on auth.users
  for each row
  execute function public.handle_new_auth_user();

-- ============================================================
-- 3. Trigger:auth.users 登入時更新 last_login_at
-- ============================================================
create or replace function public.handle_user_login()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
as $$
begin
  update public.users
  set last_login_at = now()
  where id = new.id;
  return new;
end;
$$;

-- Supabase 沒有直接 login trigger,我哋用 client 端更新
-- 但保留呢個 trigger 函數作爲 future use

-- ============================================================
-- 4. RLS 重新啟用 + 政策
-- ============================================================
-- 之前因為 PIN 自訂 auth,RLS 無法用 auth.uid()
-- 而家 Supabase Auth 支援,我哋重新開啟 RLS
alter table users enable row level security;
alter table catches enable row level security;

-- users:用戶可以讀自己 + 其他人嘅公開資料(display_name + avatar)
drop policy if exists "users read all" on users;
create policy "users read all" on users
  for select to anon, authenticated
  using (true);  -- 公開可讀(釣魚社群需要見其他釣友名)

drop policy if exists "users update self" on users;
create policy "users update self" on users
  for update to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

drop policy if exists "users insert via trigger" on users;
create policy "users insert via trigger" on users
  for insert to authenticated
  with check (auth.uid() = id);

-- catches:用戶可以管理自己的 + 全部可讀
drop policy if exists "catches read all" on catches;
create policy "catches read all" on catches
  for select to anon, authenticated
  using (true);  -- 公開可讀(社群分享)

drop policy if exists "catches manage own" on catches;
create policy "catches manage own" on catches
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================
-- 5. 刪除 WhatsApp OTP 相關係度 + 表
-- ============================================================
-- 暫時保留 otp_codes + login_attempts 表(將來可重用)
-- 如果確定唔再用 WhatsApp OTP,可以 uncomment 下面刪除

-- drop table if exists login_attempts;
-- drop table if exists otp_codes;
-- drop function if exists check_rate_limit(text, text, int, int);

-- 移除 users 表 WhatsApp 欄位(不再需要)
alter table users
  drop column if exists phone_verified_at,
  drop column if exists username,
  drop column if exists pin_hash,
  drop column if exists pin_salt;

-- ============================================================
-- 6. 兼容舊 catches.user_id(可能有舊用戶 UUID)
-- ============================================================
-- 如果舊 users table 有 row,佢哋嘅 catches 引用可能會失效
-- 我哋唔主動處理呢啲舊資料 — 客戶端會 query 時 fallback 到 demo

-- ============================================================
-- 7. 驗證
-- ============================================================
-- 預期 users 表結構:
--   id (uuid, FK auth.users.id) + email + avatar + display_name + phone_e164 + phone_verified + last_login_at + created_via + created_at

-- 預期 trigger:
--   on_auth_user_created → handle_new_auth_user

-- 預期 RLS:
--   users + catches → enabled

-- ============================================================
-- ⚠️ 重要:執行呢個 SQL 後需要做:
-- 1. Supabase Dashboard → Authentication → Users → 刪除舊嘅 demo/test auth users
-- 2. 第一次測試 magic link login
-- 3. 確認 trigger 自動建立 users row
-- ============================================================