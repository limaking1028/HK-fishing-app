# WhatsApp OTP 認證設定指南

> **給開發者(Limaking):** 跟住呢份指南 step-by-step 由零開始設定,成個過程大約 1-2 小時(包含 Meta 審批 + Supabase 部署)

---

## 為何揀 WhatsApp OTP?

| 方案 | 優點 | 缺點 | 結論 |
|------|------|------|------|
| Email + Password | 技術簡單 | 40-50 歲用戶要記密碼,容易丟失 | ❌ |
| Email Magic Link | 唔使記密碼 | 要開 Email App,釣魚場無信號時麻煩 | ⚠️ |
| SMS OTP | 普及 | 香港 SMS 商業 API 貴(HK$0.5-1/條) | ❌ |
| **WhatsApp OTP** | ✅ 普及近 100%,免費頭 1000 條/月,真人電話 | 需 Meta 商家帳號審批 | ✅ **推薦** |

**WhatsApp Cloud API 收費:**
- 頭 1000 條/月:**免費**(永久)
- 之後每 1000 條商業模板訊息:**約 US$8-15**(2026 年 Meta 政策)
- 預估 1000 用戶,每人每月 5 次登入 = 5 000 條 = ~US$40-80/月 = HK$300-600/月

---

## Step 1:建立 Meta Business 帳號(30-60 分鐘)

### 1.1 註冊 Meta Business
1. 去 https://business.facebook.com/
2. 用你嘅 Facebook 帳號登入
3. 「建立帳號」→ 填公司/個人資料
   - **業務名稱:** 「香港釣魚數據平台」或你嘅真實公司名
   - **業務類別:** 「軟件 / Apps」
   - **聯絡電郵:** 你嘅 email
4. 完成驗證電郵

### 1.2 創建 WhatsApp Business App
1. 去 https://developers.facebook.com/
2. 「My Apps」→「Create App」
3. 揀 **「Business」** 類型
4. 揀你啱啱建立嘅 Business Account
5. App 名稱: `HK Fishing OTP`(隨意)
6. 喺 App Dashboard 嘅「Add a Product」,搵 **WhatsApp** → 點 **Set Up**

### 1.3 加 WhatsApp 電話號碼
1. WhatsApp → API Setup → 揀 **「Create a WhatsApp Business Account」**
2. 你有兩個選擇:
   - **(a) Meta 提供測試號碼**(推薦起步用): 即刻可用,只可以發給你自己
   - **(b) 用你自己公司電話號碼**: 要經 Meta 商家驗證(2-3 工作日)
3. 揀 (a) 測試號碼 → 跟住步驟完成設定
5. 記低兩個值(之後要放去 Supabase):
   - **Phone Number ID** = `xxxxxxxxxxxxxx`(在 WhatsApp > API Setup 頁面)
   - **WhatsApp Business Account ID** = `xxxxxxxxxx`(可選)

### 1.4 拎 Access Token
1. WhatsApp → API Setup → 「Temporary access token」**(只係 24 小時有效!)**
2. 你需要一個 **Permanent Token**:
   - 去 Business Settings → System Users → Add
   - 設定 role: Admin
   - 「Add Assets」→ 揀你嘅 WhatsApp App → 啟用「Full Control」
   - 「Generate New Token」→ 揀你嘅 App,選 `whatsapp_business_management` + `whatsapp_business_messaging` 兩個 permission
   - **Save this token securely!** 這就是 `WHATSAPP_ACCESS_TOKEN`

---

## Step 2:創建 WhatsApp 訊息模板(15-30 分鐘審批)

### 2.1 設計模板
1. 去 https://business.facebook.com/ → WhatsApp Manager → Message Templates
2. 「Create Template」
   - **Name:** `hk_fishing_otp`(之後 `WHATSAPP_TEMPLATE_NAME` 環境變數)
   - **Category:** **Authentication**(很重要!否則模板唔可以帶一次性驗證碼)
   - **Language:** `Chinese (Hong Kong)`
   - **Header:** Optional,可省略
   - **Body:** 複製以下:

