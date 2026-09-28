-- ============================================================
-- Route E - 為 catches 加 photo_url 欄位
-- 在 Supabase SQL Editor 貼上並執行
-- ============================================================
-- 背景：原本 UI 有照片上傳 input，但 dbAddCatch() 冇讀，
--       所以全部舊魚獲都冇照片。Route E 補欄位 + 修前端。
-- 新欄：photo_url TEXT（儲 Supabase Storage public URL）
-- 配套：需先建 Storage bucket 'catch-photos' (public)
-- ============================================================

-- 步驟 1：加欄位
ALTER TABLE catches ADD COLUMN IF NOT EXISTS photo_url TEXT;

-- 步驟 2：partial index（只有 photo_url NOT NULL 先納入索引，慳空間）
CREATE INDEX IF NOT EXISTS catches_has_photo_idx
  ON catches(id) WHERE photo_url IS NOT NULL;

-- 步驟 3：驗證
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'catches'
  AND column_name = 'photo_url';

-- 預期結果：
--   column_name | data_type | is_nullable
--   ------------+-----------+------------
--   photo_url   | text      | YES

-- ============================================================
-- ⚠️ 仲要做（手動）:
-- 1. Supabase Dashboard → Storage → New bucket
--    - Name: catch-photos
--    - Public: ✓ (公開讀)
--    - File size limit: 5 MB
--    - Allowed MIME types: image/jpeg, image/png, image/webp
-- 2. Storage → Policies (冇 RLS 的話 default 已可寫，但保險可加 policy)
-- ============================================================