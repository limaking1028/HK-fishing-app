# Email Magic Link 設定指南

> **給開發者(Limaking):** 由零開始設定 Supabase Email Magic Link,完全免費,即刻可用。

---

## 為何揀 Email Magic Link 而唔係 WhatsApp OTP?

| 方案 | 上架時間 | 成本 | 維護 |
|------|------|------|------|
| ~~WhatsApp OTP~~ | ❌ Meta 限制:免費 test number 無法 create template | $0-15/1000 條 | 需管理 template 審批 |
| **Email Magic Link** | ✅ 即刻可用 | **完全免費** | Supabase 自動處理 |
| SMS OTP | 3 日 | HK$0.5-1/條 | SMS gateway 設定 |
| Username + PIN | 已試 | $0 | 已被用戶嫌麻煩 |

**結論:** Email Magic Link 最快 + 最平 + 最簡單。Supabase 內建,每月 50,000 用戶免費額。

---

## Step 1:啟用 Supabase Email Auth(已做 ✅)

喺 Supabase Dashboard → Authentication → Providers → Email → 確保:
- ✅ Email toggle ON
- ❌ Confirm email toggle OFF(用戶唔需要確認,直接 magic link 登入)
- ❌ Secure email change OFF

---

## Step 2:設定 Site URL(手機做,5 分鐘)

### 2.1 去 Authentication → URL Configuration

喺 Supabase Dashboard → Authentication → **URL Configuration**

### 2.2 設定 Site URL

填入:

```
https://limaking1028.github.io/HK-fishing-app/
```

(呢個係用戶撳 email link 之後會被帶去嘅 URL)

### 2.3 加入 Redirect URLs

加入以下 URL 到「Redirect URLs」(可加多個):

```
https://limaking1028.github.io/HK-fishing-app/
http://localhost:8080/         # 本地測試用
http://localhost:5500/         # VS Code Live Server
capacitor://localhost          # Capacitor 包裝(iOS/Android native)
```

---

## Step 3:跑 Migration SQL(手機做,5 分鐘)

### 3.1 去 SQL Editor

Supabase Dashboard → SQL Editor → 「New query」

### 3.2 貼 SQL

打開 `/workspace/hk-fishing-app/migration-email-magic-link.sql`

複製整個檔案嘅 SQL(約 130 行),貼入查詢框。

### 3.3 執行撳「Run」(右下角 / `Ctrl+Enter`)

### ✅ 預期結果:
- 底部出現 `Success. No rows returned`
- 唔會見到任何紅色錯誤

---

## Step 4:測試(手機做,5 分鐘)

### 4.1 打開 App

去 👉 https://limaking1028.github.io/HK-fishing-app/

### 4.2 輸入你嘅 Email

用一個你**真正會收到 email 嘅地址**(例如你常用 Gmail)。

撳「發送登入連結」。

### 4.3 檢查 Email

去 email inbox,應該見到一封來自 Supabase 嘅 email:

```
Subject: Sign in to 香港釣魚數據平台
From: noreply@supabase.io
```

(如果用咗 Supabase 預設 branding;可以之後喺 Authentication → Email Templates 自訂外觀)

### 4.4 撳 Link

Email 入面有個 **「Sign In」** / **「登入」** 按鈕。撳佢。

### 4.5 自動登入

撳咗會被帶返去 PURL,App 應該自動偵測到登入,直接見到主畫面。

---

## Step 5(可選):自訂 Email 外觀

### 1.1 去 Authentication → Email Templates

Supabase Dashboard → Authentication → **Email Templates**

### 1.2 揀「Magic Link」 template

撳 「Magic Link」 template 入面嘅「Edit」。

### 1.3 修改內容(可選)

預設內容係英文 + Supabase logo。可以改為:

**Subject:**
```
登入香港釣魚數據平台 🎣
```

**Body (HTML):**
```html
<h2>釣魚愛好者,你好 👋</h2>
<p>撳下面嘅按鈕登入香港釣魚數據平台:</p>
<p>
  <a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:14px 28px;background:#0d8a99;color:white;border-radius:10px;text-decoration:none;font-weight:600;">
    立即登入
  </a>
</p>
<p style="color:#666;font-size:12px;margin-top:24px;">
  連結 1 小時內有效。如果你沒有要求登入,請忽略此 email。
</p>
<p style="color:#999;font-size:11px;margin-top:24px;">
  香港釣魚數據平台 · 雲端同步 · 多裝置共享
</p>
```

---

## Step 6:生產環境檢查清單

- [x] Email Auth 啟用
- [x] Confirm email OFF(用戶唔需確認)
- [x] Site URL 設定為 GitHub Pages URL
- [ ] 喺 supabase-schema.sql 跑 migration 後,測試一次 magic link
- [ ] 確認 trigger 自動建立 users row(去 Table Editor → users 應該見到 row)
- [ ] Email template 自訂(可選)
- [ ] commit + push 個 migration 同 index.html 改動到 GitHub
- [ ] iOS / Android 用 Capacitor 包裝時,加入 `capacitor://localhost` 到 Redirect URLs

---

## 故障排除

### Q: Email 收唔到
- 檢查 spam folder
- 確認 Supabase 用嘅 SMTP 未超 quota(預設每日 3 條 / 用戶)
- 去 Supabase Dashboard → Logs → Auth Logs 睇 send 記錄

### Q: 撳 link 後 404 / 撞嘅
- 確認 Site URL 啱(必須同 GitHub Pages URL 完全 match)
- 確認 Redirect URLs 包埋呢個 URL

### Q: Magic link 過期
- 預設 1 小時有效。如要改:Supabase Dashboard → Authentication → Providers → Email → 「Magic link expiry time」

### Q: 用戶話 email 唔方便(40-50 歲)
- 唔好咁諗:Email 係 universal 嘅,大多數人都有
- 如果用戶真係冇 email,可以為佢 create Gmail / Outlook(免費,簡單)
- 將來升級到 WhatsApp OTP(等 Business Verification 通過)

### Q: 多個 device 同步?
- ✅ Magic link 同一個 email 喺多個 device 都 work
- 用戶喺新 device 用同一個 email 撳 link,自動登入同一個 profile

---

## 將來升級路徑

當用戶反映「想用 WhatsApp OTP」(可能 WhatsApp Business Verification 已通過),可以:

1. 保留 Email Magic Link 作為 fallback
2. 加返 WhatsApp OTP(用之前嘅 code,但要修 `migration-whatsapp-otp.sql` 不再破壞現有 schema)
3. UI 加「用電話 / 用 email」切換

但目前已經夠用。

---

**設定完成!** 如有問題,睇 Supabase Logs 或者問我。