```
您的香港釣魚驗證碼是 {{1}},5 分鐘內有效。請勿向任何人透露此驗證碼。
```

   - **Footer:** Optional
   - **Buttons:** Optional

3. Submit for review(通常 5-30 分鐘,工作日會更快)

### 2.2 等審批
- 模板狀態會由「Pending」→「Approved」
- 審批後你會收到電郵通知
- **期間你可以繼續做 Step 3**

---

## Step 3:Supabase 部署 Edge Functions(15 分鐘)

### 3.1 安裝 supabase CLI
```bash
# macOS
brew install supabase/tap/supabase

# 或用 npm
npm install -g supabase
```

### 3.2 連結你嘅 Supabase 專案
```bash
cd /workspace/hk-fishing-app
supabase login                          # 會彈出 browser 認證
supabase link --project-ref <你的-ref>   # 在 Supabase Dashboard > Settings > General 搵
```

### 3.3 設定環境變數(Secrets)
```bash
# WhatsApp 認證(從 Step 1.4 + 1.3 拎)
supabase secrets set WHATSAPP_ACCESS_TOKEN="EAAIxxxxx..."   # 永久 token
supabase secrets set WHATSAPP_PHONE_ID="123456789012345"    # Phone Number ID
supabase secrets set WHATSAPP_TEMPLATE_NAME="hk_fishing_otp" # 預設,可省略
supabase secrets set WHATSAPP_LANG_CODE="zh_HK"             # 預設,可省略

# 開發期間想喺 client 睇到驗證碼(方便測試):
> supabase secrets set WHATSAPP_DEBUG_RETURN_CODE="true"

# **Production 一定要 UNSET!**
> supabase secrets unset WHATSAPP_DEBUG_RETURN_CODE
```

### 3.4 部署兩個 Edge Functions
```bash
supabase functions deploy send-whatsapp-otp
supabase functions deploy verify-whatsapp-otp
```

成功後會見到類似:
```
Deployed Function send-whatsapp-otp on project limaking-hk-fishing
Function URL: https://<project-ref>.supabase.co/functions/v1/send-whatsapp-otp
```

---

## Step 4:執行 SQL Migration(5 分鐘)

1. 去 https://supabase.com/dashboard → 你嘅專案 → SQL Editor
2. 「New query」→ 開檔 `/workspace/hk-fishing-app/migration-whatsapp-otp.sql`
3. 貼上全部內容 → 執行
4. 預期結果:成功(無錯誤)

### 驗證 SQL 成功
```sql
-- 應該見到 phone_e164 / phone_verified / last_login_at / created_via
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'users'
  and column_name like '%phone%' or column_name = 'created_via';

-- 應該見到 otp_codes + login_attempts 兩張表
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('otp_codes', 'login_attempts');
```

---

## Step 5:更新 index.html + lib/auth.js(已完成)

✅ 已加入 `<script src="./lib/auth.js"></script>`  
✅ 登入 UI 已改為兩步驟流程  
✅ 舊嘅 sbRegister/sbLogin 已標 deprecated  

推到 GitHub:
```bash
cd /workspace/hk-fishing-app
git add .
git commit -m "WhatsApp OTP 認證系統"
git push origin main
```

---

## Step 6:本地測試(15 分鐘)

### 6.1 開啟 Dev 模式
```bash
supabase secrets set WHATSAPP_DEBUG_RETURN_CODE="true"
supabase functions deploy send-whatsapp-otp --no-verify-jwt
```

### 6.2 測試流程
1. 用 Chrome DevTools 打開 https://limaking1028.github.io/HK-fishing-app/
2. 開啟 Network tab,filter "supabase"
3. 輸入你自己嘅香港手機號碼(必須與 Meta test 號碼「收件人」內已加入的號碼一致)
4. 點「發送 WhatsApp 驗證碼」
5. **應該見到 popup 顯示 `🔧 DEV 模式驗證碼:xxxxxx`**
6. 輸入驗證碼 → 應該成功登入
7. Supabase Dashboard → Table Editor → `users` 表,應該見到你嘅帳號已自動建立

