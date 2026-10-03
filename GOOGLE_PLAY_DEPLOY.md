# 🚀 Google Play 上架完整指南（HK Fishing App）

> **本指南狀態**：配置文件已就緒，需手動執行 Bubblewrap build + Play Console 上傳

---

## 📦 必須檔案（已就緒）

| 檔案 | 位置 | 狀態 |
|---|---|---|
| TWA 配置 | `/workspace/hk-fishing-app/twa-manifest.json` | ✅ |
| Digital Asset Links | `/workspace/hk-fishing-app/.well-known/assetlinks.json` | ✅ |
| PWA Manifest | `/workspace/hk-fishing-app/manifest.json` | ✅ |
| App Icon 192 | `/workspace/hk-fishing-app/icon-192.png` | ✅ |
| App Icon 512 | `/workspace/hk-fishing-app/icon-512.png` | ✅ |
| Feature Graphic 1024×500 | `/workspace/hk-fishing-app/feature-graphic.png` | ✅ |
| Privacy Policy | `/workspace/hk-fishing-app/privacy.html` | ✅ |
| SW (offline + caching) | `/workspace/hk-fishing-app/sw.js` (v89) | ✅ |

---

## 🎯 上架流程（5 步）

### Step 1: 安裝 Bubblewrap CLI

```bash
# 安裝 Java JDK 17+ (Linux)
sudo apt install -y openjdk-17-jdk

# 安裝 Bubblewrap
npm install -g @bubblewrap/cli

# 驗證
bubblewrap --version
```

### Step 2: 初始化 + 產生 keystore

```bash
cd /workspace/hk-fishing-app
bubblewrap init --manifest=twa-manifest.json

# Bubblewrap 會：
# 1. 生成 android.keystore
# 2. 輸出 SHA-256 fingerprint (類似：3A:2B:1C:...)
# 3. 要求你修改 keystore 密碼
```

### Step 3: 填 SHA-256 到 assetlinks.json

```bash
# 取得 fingerprint
keytool -list -v -keystore android.keystore -alias hkfishing

# 複製 SHA256 指紋（形如 3A:2B:1C:4D:5E:6F:...）
# 貼到 .well-known/assetlinks.json 的 sha256_cert_fingerprints 字段
# 去掉冒號，例如：3A2B1C4D5E6F...

# 部署到 GitHub Pages
cd /workspace/hk-fishing-app
git add .well-known/assetlinks.json
git commit -m "feat: 加入 TWA Digital Asset Links 驗證"
git push origin main
```

### Step 4: 構建 App Bundle (.aab)

```bash
cd /workspace/hk-fishing-app
bubblewrap build

# 輸出檔案：app-release-bundle.aab（位於 android/app/build/outputs/bundle/release/）
```

### Step 5: 上傳到 Google Play Console

1. **註冊 Google Play Developer 帳號**（一次性 $25 USD）
   - 網址：https://play.google.com/console
   - 需綁定信用卡
   - 審核 1-3 天

3. **建立新應用**
   - 應用名稱：「香港釣魚數據平台」
   - 預設語言：繁體中文
   - 應用程式類別：體育 / 健康塑身
   - 免費 / 付費：免費

4. **填寫商店資料**
   - 簡短描述（30 字內）：記錄你的每一次上魚時刻。
   - 完整應用說明：見下方模板
   - 應用程式圖示：icon-512.png
   - Feature Graphic：feature-graphic.png
   - Phone Screenshots：見下方截圖準備
   - 隱私政策 URL：`https://limaking1028.github.io/HK-fishing-app/privacy.html`

5. **上傳 AAB**
   - 選單 → 正式版 → 建立新版本
   - 上傳 `app-release-bundle.aab`
   - 填寫版本號 v89 / 版本名稱 1.0.0

6. **填寫內容分級**（IARC 問卷）
   - 類別：休閒
   - 內容問題：無暴力、無成人、無賭博
   - 結果：普遍級（PEGI 3+）

7. **目標對象與內容**
   - 目標年齡：13+
   - 是否含廣告：否
   - 是否應用程式內購買：否
   - 數據分享聲明：見下方

8. **提交審核**
   - 預計審核時間：1-3 天
   - 審核通過後自動上架

---

## 📝 應用程式描述模板

### 簡短描述（30 字）
```
記錄魚獲、行程、月相、潮汐、潮汐預報的香港釣魚 App。
```

