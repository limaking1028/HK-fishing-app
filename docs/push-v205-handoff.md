# 推送第 2 批 v205 交回報告

## 依賴與範圍

- Web：`codex/push-2-web` → `codex/push-1-web`，base `1403acd9d136dcedb14d7088453a94097910442c`，依賴 #73。
- iOS：`codex/push-2-ios` → `codex/settings-page-ios`，base `e1ff4221c03b14b364d89b6e25e5951efd600491`，依賴 #83（執行時遠端最新 head）。
- 兩個疊加 PR 不合併；等待依賴合併後，由泥馬王 retarget。兩邊 app-version／CACHE 均 v205；iOS `photos-v199` 保留。
- 沿用既有 outbox、APNs／VAPID sender、token／prefs；Web 只在 #73 舊 fieldset 加 checkbox，iOS 在 #83 通知卡片加五個 indented switches。
- 未執行任何遠端 SQL、部署、cron、Codemagic、真實推送；沒有 Firebase／Meta SDK、IDFA 或 Android GPS 變更。

## 改檔清單

### Web

- `cron-v205-push-schedule.example.sql`
- `docs/push-v205-handoff.md`
- `migration-v205-push-more-types.sql`
- `supabase/functions/push-schedule/index.test.ts`
- `supabase/functions/push-schedule/index.ts`
- `supabase/functions/push-schedule/migration.test.js`
- `tests/push-prefs.playwright.py`
- `index.html`
- `lib/push.js`
- `supabase/functions/send-push/index.test.ts`
- `supabase/functions/send-push/index.ts`
- `sw.js`
- `tests/admin-manage-admins.playwright.py`
- `tests/push-sw.playwright.py`
- `tests/trip-end-summary.playwright.py`

### iOS

- `docs/screenshots/push-v205-ios-notifications-390.png`
- `tests/push-prefs.playwright.py`
- `index.html`
- `lib/push.js`
- `scripts/ios/transform.js`
- `sw.js`
- `tests/push-sw.playwright.py`
- `tests/score-card-save.playwright.py`
- `tests/settings-page.playwright.py`

## SQL／cron 路徑與資料表

- [migration-v205-push-more-types.sql](../migration-v205-push-more-types.sql)：BEGIN/COMMIT、可重跑；v200 原檔完全不改。
- [cron-v205-push-schedule.example.sql](../cron-v205-push-schedule.example.sql)：只供主人審核的範例，不啟用 extension 或排程。

| 表 | 改動 |
|---|---|
| notification_prefs | 新增五個 NOT NULL DEFAULT true 開關；總開關 enabled 仍 DEFAULT false。 |
| notification_outbox | 七種類型、board 可空、all/month、priority／expires_at／skip_reason；原 unique 及 index 保留。 |
| notification_dedupe | 新增私有主鍵 (user_id,type,dedupe_key)、created_at／meta，FK CASCADE、RLS、只有 service role 可用。 |
| device_tokens | 沿用原表與 enabled 篩選，沒有新增資料收集。 |

### 每個新／替換函數

| 函數 | 說明 |
|---|---|
| `push_type_enabled(prefs,text)` | 逐一對應七種類型的偏好，未知類型回 false。 |
| `push_priority(text)` | 回傳 overtaken → record_broken → trip_open → tide_window → lb_chance → weekly_summary → inactive 的優先次序。 |
| `push_audience(uuid,text)` | 統一檢查總開關、該類型、enabled token、封鎖及測試帳戶排除。 |
| `push_after_quiet(timestamptz)` | 把香港 23:00–07:00 的即時工作延至 07:00。 |
| `push_route_data(jsonb)` | 只保留四種頁面、榜類、all/month、tide 及十二個公開站代號。 |
| `push_enqueue_generic(...)` | 對象篩選後先寫 dedupe，再寫既有 outbox，統一 priority、夜靜與 expiry。 |
| `push_enqueue_one(...) [替換]` | 舊兩種通知沿用原文案及每日每榜去重，改用新偏好／排隊共用規則，v200 原檔未改。 |
| `push_last_seen(uuid)` | 計 usage 日結束、token last_seen_at 與 last_login_at 的最大時間，皆無資料才回退帳戶建立日。 |
| `push_cleanup_dedupe()` | 清理超過 90 日的 dedupe，但仍開啟的 trip 與未重新活躍的 inactive 期間保留。 |
| `push_claim_outbox(integer) [替換]` | 交易 advisory lock 配合每人 window 排序，同批／後續 claim 均最多每日兩個，處理 expiry、配額、退避及舊每日去重。 |
| `push_delivery_allowed(...) [替換]` | 真正發送前重驗 claim、裝置、偏好與 expiry；跨入夜靜的即時 job 改回 pending 至 07:00。 |
| `push_monthly_ranks()` | 清除並還原 auth claims 後沿用既有 lb_* 取得三個月榜私有投影，不更動公開排行榜 API。 |
| `push_schedule_trip_open()` | 對超過六小時未結束行程排一次提醒，以行程 UUID 去重。 |
| `push_schedule_lb_chance()` | 最近 60 日非測試魚獲用戶，依月榜空位／11–20 名接近門檻規則，每人選一榜並每 ISO 週去重。 |
| `push_schedule_weekly()` | 計本週自己的行程／非測試魚獲／魚種，將自己月榜排名與上次 meta 比較，每週一次。 |
| `push_tide_candidates_enqueue(...)` | 在 SQL 用最新行程按關鍵字→最近座標→QUB 選站，套官方／秘點／站名一帶規則，私有座標不回傳。 |
| `push_inactive_enqueue(boolean,text)` | 最後開 app 已滿七日才排週末提醒，同一最後開 app 日期只一次。 |
| `delete_my_account() [原 wrapper 增補]` | 同一個 wrapper 先清 dedupe，再清既有推送資料並呼叫原保留函數，沒有多包一層。 |

