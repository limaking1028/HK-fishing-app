# 釣港 iOS（Capacitor）設定說明

> 狀態：**只係 PR，未 build 過真機、未上 TestFlight。** 網頁（GitHub Pages）同 Android TWA 完全唔受影響。

## 呢個 PR 做咗乜
- 加 Capacitor 7 iOS 殼：Bundle ID `app.hkfishing.ios`，App 名「釣港」。
- `scripts/build-ios-web.js`：打包前將 repo 根目錄嘅網頁檔（index.html、lib/、photos/ 等）**複製**去 `www/`（唔改原檔，`www/` 唔入 repo）。
- `ios/`：Xcode 工程（CocoaPods）；`Info.plist` 加咗中文權限說明同 URL scheme `app.hkfishing.ios://`。
- `codemagic.yaml`：兩個 workflow，**只會手動開始**：
  - `ios-simulator-check`：唔使 Apple 帳戶，試 build 模擬器版，確認工程無問題。
  - `ios-testflight`：Apple 批咗之後先用，自動簽名＋上 TestFlight。
- `docs/ios-github-actions/ios-build.yml`：後備 GitHub Actions macOS workflow（**只可以手動撳 Run**，模擬器版、唔簽名）。因為我哋嘅 token 冇 `workflow` 權限，暫時放喺 docs；主人想啟用就喺 GitHub 網頁將佢複製去 `.github/workflows/ios-build.yml`（Add file → Create new file，貼上內容 → Commit）。
- repo 入面**冇**任何金鑰、證書、.p8、profile。

## Info.plist 權限文字
| 權限 | 文字 |
|---|---|
| 位置（使用期間） | 釣港會用你嘅位置，顯示附近釣點、潮汐同天氣，同埋喺你記錄漁獲時標示位置。位置只會喺你使用 App 時讀取。 |
| 相機 | 釣港需要用相機，等你可以影低漁獲相片並上載到你嘅記錄。 |
| 相簿讀取 | 釣港需要讀取你嘅相簿，等你可以揀漁獲相片上載到你嘅記錄。 |
| 相簿寫入 | 釣港需要寫入相簿，等你可以將漁獲相片或分享圖儲存到手機。 |

---

## 主人要自己做嘅步驟（只需 Windows）

### A. 而家就可以做：Codemagic
1. 去 https://codemagic.io 用 **GitHub 登入**，揀 personal（個人）帳戶。
2. 「Add application」→ 揀 GitHub → 授權 `limaking1028/HK-fishing-app`。
3. 揀「codemagic.yaml」做設定方式。
4. （PR merge 之前都可以）揀 branch `ios-capacitor`，手動開始 **`ios-simulator-check`**，睇下會唔會成功。呢步唔使 Apple 帳戶。

### B. Apple 批咗 Developer 之後
1. **App Store Connect → 我的 App → ＋ 新增 App**：平台 iOS、名稱「釣港」、主要語言「中文（香港）」或繁中、Bundle ID 揀 `app.hkfishing.ios`（如冇得揀，先去 developer.apple.com → Identifiers 新增）、SKU 例如 `hkfishing-ios`。
2. 記低 App 資料頁嘅 **Apple ID**（一串數字）→ 交返我哋填入 `codemagic.yaml` 嘅 `APP_STORE_APPLE_ID`（佢唔係秘密）。
3. **App Store Connect → 用戶與存取 → 整合 → App Store Connect API → 新增金鑰**，權限揀「App Manager」。下載 `.p8`（**只可以下載一次**，唔好放入 repo、唔好貼俾任何人）。記低 Issuer ID 同 Key ID。
4. **Codemagic → Teams/Personal settings → Integrations → Developer Portal / App Store Connect → Connect**：名稱填 `HKFISHING_ASC_KEY`，上載 `.p8`、填 Issuer ID 同 Key ID。
5. Codemagic 會用呢條 key **自動整證書同 provisioning profile**（唔使 Mac）。
6. 手動開始 **`ios-testflight`** workflow → 成功後去 App Store Connect → TestFlight，加自己做內部測試員，用 iPhone 裝 TestFlight App 試。
7. 正式送審前要填：私隱網址 `https://limaking1028.github.io/HK-fishing-app/privacy.html`、App 私隱問卷（位置、相片、電郵、用戶 ID）、截圖。

### C. Supabase Dashboard（Auth → URL Configuration）
**iOS 登入修正 PR merge 之前／同時加**（加咗都唔影響網頁版）：
- Redirect URLs 加：`app.hkfishing.ios://auth-callback`（如想保險可以再加 `app.hkfishing.ios://**`）
- Site URL **唔好改**（保持網頁版）。
- Google 登入：**Google Cloud Console 唔使改**。Google 只會返去 Supabase 本身嘅 callback（`https://lucizjohiycxdynrkjus.supabase.co/auth/v1/callback`，已登記），之後由 Supabase 轉去 App scheme，所以只要上面 Supabase 允許清單有就得。

---

## 已知問題／跟進（今次刻意**冇改** index.html 同 lib/，以免影響網頁）
1. **登入 redirect（iOS 登入修正 PR 已處理）**：
   - `lib/auth.js` 加 `isNativeIOS()`：只有 `window.Capacitor.isNativePlatform()` 同 `getPlatform()==='ios'` 先成立。網頁同 Android TWA 冇 `window.Capacitor`，永遠行返舊路（redirect = 網頁網址、supabase-js 預設 `implicit` flow），有單元測試＋Playwright 證明。
   - iOS：magic link／重設密碼／註冊確認信同 Google 登入一律用 `app.hkfishing.ios://auth-callback`；iOS 改用 PKCE（返嚟帶 `?code=`），`appUrlOpen` 收到後 `exchangeCodeForSession`，再關 Browser。
   - Google 登入喺 iOS 用 `@capacitor/browser`（系統 Safari 視窗）開，唔喺 WebView 入面登入。
   - 冇 bundler：插件唔使 import，原生殼會注入 `window.Capacitor`，插件喺 `window.Capacitor.Plugins.App／Browser`；npm 套件只係俾 `pod install` 攞原生碼。
   - 限制：PKCE 電郵連結要喺**同一部 iPhone** 撳先登入到（code verifier 存喺 App 入面）。
2. **Service worker**：WKWebView 喺 `capacitor://` 自訂 scheme 下**唔支援 service worker**，`navigator.serviceWorker` 可能係 undefined 或者 register 失敗。index.html 已有 `.catch`／feature check，唔會壞；而且魚相已經打包喺 App 入面，唔需要 SW 快取。
3. **Apple 審核風險（Guideline 4.2）**：純網頁包殼有機會被拒；送審備註要講清楚 GPS、相機、離線魚圖等原生功能。
4. **網頁更新**：網頁改咗之後，iOS 要重新 build＋上 TestFlight 先會更新。
5. **App icon／啟動畫面**：已換成釣港正式 icon（來源 `store-assets/icon-1024.png`，原生 1024×1024，冇放大；RGB 無透明、方角，圓角由 iOS 自己加）。啟動畫面 2732×2732，深藍底 `#014890` 置中 icon（邊緣柔化）。
6. **Linux 上未能驗證**：`pod install` 同 `xcodebuild` 要 macOS，第一次真 build 要等 Codemagic／GitHub Actions 跑。
