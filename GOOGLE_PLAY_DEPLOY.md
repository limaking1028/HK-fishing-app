# 🚀 Google Play 上架指南（釣港 HK Fishing App）

> **最後更新**：2026 年 10 月 13 日 · 對應 App 版本：v151 · Service Worker：`hk-fishing-v151`
>
> **本指南狀態**：配置檔已就緒；簽署、AAB 構建同 Play Console 上傳需要由負責人喺自己電腦手動完成。
> 所有路徑都係相對於 repo 根目錄。

---

## ✅ 目前進度總覽

| 項目 | 狀態 | 備註 |
|---|---|---|
| TWA 配置 `twa-manifest.json` | ⚠️ 未完成 | `versionCode` 仲係 89、`versionName` 仲係 v89；keystore 密碼仲係佔位符 |
| Digital Asset Links `.well-known/assetlinks.json` | 🟡 進行中 | 位置：`limaking1028.github.io` repo 根目錄；upload key 指紋已填（待部署驗證），Play App Signing 指紋待首次上傳 AAB 後加入 |
| PWA Manifest `manifest.json` | ✅ | |
| App 圖示 512 `icon-512.png` / `store-assets/play-store-icon-512.png` | ✅ | 512×512 |
| Feature Graphic `feature-graphic.png` | ✅ | 1024×500 |
| 手機截圖（1080×1920） | ❌ 待重新截 | 舊版截圖（舊 UI 同示範數據）已由 repo 刪除，要用最新版本重新截，可用 `scripts/capture-playstore-screenshots.py` |
| 私隱政策 `privacy.html` | ✅ | 生效版本 v152，已包括錯誤紀錄同管理員內部查看 |
| 刪除帳戶 | ✅ | App 內「設定 → 永久刪除帳戶」（`deleteAccount()`，調用 `delete_my_account()`，見 `migration-v107-hardening.sql`）；網頁申請頁 `delete-account.html` |
| 簽署 keystore `android.keystore` | ✅ 已生成 | 存放喺本機 `C:\Users\ivanl\android.keystore`（唔入 repo）；之前密碼曾曝光，要用 `keytool -storepasswd` 更換並安全備份 |
| `.gitignore` 排除 keystore | ✅ | `android.keystore`、`*.keystore`、`google-play-service-account.json`、`google-services.json` |
| `android/` 專案資料夾 | ✅ 已生成 | 喺本機，唔入 repo |
| AAB 構建 | ✅ 已完成 | 本機 `C:\Users\ivanl\app-release-bundle.aab`，待開發者帳戶驗證完成後上傳封閉測試 |
| Play Console 開發者帳戶 | 🟡 已建立，身份驗證進行中 | $25 USD 一次性；仲要完成證件上傳、Android 裝置驗證同聯絡電話驗證 |
| Google OAuth 同意畫面 | ⚠️ 要確認 | 要由「測試」改為「正式」，否則只有測試用戶可以登入 |
| Supabase Redirect URL | ⚠️ 要確認 | 要包括 `https://limaking1028.github.io/HK-fishing-app/**` |

---

## 🎯 上架流程

### Step 1：安裝工具（喺你自己嘅電腦）

```bash
# 需要 Java JDK 17 或以上
java -version

# 安裝 Bubblewrap
npm install -g @bubblewrap/cli
bubblewrap --version
```

### Step 2：初始化 + 生成 keystore

```bash
cd HK-fishing-app
bubblewrap init --manifest=twa-manifest.json
```

Bubblewrap 會：
1. 生成 `android.keystore`
2. 輸出 SHA-256 指紋（格式類似 `3A:2B:1C:...`）
3. 要求你設定 keystore 密碼

**設定密碼後，記得修改 `twa-manifest.json` 嘅 `keystorePasswordValue`**（而家係 `CHANGE_ME_BEFORE_BUILD`）。
密碼建議放入密碼管理器，唔好寫入 repo。

### Step 3：更新版本號

`twa-manifest.json` 而家係 `versionCode: 89`、`versionName: "v89"`。首次上架建議改為：

```json
"versionCode": 1,
"versionName": "1.0.0"
```

之後每次上傳都要比上一次更大嘅 `versionCode`。

### Step 4：填 SHA-256 到 assetlinks.json，並部署

> ⚠️ **assetlinks.json 必須放喺網域根目錄**，即係 `limaking1028.github.io` 呢個 user-site repo 嘅 `main` 分支，路徑 `.well-known/assetlinks.json`。**唔可以放喺 HK-fishing-app repo**，否則 Android 驗證唔會通過。

**4.1 攞 upload key 指紋（keystore 生成時已經有）**

```cmd
"C:\Users\ivanl\.bubblewrap\jdk\jdk-17.0.11+9\bin\keytool.exe" -list -v -keystore C:\Users\ivanl\android.keystore -alias android
```

