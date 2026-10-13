-- ============================================================
-- migration-v149：每個用戶同一時間只可以有一個「未結束」行程（資料庫層保證）
--
-- 背景：App 之前可以喺有未結束行程嘅情況下再開新行程（例如本機記錄唔見咗、
--       換機、或者結束失敗），令資料庫入面留低多個未結束行程。
--
-- 1) 先處理舊資料：同一個用戶如果有多過一個未結束行程，只保留最新嗰個，
--    其餘自動結束（結束時間 = 開始時間，備註註明係系統自動結束）。
-- 2) 建立 partial unique index：之後同一用戶只可以有一個 ended_at 係 null 嘅行程。
--    示範行程（user_id is null）唔受影響。
--
-- 可重複執行。需要先執行 v107（fishing_trips 同 RLS）。
-- ============================================================

begin;

-- 1) 收埋舊資料多出嚟嘅未結束行程（每用戶只保留最新一個）
with ranked as (
  select id,
         row_number() over (partition by user_id order by started_at desc, id desc) as rn
    from public.fishing_trips
   where user_id is not null and ended_at is null
)
update public.fishing_trips t
   set ended_at = t.started_at,
       notes = case when coalesce(t.notes, '') = ''
                    then '（系統自動結束：舊版本未有記錄結束時間）'
                    else t.notes || ' （系統自動結束：舊版本未有記錄結束時間）' end
  from ranked r
 where r.id = t.id and r.rn > 1;

-- 2) 之後每個用戶只可以有一個未結束行程
create unique index if not exists fishing_trips_one_open_per_user
  on public.fishing_trips (user_id)
  where ended_at is null and user_id is not null;

commit;

-- ---------- 驗證 ----------
-- select user_id, count(*) from public.fishing_trips
--  where ended_at is null and user_id is not null group by user_id having count(*) > 1;   -- 應該冇結果
-- select indexname from pg_indexes where tablename = 'fishing_trips' and indexname = 'fishing_trips_one_open_per_user';
