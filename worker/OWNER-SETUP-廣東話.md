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