所有新內部函數 SECURITY DEFINER、search_path=public，撤銷 PUBLIC／anon／authenticated，只 grant service_role；delete_my_account 保留原 authenticated 自助刪帳權限。

共通政策：香港 23:00–07:00；即時三種遇夜靜或配額超額延至 07:00，排程四種當日 23:00 過期；每日每人所有類型合計兩個，依 priority 分配。已送裝置的部分重試不重複耗新 quota，跨日重試用較新的 claimed_at／sent_at 計算當日預留。

去重：tide:明日日期、lb:ISO年週、trip:行程ID、week:ISO年週、inactive:最後開 app 日期。舊兩種仍保留每日每個榜／魚種一次，包含跨日 backlog 情況。11–20 名的建議數量採「差額 + 1」，避免只追平但被原榜 tie-break 留在前十之外。

### cron 範例換算

| UTC | 香港時間／工作 |
|---|---|
| 每 15 分鐘 | trip_open |
| 星期三 11:00 | 星期三 19:00 lb_chance |
| 星期五 11:20 | 19:20 取週末天氣，排 19:30 inactive |
| 星期日 10:00 | 星期日 18:00 weekly_summary |
| 每日 11:50 | 19:50 取潮汐／HKO，排 20:00 tide_window |
| 每 5 分鐘 | send-push（夜靜只清理／延後，不 claim 發送） |

URL／呼叫 secret 只從 `vault.decrypted_secrets` 的 `PUSH_EDGE_BASE_URL_PLACEHOLDER`／`PUSH_SECRET_PLACEHOLDER` 佔位名稱讀取，沒有任何實際值。

## Edge Function 與 secret 名稱

- 新：`supabase/functions/push-schedule/index.ts`，`job=tide|inactive`，POST＋常數時間 `x-push-secret` 驗證；日後部署需 `--no-verify-jwt`，這次沒有部署。
- 沿用修改：`supabase/functions/send-push/index.ts`，四種 view 的同一組 payload allowlist。
- 新 scheduler 必須：`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`PUSH_SEND_SECRET`。
- 可選公開來源設定：`TIDE_DATA_URL`（預設為文件指定 GitHub Pages 公開 tide-data.json，不是 credential）。
- 既有 sender 另用：`APNS_KEY_P8`、`APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_TOPIC`、`APNS_ENVIRONMENT`、`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT`。

僅使用公開潮汐檔、HKO fnd／warnsum，沒有呼叫 HKO 潮汐 API，沒有新收費服務。來源失敗／缺資料回 200 `{skipped:'source'}`。潮時明確 +08:00，跨年讀 extraYears；低／中低 PSR、最大風力≤5、非62–65、無八號以上／紅黑雨才接受。日潮差≥1m，取06–19時首個高潮，取前兩小時且不早於05時。

## SW diff 證明

兩個 base 的 `CACHE` 第一行以外、`// Push handlers` 之前所有 bytes 完全一致；只有 CACHE 及 push/notificationclick listeners 改動。install／activate／fetch／FISH_PHOTOS 沒有修改；iOS transform 也只改原 CACHE 比對字串，環境相片 cache 名仍 photos-v199。

### web sw.js diff

