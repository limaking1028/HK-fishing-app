-- ============================================================
-- 為 catches 表新增 GPS 欄位
-- 在 Supabase SQL Editor 貼上並執行
-- ============================================================

ALTER TABLE catches
ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION,
ADD COLUMN IF NOT EXISTS location_accuracy REAL,
ADD COLUMN IF NOT EXISTS location_source TEXT DEFAULT 'gps';

-- 索引（加速地圖查詢）
CREATE INDEX IF NOT EXISTS catches_lat_lng_idx
ON catches(latitude, longitude)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- 驗證
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'catches'
  AND column_name IN ('latitude', 'longitude', 'location_accuracy', 'location_source')
ORDER BY column_name;