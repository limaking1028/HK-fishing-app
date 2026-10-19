# 釣港 項目交接文件（HANDOFF）

> 更新日期：2026-10-18（Asia/Taipei）
> 用途：交接去新對話。新對話開頭請貼成份文件，或叫 Claude 先讀 repo 根目錄嘅 `HANDOFF.md`。
> 溝通語言：**繁體中文（廣東話語氣）**。

---

## 0. 一眼睇晒

| 項目 | 狀態 |
|---|---|
| App | 釣港（香港釣魚記錄 App），已喺 Google Play **封閉測試**上線 |
| 封閉測試審核 | ✅ 已通過 |
| 全螢幕 TWA（冇網址列） | ✅ 已驗證成功（Digital Asset Links 生效） |
| 12 位測試人員、連續 14 日 | 🔵 進行中（要開始叫人加入） |
| 正式版（Production）申請 | ⬜ 14 日測試完成後先可以申請 |

**注意**：「今天吃啥 / Makan Apa」同「迷宮塔防」係用戶另外嘅項目，同釣港**冇關係，唔好混埋**。

---

## 1. 項目基本資料

- Repo：`limaking1028/HK-fishing-app`（舊名 `hk-fishing-app` 會自動轉址）
- 網站：https://limaking1028.github.io/HK-fishing-app/
- 私隱政策：https://limaking1028.github.io/HK-fishing-app/privacy.html
- 刪除帳戶頁：https://limaking1028.github.io/HK-fishing-app/delete-account.html
- Supabase 項目：`lucizjohiycxdynrkjus`
- Android 套件名：`app.hkfishing.twa`
- 商店聯絡電郵：`fishport1028@gmail.com`
- App 版本：v152（`sw.js` CACHE：`hk-fishing-v152`）
- 技術：PWA + TWA（用 Bubblewrap 打包），後端 Supabase（Auth／DB／Storage）

---

## 2. 已完成

### 2.1 Google Play
- 開發者帳戶建立、身份驗證完成。
- 建立 App（套件名 `app.hkfishing.twa`）。
- 上傳 AAB 到封閉測試軌道（versionCode **3**；之後上傳要 **大過 3**）。
- 商店資料：簡短說明（≤80 字）、完整說明、圖示 512×512、主圖 1024×500、手機截圖（用戶自己截新版 UI）。
- App 內容聲明全部完成：私隱政策、App 存取權、廣告（否）、內容分級、目標對象（13 歲或以上）、Data safety、財務／健康／政府聲明、廣告 ID（否）、AI 素材聲明。
- 類別：運動；標籤：地圖及導航、天氣、運動。
- 封閉測試審核通過，用戶已經喺 Google Play 睇到 App 並成功安裝。