### 完整應用說明
```
🇭🇰 香港釣魚數據平台 — 為香港釣魚人設計的終極記錄工具

★ 主要功能
• 一鍵記錄魚獲：魚種、重量、長度、釣法、釣餌
• 行程追蹤：開始 / 結束行程，自動累加「總釣魚時間」
• GPS 自動定位：自動判斷釣點，支援自訂名稱
• 28 種預設釣點：西貢、赤柱、長洲、坪洲等熱門點
• 月相 / 日出日落：月色對漁情的影響
• 潮汐預報：未來 5 天潮汐時間、潮差、釣況評級
• 實時天氣：風力（蒲福級）、溫度、降雨、氣壓、釣況指數
• 雲端同步：登入後多部裝置共享資料
• 統計圖表：總魚獲、總重量、總魚種、總釣魚時間

★ 隱私優先
• GPS 位置只在你點擊「使用 GPS」時記錄
• 完整 PDPA / GDPR 合規，無追蹤、無廣告
• 數據加密傳輸到 Supabase 雲端

★ 離線可用
• PWA 技術，沒網也能記錄
• Service Worker 緩存所有靜態資源

★ 完全免費
• 無內購、無訂閱、無廣告
• 由釣魚愛好者為釣魚愛好者打造

開始記錄你的每一次上魚時刻！
```

### 數據分享聲明
```
本應用不會將你的數據分享給第三方廣告商。
GPS 數據僅儲存在你的帳戶中，用於：
1. 自動判斷釣點名稱
2. 在地圖上顯示你的魚獲位置（僅你本人可見）

如你主動開啟「數據分析 opt-in」：
我們會分析時間 / 月相 / 潮汐 / 天氣與漁情的相關性，
用於日後個人化洞察（你本人受益，不會分享給他人）。

你可隨時在設定中關閉此功能。
```

---

## 📸 應用截圖準備

### 推薦截圖（至少 2 張，建議 4-8 張）

1. **首頁（總魚獲 + 統計）** — 顯示你的數據總結
2. **記錄頁（月色 + 潮汐 + 天氣）** — 顯示智能化輔助
3. **地圖頁（GPS 點分佈）** — 顯示釣點追蹤
4. **行程詳情（總重量、總魚獲）** — 顯示行程管理
5. **潮汐預報（5 天預覽）** — 顯示專業功能

### 截圖規範
- 解析度：1080 × 1920 像素（手機直向）
- 格式：PNG 或 JPEG
- 大小：< 8 MB / 張
- 數量：2-8 張（建議 4-5 張）

### 自動截圖腳本

```bash
# 1. 安裝 Playwright
pip install playwright
playwright install chromium

# 2. 跑截圖腳本（會自動登入測試帳號 + 截 5 個關鍵畫面）
python3 scripts/capture-playstore-screenshots.py
```

輸出檔：
- `screenshots/01-my-log.png`（首頁）
- `screenshots/02-record-form.png`（記錄）
- `screenshots/03-map.png`（地圖）
- `screenshots/04-tides.png`（潮汐）
- `screenshots/05-weather.png`（天氣）

---

## 🔐 安全提醒

### ⚠️ 不要 commit 以下檔案到 GitHub

```bash
# 加入 .gitignore
android.keystore
google-play-service-account.json
*.keystore
google-services.json
```

### ⚠️ 保管好以下檔案（丟失無法更新 App）

```bash
android.keystore     # 用於所有未來 App 簽名
```

建議備份到：
- 加密 USB 隨身碟
- 1Password / Bitwarden 等密碼管理器
- 多重離線備份

---

## ❓ 常見問題

### Q: Bubblewrap init 失敗？
A: 確認 Java 已安裝且版本 ≥ 11：
```bash
java -version
```

### Q: Digital Asset Links 驗證失敗？
A: 用以下 URL 測試（要返回 JSON 200）：
```
https://limaking1028.github.io/HK-fishing-app/.well-known/assetlinks.json
```

### Q: AAB 太大？
A: 確認 targetSdk 是 34、minSdk 是 24。當前 PWA 資源很小（< 500KB），AAB 應該 < 1MB。

### Q: 審核被拒？
常見原因：
1. 隱私權 URL 無法訪問 → 已用 GitHub Pages ✅
2. 缺少截圖 → 見上方截圖準備
3. 內容分級未填 → 見 Step 5.6

### Q: 上架後想更新？
```bash
# 修改版本
# 編輯 twa-manifest.json: versionCode 89 → 90, versionName v89 → v1.0.1
# 重跑 bubblewrap build
# 上傳新 AAB 到 Play Console
```

---

## 📋 上架前最終確認清單

- [ ] Bubblewrap 已安裝
- [ ] Keystore 已生成並妥善保管
- [ ] SHA-256 fingerprint 已填到 assetlinks.json
- [ ] assetlinks.json 已部署到 GitHub Pages
- [ ] AAB 已構建成功
- [ ] Google Play Developer 帳號已註冊（$25 USD）
- [ ] Privacy Policy URL 可訪問
- [ ] 應用截圖已準備（4-5 張）
- [ ] Feature Graphic 已上傳
- [ ] 應用描述已填寫
- [ ] 內容分級已填寫
- [ ] 提交審核

---

## 🎉 完成！

預計上架時間：**今晚配置完成 + 明天提交 → 後天審核通過 → 即可下載**

如有任何問題，可隨時來找我 🚀