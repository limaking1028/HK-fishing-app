-- ============================================================
-- Route E 補丁 — Supabase Storage catch-photos bucket 寫入權限
-- 在 Supabase SQL Editor 貼上並執行（只需跑一次）
-- ============================================================
-- 背景：
--   Supabase Storage 嘅 public bucket 只開放「公開讀」。
--   寫入 (INSERT/UPDATE/DELETE) 仍需要 RLS policy。
--   我哋用嘅係 anon key（PIN auth 係 client-side 自訂），
--   所以要明確授權 anon role 對 catch-photos 嘅寫入。
--
-- 觸發時機：
--   用戶新增魚獲 → 上傳照片 → Storage 回 'new row violates
--   row-level security policy'。跑呢個 SQL 就解決。
-- ============================================================

-- INSERT：允許 anon 上傳照片到 catch-photos
CREATE POLICY "anon upload catch photos"
ON storage.objects
FOR INSERT
TO anon
WITH CHECK (bucket_id = 'catch-photos');

-- UPDATE：允許 anon 更新（之後維護可能需要）
CREATE POLICY "anon update catch photos"
ON storage.objects
FOR UPDATE
TO anon
USING (bucket_id = 'catch-photos');

-- DELETE：允許 anon 刪除（讓用戶能撤銷自己上傳的照片）
CREATE POLICY "anon delete catch photos"
ON storage.objects
FOR DELETE
TO anon
USING (bucket_id = 'catch-photos');

-- 驗證（應該見到 3 條 policy）
SELECT policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'storage'
  AND tablename = 'objects'
  AND policyname LIKE '%catch photos%';

-- 預期結果：
--   policyname                | cmd    | roles
--   --------------------------+--------+-------
--   anon upload catch photos  | INSERT | {anon}
--   anon update catch photos  | UPDATE | {anon}
--   anon delete catch photos  | DELETE | {anon}