### 2.2 Digital Asset Links（已生效）
- 檔案位置：`limaking1028.github.io` 呢個 **user-site repo** 嘅 `main` 分支，路徑 `.well-known/assetlinks.json`。**唔可以放喺 HK-fishing-app repo。**
- 已包含兩個指紋（公開資料，可以保存）：

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "app.hkfishing.twa",
      "sha256_cert_fingerprints": [
        "53:83:F6:0C:E7:40:9D:AB:6D:80:A1:43:34:42:49:65:64:A9:07:76:F9:A8:2D:2D:F3:89:2D:81:E6:3D:77:7E",
        "D0:D2:53:38:B7:A5:F1:5B:CF:08:E7:4D:C7:91:4B:3E:7A:AB:A1:34:B3:0A:D8:24:08:F0:A9:EB:EB:86:45:2D"
      ]
    }
  }
]
```

- 第一個＝upload key；第二個＝Play App Signing key（Play 安裝版用呢個）。
- 指紋格式要**保留冒號同大寫**（舊文件寫「去掉冒號」係錯，已改正）。
- 驗證結果：手機重開 App 後冇網址列。
- **注意**：本 repo 內 `.well-known/assetlinks.json` 仍然係 placeholder，真正生效嗰份喺 user-site repo。

### 2.3 Repo 文件（已合併 `main`）
- `GOOGLE_PLAY_DEPLOY.md`：上架流程指南（已同真實操作同步）。
- `PLAY_DATA_SAFETY.md`：Data safety 答案表（v152）。
- `delete-account.html`：加入部分資料刪除說明、錯誤紀錄保留期。
- 舊截圖 `store-assets/screenshots/phone-01..06.png` 已刪除（舊 UI）。
- `store-assets/play-store-icon-512.png`、`store-assets/feature-graphic-1024x500.png` 已核對尺寸。

---

## 3. 未完成

### 3.1 用戶自己要做（按緊急程度）
1. **叫齊 12 位測試人員**：每人用清單入面嘅 Gmail，開加入測試連結（Console → 測試 → 封閉測試 → 測試人員 → 複製連結），喺 Android 手機撳「成為測試人員」。要**連續 14 日**保持加入，每人嘅 14 日由佢撳加入嗰日起計。內部測試唔計。
2. **確認 keystore 已備份**：用戶曾經輸入 keystore 密碼出錯（`keytool -list` 報密碼錯誤）。keystore 檔案同密碼都唔可以丟失。如果密碼確實唔記得，可以喺 Play Console 申請「重設上傳金鑰」。
3. **更換 keystore 同 key 密碼**（因為曾曝光）：用 `keytool -storepasswd` / `-keypasswd`，**密碼唔好貼畀 Claude**。
4. **備份 Supabase 相關表格為 CSV**，再清理測試數據（後台：先「移出排行榜」，永久刪除要輸入 `DELETE`）。
5. **清理手機 Chrome 網站數據**。
6. **確認 App 存取權測試帳號**：電郵＋密碼登入、**唔可以係管理員**、密碼只由用戶直接喺 Play Console 填寫，唔好放入 repo 或畀 Claude。截圖顯示用戶而家用「管理員TOTORO」登入，測試帳號要另開。
7. **更新後台「上架待辦」進度**（見 §6 SQL）。
8. 14 日完成後，喺 Play Console 申請正式版。

### 3.2 開發待辦（可選）
- `delete_my_account()` 目前**冇刪 `client_errors`**（自動錯誤回報表，保留 30 日）；`delete-account.html` 已按現況寫明，將來可以改為刪除帳戶時一併清除。
- 錯誤回報目前**冇關閉選項**；考慮改為 opt-in。
- 相片孤兒檔清理、API 用量監察、後台操作紀錄 CSV 匯出、2027 年潮汐數據。
- Repo 內 `twa-manifest.json` 係**舊樣本**（versionCode 89、alias `hkfishing`、冇 minSdk），真正打包用本機檔案（見 §5）。建議同步或刪除，避免混亂。
- `scripts/capture-playstore-screenshots.py` 已過時（selector 對唔到現時 UI），冇使用。
- 如日後重新啟用 WhatsApp OTP、加廣告、加分析工具或 IAP，要重新檢視 Data safety 同私隱政策。

---

## 4. 上架／測試流程備忘

### 封閉測試
- 需要 ≥12 位測試人員連續 14 日；加入方式係 opt-in 連結，唔係喺 Play 商店搜尋。
- 淨係 Android 手機用到。
- 連結生效後可能要等幾分鐘。

### 正式版
- 14 日完成後，Console 會出現申請正式版嘅入口。
- 申請時要答問卷（測試情況、App 準備度），內容要如實。

### 之後更新 App
- 每次新 AAB 嘅 versionCode 要 **大過上一次**（目前上限 3，下次用 ≥4）。
- 用同一個 upload key 簽署。
- 有網頁改動時，記得 bump `sw.js` CACHE（見 §7）。

---

## 5. 技術備忘（本機環境，用戶電腦）

> 以下路徑係用戶 Windows 電腦，唔係 Claude 容器。

- keystore：`C:\Users\ivanl\android.keystore`（PKCS12，alias `android`）
- AAB：`C:\Users\ivanl\app-release-bundle.aab`
- JDK／SDK：`C:\Users\ivanl\.bubblewrap\`
- `minSdkVersion`：24

**唔使密碼就攞到 upload key 指紋：**

```cmd
"C:\Users\ivanl\.bubblewrap\jdk\jdk-17.0.11+9\bin\keytool.exe" -printcert -jarfile C:\Users\ivanl\app-release-bundle.aab
```

**Play 簽署指紋位置：** Play Console 頁面網址最尾 `protect-with-play` 改成 `keymanagement`，或者喺搜尋列搜尋 `App signing`。

### 登入方式
- 電郵＋密碼（預設）、電郵驗證碼／Magic link、Google OAuth。
- WhatsApp OTP 舊代碼仍在，但登入畫面冇呢個選項。

### 第三方服務
- Supabase（認證／資料庫／儲存）。
- Open-Meteo：由用戶裝置直接帶經緯度請求（所以 Data safety 精確位置要揀「收集＋分享」）。
- Nominatim：約 110 米模糊化座標。
- MapTiler／Leaflet：地圖圖層。
- 冇廣告、冇廣告 SDK、冇內購。

### 資料相關重點
- 排行榜只顯示：顯示名稱、魚種、重量、日期（v133 起唔回傳釣點、座標、相片）。
- `clearAllRecords()` 刪除雲端 `catches` 同 `fishing_trips`（保留帳戶）。
- `client_errors`：message、stack、app_version、source、url、user_id；保留 ≤30 日。
- `track_usage`：只記每日每鐘頭前景使用秒數，冇關閉選項。
- 「📊 匿名統計」係 opt-in：同意後魚獲附加時間、月相、潮汐、天氣、GPS 距離等條件。

---

## 6. 後台「上架待辦」更新（Supabase SQL Editor）

> 後台函數（`admin_todo_save`）要管理員登入先用到，Claude 無法代為更新。以下 SQL 喺 Supabase SQL Editor 直接執行。標題按初始種子配對，如果之前改過標題，該行唔會被更新。預期更新 12 行 + 1 行。

```sql
update public.launch_todos
   set status = 'done', updated_at = now()
 where title in (
  '填入 upload key 指紋到 assetlinks.json',
  '生成 keystore 並打包 AAB',
  '完成 Google Cloud OAuth 設定',
  '更新 GOOGLE_PLAY_DEPLOY.md 與 privacy.html',
  '完成 Play 開發者帳戶身份驗證（上傳證件）',
  '驗證 Android 流動裝置（需要 Android 手機）',
  '驗證聯絡電話',
  '建立 Play 應用程式並填寫商店資料',
  '準備手機截圖（1080×1920）',
  '完成 Data safety 與內容分級問卷',
  '上傳 AAB 到封閉測試軌道',
  '加入 Play App Signing 指紋到 assetlinks.json'
 );

