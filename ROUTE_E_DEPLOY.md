# Route E 部署清單

## ✅ 已自動完成（沙箱推送）

| # | 任務 | 狀態 |
|---|---|---|
| E1 | 刪除死檔 `app.js` | ✓ 618 行已刪 |
| E2 | 15 張 JPG 搬到 `photos/` | ✓ 全部就位 |
| E2b | `sw.js` CORE 加入 15 張照片 | ✓ 離線可用 |
| E3 | `weight` CHECK 約束（schema 註解） | ✓ 已加 |
| E4 | 修照片上傳 bug（`uploadCatchPhoto` + `dbAddCatch`） | ✓ 已修 |
| E0 | SW bump v18 → v19 | ✓ 已 bump |
| — | git commit + push | ✓ `3a03588` 推送 |

**git log**:
```
3a03588 Route E: 清理債務 + 修照片上傳
```

## ⚠️ 你必須手動做 3 件事（沙箱無權限）

### ① 建立 Supabase Storage bucket
1. 到 Supabase Dashboard → https://lgvdqnyuhraxkffzgrhf.supabase.co
2. 左邊選 **Storage** → **New bucket**
3. 設定：
   - **Name**: `catch-photos`
   - **Public**: ✅ (打勾)
   - **File size limit**: `5242880` (5 MB)
   - **Allowed MIME types**: `image/jpeg, image/png, image/webp`
4. 點 **Create**

### ② 跑 weight CHECK migration
1. Supabase Dashboard → **SQL Editor** → **New query**
2. 貼上 `/workspace/hk-fishing-app/migration-weight-check.sql` 的內容
3. 點 **Run**
4. 預期結果：`constraint_name | weight_sanity` 出現在結果表

### ③ 跑 photo_url migration
1. SQL Editor → **New query**
2. 貼上 `/workspace/hk-fishing-app/migration-photo-url.sql` 的內容
3. 點 **Run**
4. 預期結果：`column_name | photo_url | text | YES`

## 🧪 部署後測試流程

GitHub Pages 會在 ~1 分鐘後自動部署（commit push 已觸發）。

### 網頁檢查
1. 開 https://limaking1028.github.io/HK-fishing-app/
2. **強制刷新**清除 SW 快取（v18 → v19）：
   - Chrome DevTools → Application → Service Workers → **Unregister**
   - 或直接 Ctrl+Shift+R
3. 確認首頁正常載入

### 魚照修復驗證
1. 進入「新增魚獲」
2. 點任一魚種（應見到照片，不是破圖）
3. 確認 15 種魚照片都能看到

### 照片上傳驗證
1. 進入「新增魚獲」→ 填好資料
2. 點「📸 點擊上傳照片」選一張圖
3. 看到預覽 → 提交
4. 進「我的魚獲」確認該筆有縮圖
5. Supabase Dashboard → Storage → catch-photos 應見到新檔
6. Supabase Dashboard → Table Editor → catches → 該筆的 `photo_url` 不再是 NULL

## 🆘 若出問題

| 症狀 | 原因 | 解法 |
|---|---|---|
| 點魚種看到破圖 | SW v19 還沒生效 | DevTools Unregister + Ctrl+Shift+R |
| 提交後「照片上傳失敗：...」 | Storage bucket 沒建 | 補做 ① |
| 提交後 `photo_url` 還是 NULL | bucket 沒設 public | 補做 ①，Storage → bucket → Edit → 勾 Public |
| 跑 weight CHECK 時出錯「constraint already exists」 | 之前已跑過 | 沒事，已存在就不重複加 |
| DB 出現「weight CHECK violation」 | 有現存異常資料 | migration 會先 UPDATE 成 NULL，不會 crash |

## 📂 相關檔案

```
/workspace/hk-fishing-app/
├── index.html              (已修 dbAddCatch + uploadCatchPhoto)
├── sw.js                   (v19, CORE 含 15 張照片)
├── supabase-schema.sql     (weight CHECK 已加)
├── migration-weight-check.sql   (待你跑)
├── migration-photo-url.sql      (待你跑)
├── photos/                 (15 張魚照新位置)
│   ├── 泥鯭.jpg
│   ├── 黑沙鱲.jpg
│   └── ... 共 15 張
└── style.css / manifest.json / apple-touch-icon.png / icon-192.png / icon-512.png
```