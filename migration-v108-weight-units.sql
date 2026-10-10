-- ============================================================
-- v108：重量支援 克 / 公斤 / 斤 / 兩
--   weight_kg    標準重量（公斤，精確到克）→ 排行榜排序用
--   weight_input 用戶輸入嘅原始數值
--   weight_unit  原始單位：g | kg | jin | tael
--   weight       （舊欄位，保留）= 斤，由 App 同步寫入，令舊版仍然可用
-- 可重複執行（idempotent）。請在 Supabase SQL Editor 執行。
-- ============================================================

alter table public.catches add column if not exists weight_kg    numeric(8,3);
alter table public.catches add column if not exists weight_input numeric(12,3);
alter table public.catches add column if not exists weight_unit  text;

-- 舊資料：原本單位係斤（1 斤 = 604.79 克）
update public.catches
   set weight_kg    = round(weight * 0.60479, 3),
       weight_input = weight,
       weight_unit  = 'jin'
 where weight_kg is null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'catches_weight_unit_check') then
    alter table public.catches add constraint catches_weight_unit_check
      check (weight_unit is null or weight_unit in ('g','kg','jin','tael'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'catches_weight_kg_check') then
    alter table public.catches add constraint catches_weight_kg_check
      check (weight_kg is null or (weight_kg > 0 and weight_kg < 61));
  end if;
end $$;

create index if not exists catches_weight_kg_idx on public.catches (weight_kg desc);

-- 行程總重量快取：同樣加公斤欄位
alter table public.fishing_trips add column if not exists total_weight_kg numeric(10,3);
update public.fishing_trips
   set total_weight_kg = round(coalesce(total_weight, 0) * 0.60479, 3)
 where total_weight_kg is null;
