# Supabase 遷移清單 — isMine 邏輯改造

> 本文件記錄 `index.html` 中所有 `isMine` 的使用位置，以及遷移到 Supabase 後需要怎麼改。
> 產生日期：2026-09-26

---

## 核心原則

所有 `c.isMine` 都會被替換為：

```js
c.user_id === supabase.auth.currentUser.id
```

`isMine` 欄位本身從資料庫中移除，不再儲存，改為查詢時動態判斷。

---

## 資料表設計

### `profiles` 表

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | UUID (PK) | Supabase Auth 用戶 ID |
| username | TEXT | 顯示名稱 |
| created_at | TIMESTAMPTZ | 建立時間 |

### `catches` 表

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | UUID (PK) | 記錄唯一 ID |
| user_id | UUID (FK → profiles.id) | 誰釣到的 |
| species | TEXT | 魚種名 |
| species_icon | TEXT | 魚種 emoji |
| weight | NUMERIC | 重量（斤） |
| length | NUMERIC | 長度 |
| spot | TEXT | 釣點 |
| spot_area | TEXT | 釣點區域 |
| date | DATE | 日期 |
| time | TEXT | 時間 |
| method | TEXT | 釣法 |
| bait | TEXT | 魚餌 |
| photo_url | TEXT | 照片 URL（之後加） |
| verified | BOOLEAN | 是否已驗證 |
| notes | TEXT | 備註 |
| saved_by | UUID (nullable) | 誰收藏的（匯入分享用） |
| share_key | TEXT (nullable) | 分享金鑰 |
| created_at | TIMESTAMPTZ | 建立時間 |

---

## 18 處改動清單

### 場景一：建立記錄時標記身份（2 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 1 | 411 | `isMine: true,` | 刪除此欄位。記錄由 `user_id: currentUser.id` 自動帶出身份 |
| 2 | 315 | `isMine: users[d[0]] === getUserName(),` | 刪除。示範資料直接指定 `user_id` |

---

### 場景二：改名的連鎖更新（2 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 3 | 329 | `state.catches.forEach(c => { if (c.isMine) c.user = name; });` | 刪除整段。改名只 UPDATE `profiles` 表，`catches` 靠 `user_id` 關聯，自然讀到新名 |
| 4 | 338 | `data.forEach(c => { if (c.isMine) c.user = uname; });` | 刪除整段。同上理由 |

> **重點**：改名從「遍歷所有記錄改 user 欄位」→「一條 SQL UPDATE profiles」。這是最大改善。

---

### 場景三：排行榜高亮「我」的記錄（3 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 5 | 653 | `m[c.user] = {...c}`（最大魚聚合，isMine 跟著帶過去） | 聚合後比對 `c.user_id === currentUser.id`，在結果物件上動態標記 `isMine` |
| 6 | 657 | `if (c.isMine) m[c.user].isMine = true;` | `if (c.user_id === currentUser.id) m[c.user].isMine = true;` |
| 7 | 665 | `isMine: u.catches.some(c => c.isMine)` | `isMine: u.catches.some(c => c.user_id === currentUser.id)` |

---

### 場景四：排行榜渲染時顯示「（我）」標記（1 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 8 | 679 | `item.isMine?' mine':''` 和 `item.isMine?' （我）':''` | **不用改**。前端渲染邏輯依賴 `item.isMine`，只要確保上面聚合時正確標記就行 |

---

### 場景五：我的魚獲頁面篩選（2 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 9 | 461 | `state.catches.filter(c => c.isMine)` | Supabase 查詢時直接 `WHERE user_id = currentUser.id`，不用前機篩選 |
| 10 | 694 | `state.catches.filter(c => c.isMine \|\| c.imported)` | 拆成兩次查詢：① `WHERE user_id = me` ② `WHERE saved_by = me`，合併顯示 |

---

### 場景六：個人排名徽章計算 — `getMyCatchRankings()`（4 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 11 | 430 | `const qualify = c => c.verified \|\| c.isMine \|\| c.imported;` | `const qualify = c => c.verified \|\| c.user_id === currentUser.id \|\| c.saved_by === currentUser.id;` |
| 12 | 435 | `if (item.isMine) { ... }`（最大魚排名標記） | `if (item.user_id === currentUser.id) { ... }` |
| 13 | 441 | `const mine = item.catches.filter(c => c.isMine);`（魚種王） | `const mine = item.catches.filter(c => c.user_id === currentUser.id);` |
| 14 | 451 | `const mine = item.catches.filter(c => c.isMine);`（最多魚獲） | 同 #13 |

---

### 場景七：匯入（收藏）別人分享的魚獲（2 處）

| # | 行號 | 原始碼 | 改成 |
|---|------|--------|------|
| 15 | 629 | `isMine: false, imported: true, shareKey: shareData` | `user_id: 分享者的id`（不變）, `saved_by: currentUser.id`, `shareKey: shareData`。不再需要 `isMine` 和 `imported` |
| 16 | 418 | `c.isMine && c.species === speciesName`（解鎖偵測） | `c.user_id === currentUser.id && c.species === speciesName` |

---

## 改造步驟（建議順序）

```
Step 1：建 Supabase 專案 + 兩張表
         ├─ profiles (id, username, created_at)
         └─ catches  (id, user_id, species, weight, ...)
         設好 RLS：用戶只能讀寫自己的 catches

Step 2：加 Supabase Auth
         ├─ 註冊/登入流程（Email 或 OAuth）
         └─ 登入後取得 currentUser.id

Step 3：改 setUserName()
         從遍歷改資料 → 一條 SQL UPDATE profiles

Step 4：改 submitCatch()
         ├─ 刪掉 isMine: true
         └─ INSERT 時帶 user_id = currentUser.id

Step 5：改 getMyCatchRankings() 和 renderLeaderboardView()
         ├─ 4 處 c.isMine → c.user_id === currentUser.id
         └─ 聚合邏輯在 SQL 層做（GROUP BY user_id）

Step 6：改 renderMyView() 和 renderEncyclopediaView()
         ├─ 從 state.catches.filter 改成 Supabase 查詢
         └─ 我的魚獲：WHERE user_id = me
         └─ 收藏的：WHERE saved_by = me

Step 7：改匯入分享邏輯
         ├─ 匯入時寫 saved_by，不寫 isMine
         └─ 分享時只帶原始 user_id，不帶 isMine

Step 8：刪除 STORAGE_KEY 相關的 localStorage 邏輯
         （可保留作離線快取，但資料來源改為 Supabase）
```

---

## 一句話總結

> 18 處改動聽起來多，但**每一處都是同一個模式的替換**：`c.isMine` → `c.user_id === currentUser.id`。真正要重新設計的只有兩件事 —— **改名流程**（從遍歷改一條 SQL）和**匯入分享的資料結構**（加 `saved_by` 欄位）。其餘都是機械式替換。