### 6.3 真實 WhatsApp 測試
1. 確認 Meta WhatsApp Manager 已加入你嘅電話做「Test Number」
2. WhatsApp Manager → Test Number → 「Send a test message」
3. 真實收到 WhatsApp 訊息? → 成功!

### 6.4 Production 模式(移除 dev 碼)
```bash
supabase secrets unset WHATSAPP_DEBUG_RETURN_CODE
supabase functions deploy send-whatsapp-otp
```

---

## Step 7:上線 checklist

- [ ] WHATSAPP_ACCESS_TOKEN 係永久 token(非 24 小時臨時)
- [ ] WHATSAPP_DEBUG_RETURN_CODE **未設定**(生產環境)
- [ ] 訊息模板已 Approved
- [ ] 已加入至少 1 個 Production 電話號碼(非測試號碼)
- [ ] SQL migration 已執行
- [ ] Edge Functions 已部署
- [ ] 客戶端 `index.html` 已推到 GitHub Pages
- [ ] 用測試帳號喺手機完整測試一次登入流程
- [ ] WhatsApp 訊息內嘅驗證碼可正確 enable 登入
- [ ] 5 分鐘後驗證碼過期
- [ ] 60 秒內唔可以重發(冷卻)
- [ ] 連續 5 次錯密會鎖定 5 分鐘
- [ ] 退出後再登入可以成功

---

## 故障排除

### Q: WhatsApp 訊息送不出去
- 確認 Meta test number 已加入你嘅電話號碼
- 確認 token 未過期(永久 token 唔會過期)
- 確認 Phone Number ID 啱
- 確認模板已 Approved
- 看 Supabase Edge Function logs:`supabase functions logs send-whatsapp-otp`

### Q: 驗證碼 mismatch
- 確認 server time 與 client time 一致
- Edge Function 用 `new Date()` (server UTC) 計算 expires_at,無 client 時間問題
- 看 `otp_codes` 表 `attempts` 欄位有冇增加

### Q: 用戶想回退 username+PIN 登入
- 因 sbRegister/sbLogin 仲喺 code 度(deprecated),可以加返 UI 但唔推薦
- 建議:全部用戶都用電話,慢慢過渡
- 如要清理:`update users set pin_hash=null, pin_salt=null where phone_verified is not null;`

### Q: WhatsApp 訊息收費超出預期
- 用 `login_attempts` 表統計每月 send_otp 次數:
```sql
select date_trunc('day', created_at) as day, count(*) as sends
from login_attempts where action='send_otp' and success
group by 1 order by 1 desc limit 30;
```
- Meta 頭 1000 條免費,超出後可改用 SMS OTP fallback 或加強 UX 減少重發

### Q: 想換 Meta Business Account
- 重新做 Step 1 + 更新 Supabase secrets 即可
- Edge Functions 唔需要重 deploy(token + Phone ID 透過環境變數讀取)

---

## 後續優化(可選)

### A) 自動清理過期 OTP
喺 Supabase SQL Editor 加 cron job:
```sql
-- 每日清理過期 OTP(需要先 enable pg_cron extension)
select cron.schedule('cleanup-otp', '0 3 * * *', $$
  delete from otp_codes where expires_at < now() - interval '1 day';
  delete from login_attempts where created_at < now() - interval '30 days';
$$);
```

### B) 多語言模板
1. 喺 Meta Business 創建多語言模板(`en_US`, `zh_CN`)
2. 更新 Edge Function 根據用戶偏好語言選擇
3. UI 加語言偵測

### C) 加 SMS OTP fallback
1. 註冊 Twilio 或 AWS SNS
2. 加新嘅 send-sms-otp Edge Function
3. WhatsApp 訊息失敗時自動 fallback 到 SMS

### D) 帳號綁定多電話
目前一個電話對應一個 user。可加 `user_phones` 多對多表支援「主號 + 副號」。

---

**設定完成!** 如有任何問題,睇 `supabase functions logs <function-name>` 或聯絡 Meta Support。