```diff
diff --git a/sw.js b/sw.js
index 1c207c9..dcb8327 100644
--- a/sw.js
+++ b/sw.js
@@ -1,4 +1,4 @@
-const CACHE = 'hk-fishing-v198';  // v192 跟 App 版本號；v182: 只快取魚種相（WebP），其他請求一律唔掂
+const CACHE = 'hk-fishing-v205';  // v192 跟 App 版本號；v182: 只快取魚種相（WebP），其他請求一律唔掂
 // v180：v102 起 SW 停用（舊版網絡優先快取 index/lib 引起問題）。今次重開，但只處理 photos/*.webp：
 //   install 時 precache 魚種相；fetch 只對魚種相 cache-first；其他請求唔 respondWith，行返瀏覽器正常網絡。
 //   activate 時刪走所有舊 cache（包括 v101–v179 留低嘅）。
@@ -34,24 +34,45 @@ self.addEventListener('fetch', e => {
 self.addEventListener('push', e => {
   e.waitUntil((async () => {
     let p; try { p = e.data.json(); } catch (_) { return; }
-    const board = ['biggest', 'quantity', 'species'].includes(p.data?.lbType) ? p.data.lbType : 'biggest';
-    // Render only server-created text; navigation data has a fixed allowlist.
-    await self.registration.showNotification(String(p.title || '釣港'), {
-      body: String(p.body || ''), data: {view: 'leaderboard', lbType: board, lbPeriod: 'all'}
-    });
+    function pushRoute(data) {
+    data = data || {};
+    const view = ['leaderboard','map','trips','my'].includes(data.view) ? data.view : 'leaderboard';
+    const out = {view};
+    if (view === 'leaderboard') {
+      out.lbType = ['biggest','quantity','species'].includes(data.lbType) ? data.lbType : 'biggest';
+      out.lbPeriod = ['all','month'].includes(data.lbPeriod) ? data.lbPeriod : 'all';
+    } else if (view === 'map') {
+      out.mapTab = 'tide';
+      if (['QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN'].includes(data.station)) out.station = data.station;
+    }
+    return out;
+  }
+    await self.registration.showNotification(String(p.title || '釣港'), {body:String(p.body || ''), data:pushRoute(p.data)});
   })());
 });
 self.addEventListener('notificationclick', e => {
   e.notification.close();
   e.waitUntil((async () => {
-    const board = ['biggest', 'quantity', 'species'].includes(e.notification.data?.lbType) ? e.notification.data.lbType : 'biggest';
+    function pushRoute(data) {
+    data = data || {};
+    const view = ['leaderboard','map','trips','my'].includes(data.view) ? data.view : 'leaderboard';
+    const out = {view};
+    if (view === 'leaderboard') {
+      out.lbType = ['biggest','quantity','species'].includes(data.lbType) ? data.lbType : 'biggest';
+      out.lbPeriod = ['all','month'].includes(data.lbPeriod) ? data.lbPeriod : 'all';
+    } else if (view === 'map') {
+      out.mapTab = 'tide';
+      if (['QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN'].includes(data.station)) out.station = data.station;
+    }
+    return out;
+  }
     const url = new URL('./', self.registration.scope);
-    url.search = new URLSearchParams({view: 'leaderboard', lbType: board, lbPeriod: 'all'}).toString();
-    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
+    url.search = new URLSearchParams(pushRoute(e.notification.data)).toString();
+    const windows = await self.clients.matchAll({type:'window', includeUncontrolled:true});
     const app = windows.find(w => new URL(w.url).origin === url.origin && new URL(w.url).pathname.startsWith(new URL(self.registration.scope).pathname));
     if (app) {
-      try { await app.navigate(url.href); } catch (_) { /* The existing window may still be focusable. */ }
-      try { await app.focus(); return; } catch (_) { /* Closed/unfocusable window: open a new one. */ }
+      try { await app.navigate(url.href); } catch (_) { /* Focus still works when navigation is unavailable. */ }
+      try { await app.focus(); return; } catch (_) { /* Window closed: open another. */ }
     }
     await self.clients.openWindow(url.href);
   })());
```

### ios sw.js diff