搵 `SHA256:` 一行，**去掉冒號**，填入 `sha256_cert_fingerprints`。

**4.2 等 Play App Signing 指紋（第一次上傳 AAB 之後）**

Play 會用自己嘅 App signing key 重新簽署。第一次上傳成功後，喺 Play Console → 設定 → 應用程式完整性 → 應用程式簽署，攞 **App signing key certificate** 嘅 SHA-256（去掉冒號），**加入同一個陣列**：

```json
[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app","package_name":"app.hkfishing.twa","sha256_cert_fingerprints":["upload key 指紋","Play App Signing 指紋"]}}]
```

**4.3 部署並驗證**

編輯 `limaking1028.github.io` repo 嘅 `.well-known/assetlinks.json`，commit 去 `main`，然後用無痕視窗打開：

```
https://limaking1028.github.io/.well-known/assetlinks.json
```

確認返回 JSON（HTTP 200）。

### Step 5：構建 App Bundle（.aab）

```bash
bubblewrap build
```

輸出檔案：`app-release-bundle.aab`（位於 `android/app/build/outputs/bundle/release/`）。

### Step 6：Play Console 設定

#### 6.1 開發者帳戶
- 網址：https://play.google.com/console
- 一次性 $25 USD，需綁定信用卡，並完成身份驗證
- 照我所知，新個人帳戶通常要先做封閉測試：**12 位測試者連續 14 日參加**，之後先可以正式上架。呢個規定可能有變，請以 Console 最新要求為準。

#### 6.2 建立應用程式
- 應用程式名稱：釣港
- 預設語言：繁體中文（香港）
- 應用程式類別：體育 或 健康與健身（請以 Console 提供嘅選項為準）
- 免費 / 付費：免費

#### 6.3 商店資料
- 簡短描述（30 字內）：見下方「應用程式描述」
- 完整說明：見下方「應用程式描述」
- 應用程式圖示：`store-assets/play-store-icon-512.png`
- Feature Graphic：`feature-graphic.png`（1024×500）
- 手機截圖：待用最新版本重新截（舊版已刪除）
- 隱私權政策 URL：`https://limaking1028.github.io/HK-fishing-app/privacy.html`

#### 6.4 App 存取權（審核用測試帳戶）
App 需要登入才能使用主要功能，所以要喺「App 存取權」提供**測試帳戶**。
- 測試帳戶請由你自己建立同設定密碼，並填入 Console。
- 請勿將密碼寫入 repo 或文件。

#### 6.5 資料安全表（Data safety）
要同 `privacy.html` 對齊，主要包括：

| 類別 | 內容 | 用途 | 是否可刪除 |
|---|---|---|---|
| 個人資料 | 電郵、顯示名稱 | 帳戶登入 | 是（刪除帳戶） |
| 位置 | GPS 座標、定位誤差（用戶按「使用 GPS」先記錄） | 自動識別釣點、地圖 | 是（刪除魚獲／帳戶） |
| 相片 | 用戶上載嘅魚獲照片 | 魚獲記錄 | 是（刪除魚獲／帳戶） |
| App 活動 | 使用時間匯總（保存 12 個月） | 統計 | 是（刪除帳戶） |
| 其他用戶內容 | 魚獲、行程、意見回饋 | 功能本身 | 是 |

傳輸與儲存：數據經加密傳輸；資料庫託管於 Supabase（新加坡）。

第三方服務（需要喺表格入面披露）：
- **Supabase**：帳戶、魚獲、行程數據
- **Open-Meteo**：天氣數據（只讀取 GPS 附近網格）
- **OpenStreetMap Nominatim**：GPS 反向地理編碼（座標經模糊化，約 110 米）

**不要寫「符合 PDPA／GDPR」或「無追蹤」呢類未經核實嘅聲明**，以 `privacy.html` 為準。

#### 6.6 內容分級（IARC 問卷）
- 類別：休閒 / 應用程式
- 暴力、成人內容、賭博：均無
- 結果以 Console 生成為準

#### 6.7 目標對象與內容
- 目標年齡：13 歲以上
- 是否含廣告：否
- 是否應用程式內購買：否
- 是否有用戶互動（排行榜、回饋）：是，需要按 Console 嘅指引填寫

#### 6.8 上傳 AAB 並提交
- 選單 → 測試 或 正式版 → 建立新版本
- 上傳 `app-release-bundle.aab`
- 版本名稱：Console 預設用 `3 (3)`（已上傳 AAB 嘅 versionCode 係 3，只供內部識別，測試者睇唔到）。之後每次上傳，versionCode 都要大過上一次。repo 內 `twa-manifest.json` 係舊樣本，實際打包用嘅係本機另一份，要以本機為準。
- 提交審核（通常 1–3 日）

---

## 📝 應用程式描述

### 簡短描述（30 字內）
```
記錄魚獲、行程、月相、潮汐與天氣的香港釣魚記錄 App。
```

