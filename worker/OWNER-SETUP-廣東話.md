# 開 Cloudflare 分享預覽（主人跟住做，大約 10 分鐘）

做完之後，你喺 WhatsApp 分享魚獲連結，對方會見到一張大圖預覽，標題好似「🎣 黑鯛 1.2kg｜今個月第 3 名」。佢撳任何一個位都會直接入 App，唔使開相機掃 QR。

**費用：** 免費 plan 每日有 100,000 次 request，唔使俾錢，亦唔使入信用卡。
官方說明：https://developers.cloudflare.com/workers/platform/pricing/

## 1. 開帳戶（你自己做，密碼同驗證碼唔好俾任何人）
1. 開 https://dash.cloudflare.com/sign-up
2. 輸入你嘅電郵，再自己設一個密碼。
3. 去你個電郵撳確認連結。

## 2. 建立 Worker（唔使裝任何嘢）
1. 登入之後，喺左邊 menu 撳 **Workers & Pages**，再撳 **Create**，然後揀 **Create Worker**（或者「Start with Hello World」）。
2. 名改做 `fishport-share`，再撳 **Deploy**。
3. 撳 **Edit code**，將入面全部 code 刪走，貼上 repo 入面 `worker/src/index.js` 嘅全部內容，再撳 **Deploy**。
4. 返去 Worker 頁，撳 **Settings**，揀 **Variables and Secrets**，然後撳 **Add**，逐個加：
   - `SUPABASE_URL` = `https://lucizjohiycxdynrkjus.supabase.co`
   - `APP_URL` = `https://limaking1028.github.io/HK-fishing-app/`
   - `SUPABASE_ANON_KEY` = Supabase 嘅 anon public key。去 Supabase dashboard，入 Project Settings，再揀 API，抄 **anon public** 嗰條。**唔好抄 service_role！**
   - 加完撳 **Deploy**／**Save**。

## 3. 攞網址
- Worker 頁頂會顯示一條 `https://fishport-share.<你個名>.workers.dev`。
- 自己試吓：喺網址後面加 `/c/abc`，應該會見到「釣港」頁，再自動跳去 App。

## 4. 話俾泥馬王知
- 將條 `https://fishport-share.xxx.workers.dev` 網址傳俾泥馬王。
- 我會將 App 入面嘅 `SHARE_BASE_URL` 改做呢條網址。呢個係 App code 改一行，要開一個細 PR，你批咗先上線。之後分享連結、QR、卡上嘅網址都會用新網址。

## 另一個方法（識用電腦指令先揀）
如果想用指令部署：`cd worker`，`npx wrangler login`，然後 `npx wrangler deploy`。用呢個方法，變數已經寫喺 `wrangler.toml`，唔使再喺 dashboard 填。

## 有問題點算
- 預覽唔出：WhatsApp 會 cache 舊結果，大約要等幾日；或者換一條新連結再試。
- 如果 Worker 壞咗，舊嘅 `?c=` 連結照樣用得，App 唔受影響。

## 更新 Worker 程式碼（v166）

v166 改咗 Worker：預覽標題重量變「605g（1.0 斤）」，預覽圖換成新嘅 og-image-v2.jpg。要喺 Cloudflare 更新一次：

1. 喺 GitHub 打開 `worker/src/index.js`（main 分支），撳「Copy raw file」複製**成個檔案**。
2. 登入 Cloudflare（fishport1028 帳戶）→ 左邊「Workers & Pages」→ 撳 **fishport-share**。
3. 右上角撳「Edit code」。
4. 喺左邊揀 `worker.js`（或 `index.js`），**全選（Ctrl+A）刪晒舊嘢**，再貼上啱啱複製嘅新程式碼。
5. 撳右上角「Deploy」。
6. **變數唔使郁**：SUPABASE_URL、APP_URL、SUPABASE_ANON_KEY 照舊保留，唔好改、唔好刪。
7. 試：用 WhatsApp 分享一條**新**連結，預覽應該見到「🎣 魚種 605g（1.0 斤）」同新嘅圖（有 App 圖示）。

⚠️ 要等 App v166 上線（GitHub Pages 有 og-image-v2.jpg）之後先 Deploy Worker，否則預覽圖會暫時睇唔到。

## 更新 Worker 程式碼（v173：分享連結打開次數）

v173 令 Worker 每次有**真人**打開分享連結，就幫「分享連結打開」個總數 +1（WhatsApp／FB／Telegram 嘅預覽機械人唔計）。只送「事件名」同「來源」（例如 `wa`），**唔送 IP、位置、裝置資料**。連結後面加 `?src=wa`（或 fb／ig／yt／threads／tg／x）就分到來源。

⚠️ **次序好重要**：先等主人批准並套用 v173 migration（有 `track_event`），再 merge v173，最後先更新 Worker。如果 Worker 早咗更新，只係計唔到數，分享連結照用得。

1. 喺 GitHub 打開 `worker/src/index.js`（main 分支），撳「Copy raw file」複製**成個檔案**。
2. 登入 Cloudflare（fishport1028 帳戶）→ 左邊「Workers & Pages」→ 撳 **fishport-share**。
3. 右上角撳「Edit code」。
4. 左邊揀 `worker.js`（或 `index.js`），**全選（Ctrl+A）刪晒舊嘢**，貼上新程式碼。
5. 撳右上角「Deploy」。
6. **變數唔使郁**：SUPABASE_URL、APP_URL、SUPABASE_ANON_KEY 照舊。唔使加新變數，亦**唔好**加 service_role key。
7. 試：用手機瀏覽器開一條分享連結並喺後面加 `?src=wa`（例如 `https://fishport-share.fishport1028.workers.dev/c/xxxxxxxxxxxx?src=wa`），應該照常跳入 App；過一陣入管理後台 →「使用分析」→ 最底「新用戶每日總數」，今日「分享連結打開」應該 +1，來源寫「開·WhatsApp」。

## 更新 Worker 程式碼（v175：預覽字眼）

v175 改咗 Worker 預設預覽描述做「記低每條魚獲、同釣友鬥排行榜。唔使安裝，手機瀏覽器直接用。」，預覽頁多一行同樣字眼。步驟同上面 v173 一樣（複製 main 分支 `worker/src/index.js` 全個檔 → Cloudflare → fishport-share → Edit code → 全選刪晒 → 貼上 → Deploy；變數唔使郁）。**要等 v175 merge 咗先貼。** 未貼之前舊 Worker 照用得。

## v176：預覽描述加「唔使安裝」

- 有效分享連結嘅 WhatsApp／FB 預覽描述，尾句會變成「撳入釣港睇排行榜｜唔使安裝，手機瀏覽器直接用」。
- 釣點名太長會自動截短（加「…」），尾句一定睇到。
- 貼法同之前一樣：複製 main 嘅 worker/src/index.js → Cloudflare fishport-share → Edit code → 全選貼上 → Deploy。
- 還原：貼返 commit 7324608 嘅版本：https://raw.githubusercontent.com/limaking1028/HK-fishing-app/7324608cdb09ac981e832f4fee9f08f5ef054853/worker/src/index.js
