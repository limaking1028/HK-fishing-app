-- ============================================================
-- 升級用戶系統:用戶名 + PIN  →  WhatsApp OTP
-- ============================================================
-- 適用場景：現有用戶系統已運作中,要平滑過渡到 WhatsApp OTP
--
-- 設計原則：
--   1. 向後相容：保留 username + pin_hash + pin_salt(舊用戶仍可登入)
--      → 之後可加 unused.later 清理舊欄位
--   2. 新用戶透過 phone_e164 建立
--   3. OTP 本身不存明文,只存 SHA-256(phone:code) 雜湊
--   4. RLS 嚴格:otp_codes + login_attempts 只能由 Edge Function (service_role) 讀寫
--   5. 自動清理過期 OTP(5 分鐘)
-- ============================================================

-- ============================================================
-- 1. users 表:加 WhatsApp OTP 欄位
-- ============================================================
alter table users
  add column if not exists phone_e164      text unique,        -- +852XXXXXXXX 格式
  add column if not exists phone_verified  boolean default false,
  add column if not exists phone_verified_at timestamptz,
  add column if not exists last_login_at   timestamptz,
  add column if not exists created_via     text default 'legacy_pin';  -- 'legacy_pin' | 'whatsapp_otp'
  add column if not exists avatar          text default '🎣',
  add column if not exists display_name    text;

-- 索引:加速「用電話查找用戶」(登入時最常見查詢)
create index if not exists users_phone_idx on users (phone_e164) where phone_e164 is not null;

-- 範例:為舊用戶保留 username + pin 欄位,允許他們繼續以 PIN 登入
-- 客戶端 UI 改成只顯示 OTP,但若之後有人想回退到 PIN 登入仍可用

-- ============================================================
-- 2. otp_codes 表:短暫有效驗證碼
-- ============================================================
-- 每次用戶輸入電話並按「發送驗證碼」:
--   1. Edge Function 隨機生成 6 位數字
--   2. 寫入此表(已 hash)
--   3. 透過 WhatsApp Cloud API 發給用戶
--   4. 用戶輸入驗證碼後,Edge Function 查此表驗證
--   5. 驗證成功 → 標記 consumed
--
-- 過期/已消耗的碼不再能用(consumed=true 或 expires_at < now())
-- ============================================================
create table if not exists otp_codes (
  id            uuid primary key default gen_random_uuid(),
  phone_e164    text not null,
  code_hash     text not null,           -- SHA-256(phone_e164 + ':' + code)
  purpose       text not null default 'login',  -- 'login' | 'register'(預留)
  attempts      int  not null default 0,         -- 已驗證次數(防暴力破解)
  consumed      boolean not null default false,
  ip_hash       text,                              -- 來源 IP 雜湊(濫用追蹤,GDPR 友善)
  user_agent_hash text,                            -- 來源 UA 雜湊
  created_at     timestamptz not null default now(),
  expires_at    timestamptz not null               -- created_at + 5 分鐘
);

-- 索引:加速「電話 + 未消耗 + 未過期」查詢
create index if not exists otp_codes_active_idx
  on otp_codes (phone_e164, consumed, expires_at desc)
  where consumed = false;

-- 索引:清理任務掃描用
create index if not exists otp_codes_expires_idx
  on otp_codes (expires_at)
  where consumed = false;

-- ============================================================
-- 3. login_attempts 表:限流 + 濫用追蹤
-- ============================================================
-- Edge Function 在 send_otp / verify_otp 兩個動作時各寫入一筆
-- 用於:
--   - 限流(同一電話 10 分鐘內最多 5 次 send_otp)
--   - 失敗追蹤(連續失敗鎖定)
--   - 安全稽核(誰在何時嘗試登入)
-- ============================================================
create table if not exists login_attempts (
  id            uuid primary key default gen_random_uuid(),
  phone_e164    text,                         -- 失敗時可能無電話(電話格式錯)
  ip_hash       text,
  action        text not null,                -- 'send_otp' | 'verify_otp' | 'invalid_phone'
  success       boolean not null,
  reason        text,                              -- 失敗原因('expired', 'wrong_code', 'rate_limited'...)
  created_at    timestamptz not null default now()
);

create index if not exists login_attempts_phone_idx
  on login_attempts (phone_e164, action, created_at desc);
create index if not exists login_attempts_time_idx
  on login_attempts (created_at desc);

-- ============================================================
-- 4. RLS:嚴格限制
-- ============================================================
-- otp_codes + login_attempts 屬於「內部資料」,前端 anon key 絕對不可讀寫
-- 只能由 Edge Function (持有 service_role key) 操作

alter table otp_codes enable row level security;
alter table login_attempts enable row level security;

-- 拒絕所有 anon/authenticated 訪問
-- (Edge Function 用 service_role,不受 RLS 影響)
drop policy if exists "anon denied otp_codes" on otp_codes;
create policy "anon denied otp_codes" on otp_codes
  for all to anon, authenticated
  using (false) with check (false);

drop policy if exists "anon denied login_attempts" on login_attempts;
create policy "anon denied login_attempts" on login_attempts
  for all to anon, authenticated
  using (false) with check (false);

-- users 表的 RLS 仍保持關閉(沿用既有設定)
-- 因為 PIN 自訂 auth 喺 client-side 執行,本來就無法用 auth.uid()
-- 等升級到 WhatsApp OTP + Supabase Auth 後,可重新開啟 RLS
-- ============================================================

-- ============================================================
-- 5. 清理策略(可選,部署後手動或 cron 觸發)
-- ============================================================
-- 建議加 pg_cron job 每日清理:
--   delete from otp_codes where expires_at < now() - interval '1 day';
--   delete from login_attempts where created_at < now() - interval '30 days';

-- ============================================================
-- 6. 驗證 migration
-- ============================================================
-- 執行以下查詢確認成功:
--   select table_name, column_name, data_type
--   from information_schema.columns
--   where table_schema = 'public' and table_name in ('users','otp_codes','login_attempts')
--   order by table_name, ordinal_position;

-- 預期新增欄位(users):
--   phone_e164 | phone_verified | phone_verified_at | last_login_at | created_via

-- 預期新增表:
--   otp_codes      (10 columns)
--   login_attempts (7 columns)

-- 預期新增 RLS:
--   otp_codes      → enabled
--   login_attempts → enabled
-- ============================================================