```diff
diff --git a/sw.js b/sw.js
index 1bdb9d3..dcb8327 100644
--- a/sw.js
+++ b/sw.js
@@ -1,4 +1,4 @@
-const CACHE = 'hk-fishing-v203';  // v192 跟 App 版本號；v182: 只快取魚種相（WebP），其他請求一律唔掂
+const CACHE = 'hk-fishing-v205';  // v192 跟 App 版本號；v182: 只快取魚種相（WebP），其他請求一律唔掂
 // v180：v102 起 SW 停用（舊版網絡優先快取 index/lib 引起問題）。今次重開，但只處理 photos/*.webp：
 //   install 時 precache 魚種相；fetch 只對魚種相 cache-first；其他請求唔 respondWith，行返瀏覽器正常網絡。
 //   activate 時刪走所有舊 cache（包括 v101–v179 留低嘅）。
@@ -34,24 +34,45 @@ self.addEventListener('fetch', e => {
 self.addEventListener('push', e => {
   e.waitUntil((async () => {
     let p; try { p = e.data.json(); } catch (_) { return; }
-    const board = ['biggest', 'quantity', 'species'].includes(p.data?.lbType) ? p.data.lbType : 'biggest';
-    // Render only server-created text; navigation data has a fixed allowlist.
-    await self.registration.showNotification(String(p.title || '釣港'), {
-      body: String(p.body || ''), data: {view: 'leaderboard', lbType: board, lbPeriod: 'all'}
-    });
+    function pushRoute(data) {
+    data = data || {};
+    const view = ['leaderboard','map','trips','my'].includes(data.view) ? data.view : 'leaderboard';
+    const out = {view};
+    if (view === 'leaderboard') {
+      out.lbType = ['biggest','quantity','species'].includes(data.lbType) ? data.lbType : 'biggest';
+      out.lbPeriod = ['all','month'].includes(data.lbPeriod) ? data.lbPeriod : 'all';
+    } else if (view === 'map') {
+      out.mapTab = 'tide';
+      if (['QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN'].includes(data.station)) out.station = data.station;
+    }
+    return out;
+  }
+    await self.registration.showNotification(String(p.title || '釣港'), {body:String(p.body || ''), data:pushRoute(p.data)});
   })());
 });
 self.addEventListener('notificationclick', e => {
   e.notification.close();
   e.waitUntil((async () => {
-    const board = ['biggest', 'quantity', 'species'].includes(e.notification.data?.lbType) ? e.notification.data.lbType : 'biggest';
+    function pushRoute(data) {
+    data = data || {};
+    const view = ['leaderboard','map','trips','my'].includes(data.view) ? data.view : 'leaderboard';
+    const out = {view};
+    if (view === 'leaderboard') {
+      out.lbType = ['biggest','quantity','species'].includes(data.lbType) ? data.lbType : 'biggest';
+      out.lbPeriod = ['all','month'].includes(data.lbPeriod) ? data.lbPeriod : 'all';
+    } else if (view === 'map') {
+      out.mapTab = 'tide';
+      if (['QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN'].includes(data.station)) out.station = data.station;
+    }
+    return out;
+  }
     const url = new URL('./', self.registration.scope);
-    url.search = new URLSearchParams({view: 'leaderboard', lbType: board, lbPeriod: 'all'}).toString();
-    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
+    url.search = new URLSearchParams(pushRoute(e.notification.data)).toString();
+    const windows = await self.clients.matchAll({type:'window', includeUncontrolled:true});
     const app = windows.find(w => new URL(w.url).origin === url.origin && new URL(w.url).pathname.startsWith(new URL(self.registration.scope).pathname));
     if (app) {
-      try { await app.navigate(url.href); } catch (_) { /* The existing window may still be focusable. */ }
-      try { await app.focus(); return; } catch (_) { /* Closed/unfocusable window: open a new one. */ }
+      try { await app.navigate(url.href); } catch (_) { /* Focus still works when navigation is unavailable. */ }
+      try { await app.focus(); return; } catch (_) { /* Window closed: open another. */ }
     }
     await self.clients.openWindow(url.href);
   })());
```

## 測試結果與限制

- Deno 型別檢查及 12 個 Edge 測試：全部通過（scheduler 6，sender 6，包含原先 5 個 sender 測試）。涵蓋 PSR／風力／警告／雨 icon／小潮／過早高潮、UTC+8、跨年、401、來源失敗及 payload allowlist。
- 新 PGlite v200→v205 整合測試：全部通過；migration 兩次、七種開關、未知類型、同批只拿優先兩個／次批不超額、跨日部分重試配額、每日舊榜去重不浪費第二位、22:30／23:30／06:30、07:00 延後／23:00 expired、trip／inactive／ISO週去重、重新活躍、is_test／excluded／ban／無token、週報自己的統計／排名、三種釣點隱私、最新行程、關鍵字／座標／QUB、上榜兩規則及品種門檻、admin claims 還原、私有 ACL、刪帳保留原行為。
- 原 `send-push/migration.test.js` 未改，單獨驗證 v200 的全部原測試通過；新的夜靜／quota 政策由 v205 整合測試驗證。
- 兩邊 `push-prefs.playwright.py` 通過：新 id／次序／中文、無 prefs 預設七種 true、upsert 齊七 key、總開關 disabled、四 view／冷啟動／prefs 服務失敗仍可導航、SW 站代號 allowlist／未知 view fallback、iOS 360px 無橫向溢位。
- iOS APP_ENV=test 與 prod 各執行 build-ios-web、hkf-build、hkf-ios、tutorial-highlight、push-sw、score-card-save、settings-page、push-prefs，16 次命令全部通過。hkf-build／hkf-ios 自身另覆蓋兩種 generated bundles。其他 UI tests 依既有腳本讀 root source，不假稱是實體 WKWebView 驗證。
- 兩邊 lib/push.js 逐字相同；版本、SW 相片程式不變、JS／diff --check 通過。