update public.launch_todos
   set status = 'doing', updated_at = now()
 where title = '邀請 12 位測試者，連續 14 日參與封閉測試';
```

進度總表：

| # | 待辦 | 狀態 |
|---|---|---|
| 1–4 | 指紋、keystore＋AAB、OAuth、文件更新 | ✅ |
| 5 | 更換 keystore 同 key 密碼 | ⬜ |
| 6 | 備份 Supabase 為 CSV | ⬜ |
| 7 | 清理測試數據 | ⬜ |
| 8 | 清理手機 Chrome 網站數據 | ⬜ |
| 9 | 建立 App 存取權測試帳號 | ❓ 用戶確認 |
| 10–13 | 帳戶驗證、Android 裝置、電話、建立 App | ✅ |
| 14 | 手機截圖 | ✅ |
| 15 | Data safety＋內容分級 | ✅ |
| 16 | 上傳 AAB 到封閉測試 | ✅ |
| 17 | 加入 Play App Signing 指紋 | ✅ |
| 18 | 邀請 12 位測試者連續 14 日 | 🔵 進行中 |

建議加一項：「14 日封閉測試到期日」＝最後一位測試人員加入日＋14 日。

---

## 7. 工作規則（必須遵守）

### 7.1 Git 流程
- **一個改動一條 branch**，同用戶確認先合併入 `main`（有 migration 就要等用戶回覆「完成」）。
- Commit 訊息結尾加：
  ```
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: <當次 session 連結>
  ```
- 只有 App 版本發佈先 bump `sw.js` CACHE（目前 `hk-fishing-v152`）。`privacy.html`、`delete-account.html`、純文件改動唔使 bump（`sw.js` 唔 cache 呢兩頁）。
- Repo 顯示 "This repository moved" 係正常現象（已改名 `HK-fishing-app`），唔影響 push。

### 7.2 Stop hook 嘅「未推送」警告
`~/.claude/stop-hook-git-check.sh` 經常誤報「有未推送 commit 同冇 remote branch」。**先核對，唔好盲目重推：**

```bash
git ls-remote origin refs/heads/<branch>
git rev-parse HEAD
```

兩個 hash 一樣＝已推送，係誤報。

### 7.3 安全紅線
- **唔好叫用戶貼**：密碼、簽署金鑰／keystore 檔案、OAuth client secret。
- 測試帳號密碼由用戶直接喺 Play Console 填寫，唔放入 repo、文件，亦唔畀 Claude。
- 測試帳號**唔可以係管理員**。
- 唔好叫用戶影身份證件或個人資料相。
- 指紋（SHA-256）係公開資料，貼出嚟冇問題。

### 7.4 溝通風格
- 繁體中文、廣東話語氣；先講結論，再講步驟。
- 用戶唔係工程師，Console 操作要逐步指引；選單名稱會因 Console 改版而變，唔確定時請用戶截圖。
- 唔好主動叫用戶做大型改動；要合併先問。

---

## 8. Git 狀態（交接時）

- `main`：`d299207`（已含全部 Play 上架文件、assetlinks 格式修正）。
- 本交接文件所在 branch：`docs/handoff-2026-10-18`（合併前請用戶確認）。
- 已合併嘅文件 branch：`docs/play-console-account-status`、`docs/play-listing-v152-sync`、`docs/play-console-answers-final`、`docs/assetlinks-fingerprint-format`。

---

## 9. 新對話建議開場

> 「我係釣港嘅負責人。請先讀 repo 嘅 `HANDOFF.md`，跟住按『未完成』清單幫我繼續。用繁體中文、廣東話語氣。釣港同今天吃啥／Makan Apa 係兩個唔同項目，唔好混埋。」

下一步建議：
1. 確認測試人員加入情況（幾多人已 opt-in、最早加入日期）。
2. 執行 §6 SQL 更新後台待辦。
3. 處理 keystore 備份同密碼更換。
4. 14 日到期前一星期，檢查正式版申請條件。
