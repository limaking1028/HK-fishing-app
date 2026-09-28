-- ============================================================
-- 香港釣魚數據平台 - Supabase Schema
-- ============================================================
-- 在 Supabase 專案 → SQL Editor → New query 貼上並執行
-- ============================================================

-- 清空舊資料（如果重來）
-- drop table if exists catches cascade;
-- drop table if exists users cascade;

-- ============================================================
-- 1. users table：用戶資料
-- ============================================================
create table if not exists users (
  id          uuid primary key default gen_random_uuid(),
  username    text unique not null,           -- 登入名稱（唯一）
  pin_hash    text not null,                  -- PBKDF2 base64 雜湊（client-side hashed）
  pin_salt    text not null,                  -- 鹽值（避免 rainbow table）
  avatar      text default '🎣',
  display_name text,
  created_at  timestamptz default now()
);

-- ============================================================
-- 2. catches table：釣魚記錄
-- ============================================================
create table if not exists catches (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references users(id) on delete cascade,  -- NULL = demo 示範數據
  species       text not null,                                -- 魚種名稱
  species_icon  text default '🐟',
  weight        numeric(5,2) not null check (weight > 0 and weight < 100),     -- 重量（斤），約束 0<w<100
  length        numeric(5,1),                                 -- 長度（cm），可選
  spot          text not null,                                -- 釣點（含備註）
  spot_area     text,                                         -- 地區（可空）
  date          date not null,
  time          time,
  method        text not null,                                -- 釣法
  bait          text not null,                                -- 釣餌
  verified      boolean default false,
  notes         text,
  created_at    timestamptz default now()
);

-- ============================================================
-- 3. Indexes for common queries
-- ============================================================
create index if not exists catches_user_id_idx on catches(user_id);
create index if not exists catches_species_idx on catches(species);
create index if not exists catches_date_idx on catches(date desc);
create index if not exists catches_weight_idx on catches(weight desc);
create index if not exists catches_spot_idx on catches(spot);

-- ============================================================
-- 4. Row Level Security (RLS)
-- ============================================================
-- 因為 PIN 自訂 auth 喺 client-side 執行，RLS 無法直接用 auth.uid()
-- 暫時關閉 RLS，由 app code 做權限檢查（user_id === currentUser.id）
--
-- ⚠️ Production 升級建議：
--   - 改用 Supabase Auth（email magic link）
--   - 重新開啟 RLS
--   - 啟用以下 policies：
--     create policy "users can insert themselves" on users
--       for insert with check (id = auth.uid());
--     create policy "users manage own catches" on catches
--       for all using (user_id = auth.uid());
-- ============================================================
alter table users disable row level security;
alter table catches disable row level security;

-- ============================================================
-- 5. 系統用戶（demo seed 嘅「範例」用戶）
-- ============================================================
-- 26 條示範數據會用 user_id = NULL 表示「示範」
-- 等用戶第一次登入時，自動匯入自己嘅真實記錄
-- ============================================================

-- ============================================================
-- 6. Demo seed data（可選：第一次 deploy 時執行）
-- ============================================================
-- 如果你想 Supabase 入面已經有示範數據，可以 uncomment 下面 INSERT
-- （NOTE: 用戶第一次登入時，app 會自動檢測並寫入示範數據，
--  所以 seed 可以省略，app 端處理）
-- ============================================================

-- ============================================================
-- 7. 驗證 schema
-- ============================================================
-- 執行以下 query 確認成功：
--   select table_name, column_name, data_type
--   from information_schema.columns
--   where table_schema = 'public'
--   order by table_name, ordinal_position;
-- 應該見到 users（10 columns）+ catches（14 columns）
-- ============================================================