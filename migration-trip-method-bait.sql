-- Route H+: fishing_trips 表加 method 和 bait 欄位
-- 用於支援行程 picker 同時記錄使用的釣法和釣餌

alter table fishing_trips
  add column if not exists method text,
  add column if not exists bait text;

comment on column fishing_trips.method is '行程使用的釣法（從 FISHING_METHODS 選或自訂）';
comment on column fishing_trips.bait is '行程使用的釣餌（從 BAIT_TYPES 選或自訂）';