### 完整說明（草稿，請按實際功能核對）
```
釣港 — 為香港釣魚人而設的記錄工具

主要功能
• 魚獲記錄：魚種、重量、長度、釣法、釣餌、相片
• 行程追蹤：開始／結束行程，累計總釣魚時間
• GPS 自動識別釣點，可加自訂備註
• 月相、日出日落、潮汐時間與未來 5 天潮汐預報
• 天氣資料：風力、溫度、降雨、氣壓
• 我的統計：魚獲、魚種、時段與釣點分析
• 雲端同步：登入後多部裝置共用資料

私隱
• GPS 位置只在你按「使用 GPS」時記錄
• 可隨時刪除單條魚獲，或在 App 內永久刪除帳戶
• 詳見私隱政策

免費使用，無內購、無廣告。
```

> 注意：「28 種釣點」、「完全免費」、「完整 PDPA／GDPR 合規」等字眼未經核實，已由草稿移除。如要加入，請先確認事實。

---

## 📸 截圖

### 規格
- 解析度：1080 × 1920（手機直向）
- 格式：PNG 或 JPEG
- 大小：每張 < 8 MB
- 數量：2–8 張（建議 4–5 張）

### 現有檔案
舊版截圖（`phone-01.png` 至 `phone-06.png`）因為係舊版 UI 同示範數據，已經刪除（git 歷史仲可以還原）。

**注意**：上架前要用最新版本重新截（1080×1920），特別係首頁、記錄頁、地圖、行程、潮汐預報。

### 舊截圖腳本（現時唔適用）
`scripts/capture-playstore-screenshots.py` 需要測試帳戶，而且係舊版畫面，暫時唔建議使用。

---

## 🔐 安全提醒

### 唔好 commit 以下檔案
`.gitignore` 已排除，但請再次確認：
```
android.keystore
*.keystore
google-play-service-account.json
google-services.json
```

### 保管好 keystore（丟失無法更新 App）
`android.keystore` 同 keystore 密碼用於所有未來版本簽署。建議備份到：
- 加密 USB 隨身碟
- 密碼管理器（1Password、Bitwarden 等）
- 最少一份離線備份

---

## ❓ 常見問題

**Bubblewrap init 失敗？**
確認 Java 已安裝，版本 17 或以上：`java -version`

**Digital Asset Links 驗證失敗？**
- 確認 `assetlinks.json` 已部署，並可以用瀏覽器打開
- 確認指紋已去掉冒號，而且係用嚟簽署 AAB 嗰個 keystore 嘅指紋
- 確認 `package_name` 係 `app.hkfishing.twa`

**Google 登入喺 App 入面失敗？**
- 確認 Google OAuth 同意畫面已改為「正式」
- 確認 Supabase Redirect URL 包括 `https://limaking1028.github.io/HK-fishing-app/**`

**審核被拒？**
常見原因：
1. 私隱權政策 URL 無法訪問，或者內容同資料安全表唔一致
2. 缺少可用嘅測試帳戶（App 存取權）
3. 截圖同實際功能唔符
4. 內容分級或資料安全表未填完整

**上架後更新？**
1. 修改 `twa-manifest.json`：`versionCode` +1，`versionName` 改新版本
2. 重跑 `bubblewrap build`
3. 上傳新 AAB 到 Play Console

---

## 📋 上架前最終確認清單

**準備工作**
- [ ] 真機測試（Android 同 iPhone）完成
- [ ] Supabase Redirect URL 已確認
- [ ] Google OAuth 同意畫面已設為「正式」

**簽署與構建**
- [ ] Bubblewrap 已安裝（Java 17+）
- [ ] `android.keystore` 已生成並備份
- [ ] `twa-manifest.json` 嘅 keystore 密碼已更新
- [ ] `twa-manifest.json` 嘅 `versionCode`、`versionName` 已更新
- [ ] SHA-256 指紋已填入 `assetlinks.json`，並已部署，網址可以打開
- [ ] AAB 構建成功

**Play Console**
- [ ] 開發者帳戶已註冊並完成驗證
- [ ] 封閉測試條件已完成（如適用）
- [ ] 商店資料、描述、圖示、Feature Graphic 已填
- [ ] 截圖已用 v151 重新截
- [ ] 私隱政策 URL 可訪問，並已更新
- [ ] 資料安全表已填
- [ ] 內容分級已填
- [ ] 目標對象與內容已填
- [ ] App 存取權（測試帳戶）已填
- [ ] AAB 已上傳，提交審核

---

## 📌 之後要做（上架以外）
- Open-Meteo 嘅授權：免費版只限非商業用途。如果將來有收費或廣告，要改用付費 API，或者改用香港天文台數據。
- iOS：需要 Apple 開發者帳戶（每年 $99 USD）同 Sign in with Apple。
- 私隱政策「生效版本」同更新日期要同步更新。
