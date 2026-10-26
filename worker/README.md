# fishport-share — 釣港分享連結預覽 Worker（v164）

`GET /c/<token>` 會回傳一頁有 og:title、og:description、og:image 嘅 HTML，等 WhatsApp、Facebook、Telegram 出大圖預覽，然後即刻跳去 `APP_URL?c=<token>`。meta refresh、JS 同一條可以撳嘅連結三樣都有做。

- **資料來源：** 只會用 anon key call 公開 RPC `share_catch_get`。回傳嘅欄位只有魚種、重量、釣點／地區、日期、排行榜名次。冇用戶名、GPS、備註、相。所有文字都做咗 HTML escape。
- **og:image：** 用 App 嘅通用圖 `APP_URL/og-image.jpg`（1200×630 JPEG）。
- **token 格式唔啱、搵唔到 token、Supabase 出錯：** 一律出通用預覽，跳去 App 主頁（fail open）。
- **Cache：** `Cache-Control: public, max-age=300`。
- **UA：** 唔分 UA，bot 同真人都收到同一頁 HTML。

## 設定（`wrangler.toml` 嘅 `[vars]`）
| 變數 | 值 |
|---|---|
| `SUPABASE_URL` | `https://lucizjohiycxdynrkjus.supabase.co` |
| `APP_URL` | `https://limaking1028.github.io/HK-fishing-app/` |
| `SUPABASE_ANON_KEY` | Supabase 嘅 **anon（公開）key**，即係 `index.html` 入面 `SB_KEY` 嗰條。佢本身已經喺網站公開，所以放喺 vars 冇問題。**永遠唔好放 service_role key。** |

冇 commit `account_id`。用 wrangler 嘅話，佢會叫你登入，自動揀你個帳戶。

## Deploy
**方法 A（唔使裝任何嘢）：** 跟 `OWNER-SETUP-廣東話.md` 做，喺 Cloudflare dashboard 建立 Worker，貼上 `src/index.js`，再填 3 個變數。

**方法 B（用 wrangler）：**
```
cd worker
npx wrangler login
npx wrangler deploy
```
部署完會得到 `https://fishport-share.<你個帳戶子網域>.workers.dev`。

## 部署後點樣接駁 App
將 `index.html` 入面 `const SHARE_BASE_URL = '';` 改做 Worker 網址，例如 `'https://fishport-share.xxx.workers.dev'`。呢個改動要開一個 PR 再上線，咁樣分享連結、QR、卡上嘅文字就會一齊變做 `<worker>/c/<token>`。

## 測試
用 Node 20 跑 `node test.mjs mock`，佢會用內置 Request/Response 同 mock 嘅 Supabase。
