-- v182：由魚種列表刪走「牛屎鱲」（未 apply，要主人批准先跑）
-- 影響：之後新記錄嘅牛屎鱲魚獲會被 catches_set_eligibility 標做 species_not_listed（唔入排行榜）。
-- 現有牛屎鱲魚獲唔會自動改；只有當佢哋嘅關鍵欄位（相、GPS、日期、魚種、重量等）被更新時先會重新判定。
-- lb_stats_rows / lb_user_photo 用 left join species_limits，冇上限時唔做超重過濾，唔會出錯。
-- 還原：insert into public.species_limits (species, max_kg) values ('牛屎鱲', 3);
delete from public.species_limits where species = '牛屎鱲';