### 全套現有測試逐項

#### web

Node 全套：8/8 通過。

- PASS `weather-score-hko.playwright.py`
- PASS `best-record-label.playwright.py`
- PASS `admin-manage-admins.playwright.py`：stale fixture/emoji expectation fixed; product code untouched
- PASS `weather-retry.playwright.py`
- PASS `push-prefs.playwright.py`
- PASS `login-plan-a.playwright.py`
- PASS `trip-end-summary.playwright.py`：stale fixture/emoji expectation fixed; product code untouched
- PASS `push-sw.playwright.py`
- PASS `share-link-base.playwright.py`
- PASS `admin-founder-revoke.playwright.py`
- PASS `species-scroll-weight.playwright.py`
- BASELINE ENV FAIL `guest-tide-weather.playwright.py`：same failure reproduced on unchanged dependency base; live-weather loading timeout
- PASS `weather-503.playwright.py`
#### ios

Node 全套：29/29 通過。

- PASS `hkf-ios.playwright.py`
- PASS `ios-auth-web.playwright.py`
- PASS `weather-score-hko.playwright.py`
- PASS `best-record-label.playwright.py`
- PASS `ios-iphone-only.playwright.py`
- PASS `score-card-save.playwright.py`
- PASS `tutorial-highlight.playwright.py`
- PASS `weather-retry.playwright.py`
- PASS `push-prefs.playwright.py`
- PASS `login-plan-a.playwright.py`
- PASS `settings-page.playwright.py`
- PASS `trip-end-summary.playwright.py`
- PASS `push-sw.playwright.py`
- PASS `share-link-base.playwright.py`
- PASS `admin-founder-revoke.playwright.py`
- PASS `species-scroll-weight.playwright.py`
- BASELINE ENV FAIL `guest-tide-weather.playwright.py`：same failure reproduced on unchanged dependency base; live-weather loading timeout
- PASS `weather-503.playwright.py`

Web 兩個舊測試的 fixture／斷言已修正並重跑通過：admin-manage-admins 的假「缺少函數」訊息改成實際 PostgREST 格式；trip-end-summary 不再要求 base 已移除的🏁。沒有修改 admin.html／行程功能。

`guest-tide-weather` 仍未通過：原測試依賴實時天氣，在等待六秒後還停於 loading，再等 `.weather-card-action` 超時；已在兩個未改的 dependency base 各自重現相同失敗。本批未改天氣頁，依 brief 視為相同 base 環境失敗保留回報；假資料的 weather-retry、weather-503、weather-score-hko 都通過。不宣稱全套零失敗。

所有新 SQL 測試僅記憶體 PGlite、Edge 測試不允許網路、browser backend 請求均阻擋；既有 CDN SDK 用本地副本供應。未測遠端 Postgres 真並行、實際 cron／Vault／HKO 可用性、APNs／Web Push 收件、真機背景喚醒／點擊，原因是本批禁止遠端 SQL、部署及真實憑證；沒有索取或記錄私鑰。

### 重跑新增測試

```sh
deno test --allow-env --allow-read supabase/functions/push-schedule/index.test.ts supabase/functions/send-push/index.test.ts
deno run --allow-read --allow-env supabase/functions/push-schedule/migration.test.js
deno run --allow-read --allow-env supabase/functions/send-push/migration.test.js
python tests/push-prefs.playwright.py
```

## iOS 通知組 390px 截圖（假資料）

使用本地假 profile、prefs 及原生外掛 stub；不是實際帳戶操作或真機推送。圖中的每週小結為測試刻意關閉，其他類型開啟。

![iOS 通知組 390px](https://raw.githubusercontent.com/limaking1028/HK-fishing-app/codex/push-2-ios/docs/screenshots/push-v205-ios-notifications-390.png)
