# 香港釣魚數據平台 - Supabase 部署指南

## 📋 部署 Checklist

- [ ] 1. 建立 Supabase 專案
- [ ] 2. 執行 schema SQL
- [ ] 3. 填入 index.html 嘅 SB_URL / SB_KEY
- [ ] 4. 部署 PWA（GitHub Pages / Netlify / Vercel）
- [ ] 5. 首次登入測試
- [ ] 6. 確認本地歷史記錄自動遷移

---

## Step 1：建立 Supabase 專案

1. 去 https://supabase.com 註冊
2. 點 **New Project** → 選 Region（建議 **Singapore** 離香港最近）
3. 設定 Database Password（記低佢！）
4. 等 1-2 分鐘建立完成

---

## Step 2：執行 Schema SQL

1. 喺 Supabase 後台 → 左邊 **SQL Editor**
2. 點 **New query**
3. 複製 `supabase-schema.sql` 全部內容貼上去
4. 點 **Run** ▶️
5. 應該見到 `Success. No rows returned`

驗證：去 **Table Editor** 應該見到 `users` 同 `catches` 兩張表。

---

## Step 3：取得 API 憑證

1. 喺 Supabase 後台 → **Settings** (左下角齒輪) → **API**
2. 複製以下兩個值：
   - **Project URL**（e.g. `https://abcdefgh.supabase.co`）
   - **anon public key**（e.g. `eyJhbGciOiJIUzI1NiIs...`）

3. 打開 `index.html`，搵到最開頭：

```js
const SB_URL  = '';   // ← 貼上 Project URL
const SB_KEY  = '';   // ← 貼上 anon key
```

⚠️ **重要**：呢兩個值係「公開」嘅（喺 frontend 會見到），但因為 RLS 暫時關閉，用戶**唔應該**用同一組 key 做 admin 操作。anon key 只可以執行已限制嘅 SQL。

---

## Step 4：部署 PWA

### 方案 A：GitHub Pages（推薦）

```bash
cd /workspace/hk-fishing-app
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/hk-fishing-app.git
git push -u origin main
```

然後喺 GitHub Repo → Settings → Pages → Source = `main` branch → Save。

幾分鐘後就會喺 `https://YOUR_USERNAME.github.io/hk-fishing-app/` 訪問到。

### 方案 B：Netlify Drop

去 https://app.netlify.com/drop 直接拖入 `/workspace/hk-fishing-app/` 資料夾。30 秒搞掂。

### 方案 C：Vercel

```bash
npm i -g vercel
cd /workspace/hk-fishing-app
vercel
```

---

## Step 5：首次登入測試

1. 開 PWA → 自動顯示登入畫面
2. 點 **註冊** → 輸入 username（2-12 字）+ 4 位 PIN
3. 成功後會自動：
   - 喺 Supabase `users` 表 insert 一條用戶記錄
   - Seed 26 條 demo 數據（`user_id = NULL`）
   - 跳到主畫面，可以正常記錄魚獲
4. 試下喺另一個 browser / 裝置 login 同一個 username + PIN → 應該見到自己嘅魚獲

---

## Step 6：本地歷史記錄遷移

如果你之前用 localStorage 用咗一段時間，會累積咗自己嘅舊記錄。Migration 機制：

- **首次登入**時，app 自動掃描 `localStorage.hk_fishing_catches_v5`
- 所有 `user === 當前 username` 嘅記錄會 insert 到 Supabase
- 原本 local 數據會 backup 到 `hk_fishing_catches_v5_backup`
- 之後用 localStorage 嘅本地 cache 仍然會保留（但寫入會被忽略）

**驗證**：登入後去 Supabase → Table Editor → catches 表，應該見到自己嘅 catch 全部都已經有 `user_id`。

---

## 🔒 安全性提醒

### 現時狀態（PIN 自訂 auth）
- RLS **已關閉**，所有用戶可以讀寫所有 catch
- App code 自己做權限檢查（`user_id === state.user.id` 才可改自己嘅 catch）
- 適合：釣友圈子 / 私人 project
- 不適合：公開服務

### 生產升級建議（5 分鐘搞掂）

1. **改用 Supabase Auth**：
   - 喺 Supabase → Authentication → Providers 啟用 Email
   - 改用 `supabase.auth.signInWithOtp({ email })` magic link
   - 用戶唔需要記 PIN，安全性大幅提升

2. **重新啟用 RLS**：
   ```sql
   alter table users enable row level security;
   alter table catches enable row level security;

   create policy "users read all" on users for select using (true);
   create policy "users insert self" on users for insert with check (id = auth.uid());
   create policy "catches read all" on catches for select using (true);
   create policy "catches manage own" on catches
     for all using (user_id = auth.uid());
   ```

3. **移除 anon key** → 用 Supabase 自己管理 session

---

## 🐛 常見問題

### Q: 登入後見不到自己嘅魚獲？
A: 檢查 Supabase → catches 表，`user_id` 欄位有冇填。用戶名輸入錯可能會 register 咗新用戶。

### Q: 報 "Cloud not enabled"？
A: `SB_URL` 同 `SB_KEY` 冇填，或者填咗 placeholder 值。檢查 `SB_ENABLED` 應該係 `true`。

### Q: 想重置資料庫？
A: 喺 Supabase → SQL Editor 執行：
```sql
truncate table catches;
truncate table users;
```
⚠️ 會刪除所有 demo + user 數據！

### Q: 想加多個用戶？
A: 直接用另一個 username + PIN 註冊就得。

### Q: Photo 點處理？
A: 現時 14 張魚種照片放喺 `photos/` 資料夾（跟 PWA 一起部署），唔需要上 Supabase Storage。

---

## 📊 預期 Supabase 用量

| 項目 | 預估 |
|---|---|
| 用戶 | 10–100 人 |
| 每人每年 catch | ~50 條 |
| 總 catches | ~500–5000 條 |
| Storage（DB） | < 5 MB |
| 月費用 | **$0**（Free tier 500 MB） |

完全 free tier 內可以撐好耐。

---

## 🆘 需要幫手？

部署過程有問題可以問我。常見問題：
- 填錯 SB_URL/SB_KEY
- RLS 想啟用但 auth 未改
- 想加新功能（相簿、社交、私訊⋯）