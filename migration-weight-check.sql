-- ============================================================
-- Route E - 為 catches.weight 加 CHECK 約束
-- 在 Supabase SQL Editor 貼上並執行
-- ============================================================
-- 背景：原本 weight 完全冇約束，可填負數/0/>=100。Route E 加約束
-- 範圍：weight IS NULL OR (weight > 0 AND weight < 100)（單位：斤）
-- ============================================================

-- 步驟 1：先清掉異常資料（CHECK 加失敗就係呢啲 row）
-- 唔刪 record，淨係將 weight 改 NULL，保留其他欄位做歷史
UPDATE catches
SET weight = NULL
WHERE weight IS NOT NULL AND (weight <= 0 OR weight >= 100);

-- 步驟 2：加 CHECK 約束
ALTER TABLE catches
ADD CONSTRAINT IF NOT EXISTS weight_sanity
CHECK (weight IS NULL OR (weight > 0 AND weight < 100));

-- 步驟 3：驗證
SELECT
  conname  AS constraint_name,
  pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'catches'::regclass
  AND conname = 'weight_sanity';

-- 預期結果：
--   constraint_name | weight_sanity
--   definition      | CHECK (((weight IS NULL) OR ((weight > (0)::numeric) AND (weight < (100)::numeric))))