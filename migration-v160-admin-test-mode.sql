-- ============================================================
-- v160：管理員專用「測試模式」
--
-- 主人要求（2026-10-25 18:22 MYT，經泥馬王轉達）：「開發只限管理員嘅測試模式」。細節由泥馬王定：
--   * catches.is_test：只有 is_admin() 帳戶可以設／改（server 端 trigger 檢查，唔信 client）；
--     普通用戶 INSERT is_test=true 或者 UPDATE 改 is_test 一律報錯 'forbidden: is_test'。
--   * 測試魚獲只略過 GPS／香港範圍檢查（no_gps、outside_hk），其他檢查照舊。
--   * 測試魚獲只有管理員睇到喺榜上（lb_weight_cand / lb_countable / lb_user_photo 加條件），
--     所以公眾 lb_biggest、lb_stats、lb_my_rank、讚都唔計；管理員自己睇到（測縮圖、讚、我的排名）。
--   * 後台：待審核列表標「測試」；admin_purge_test_catches() 清走全部（或者單一條）測試魚獲。
-- 冇新增任何 anon 權限。可重複執行。需要先執行 v159。
-- ============================================================

-- 1) 欄位
alter table public.catches add column if not exists is_test boolean not null default false;

-- 2) 上榜判定 trigger（同 v159 一樣，只加：is_test 權限檢查、is_test 改變要重新判定、測試魚獲略過 GPS／香港範圍）
CREATE OR REPLACE FUNCTION public.catches_set_eligibility()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  ref_date date;
  lim      numeric;
  reason   text;
begin
  -- v159：磅／尺相路徑只可以係自己嘅 catch-proof/<user_id>/ 資料夾（任何 INSERT / UPDATE 都檢查）
  if new.proof_path is not null and (
       new.user_id is null
       or new.proof_path !~ ('^' || new.user_id::text || '/[A-Za-z0-9._-]+$')
       or position('..' in new.proof_path) > 0) then
    raise exception 'invalid proof_path';
  end if;

  -- admin_excluded 只有管理員（或 SQL Editor）可以改
  if TG_OP = 'INSERT' then
    new.admin_excluded := false;
  elsif auth.uid() is not null and not public.is_admin() then
    new.admin_excluded := old.admin_excluded;
  end if;

  -- v160：is_test 只有管理員（或 SQL Editor）可以設／改；普通用戶試圖設就報錯
  if auth.uid() is not null and not public.is_admin() then
    if (TG_OP = 'INSERT' and new.is_test)
       or (TG_OP = 'UPDATE' and new.is_test is distinct from old.is_test) then
      raise exception 'forbidden: is_test';
    end if;
  end if;

  -- UPDATE：只有關鍵欄位改變先重新判定，否則保留原判定（防止用戶自行改 verified / eligible）
  if TG_OP = 'UPDATE' then
    if new.photo_url is not distinct from old.photo_url
       and new.photo_age_sec is not distinct from old.photo_age_sec
       and new.latitude is not distinct from old.latitude
       and new.longitude is not distinct from old.longitude
       and new.date is not distinct from old.date
       and new.species is not distinct from old.species
       and new.weight_kg is not distinct from old.weight_kg
       and new.photo_hash is not distinct from old.photo_hash
       and new.admin_excluded is not distinct from old.admin_excluded
       and new.is_test is not distinct from old.is_test
       and new.user_id is not distinct from old.user_id then
      new.leaderboard_eligible := old.leaderboard_eligible;
      new.ineligible_reason    := old.ineligible_reason;
      new.verified             := old.verified;
      return new;
    end if;
    ref_date := (old.created_at at time zone 'Asia/Hong_Kong')::date;   -- 以建立當日計，避免日子過咗先失效
  else
    ref_date := (now() at time zone 'Asia/Hong_Kong')::date;
  end if;

  if new.admin_excluded then
    reason := 'admin_excluded';
  elsif new.user_id is null then
    reason := 'demo';
  elsif new.photo_url is null or new.photo_url = '' then
    reason := 'no_photo';
  elsif position('/catch-photos/' || new.user_id::text || '/' in new.photo_url) = 0 then
    reason := 'photo_invalid';
  elsif new.photo_hash is null or new.photo_hash = '' then
    reason := 'photo_invalid';
  elsif exists (select 1 from public.catches o
                 where o.photo_hash = new.photo_hash and o.id is distinct from new.id) then
    reason := 'photo_duplicate';
  elsif new.photo_age_sec is null or new.photo_age_sec > 1800 or new.photo_age_sec < -60 then
    reason := 'photo_not_fresh';
  elsif not new.is_test and (new.latitude is null or new.longitude is null) then   -- v160：測試魚獲略過
    reason := 'no_gps';
  elsif not new.is_test and not (new.latitude between 22.15 and 22.56 and new.longitude between 113.85 and 114.45) then
    reason := 'outside_hk';
  elsif new.date > ref_date then
    reason := 'date_future';
  elsif new.date < ref_date - 7 then
    reason := 'date_old';
  else
    select max_kg into lim from public.species_limits where species = new.species;
    if lim is null then
      reason := 'species_not_listed';
    elsif new.weight_kg is null then
      reason := 'weight_too_high';
    elsif new.weight_kg <= 0 then
      reason := 'weight_invalid';                                    -- v159：0 或負數重量唔計
    end if;
    -- v159：超過 species_limits.max_kg 唔再自動拒絕，只喺後台審核清單標記「超重」
  end if;

  new.leaderboard_eligible := (reason is null);
  new.ineligible_reason    := reason;
  new.verified             := (reason is null);
  return new;
end;
$$;

-- 3) 重量王者候選：測試魚獲只有管理員睇到（其餘同 v159）
--    lb_pending_ids / lb_biggest / lb_my_rank / 讚檢查全部經呢度，所以公眾一律唔計測試魚獲
create or replace function public.lb_weight_cand()
returns table (id uuid, user_id uuid, species text, weight_kg numeric, date date, created_at timestamptz, ok boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.user_id, c.species, c.weight_kg, c.date, c.created_at,
         exists (select 1 from public.lb_catch_approval a
                  where a.catch_id = c.id and a.species = c.species and a.weight_kg = c.weight_kg
                    and a.proof_path = c.proof_path and a.photo_url is not distinct from c.photo_url) as ok
    from public.catches c
   where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
     and c.proof_path is not null
     and (not c.is_test or public.is_admin());
$$;
revoke all on function public.lb_weight_cand() from public, anon, authenticated;

-- 4) 數量／品種王者可計魚獲（view，欄位不變）：測試魚獲只有管理員睇到
--    lb_stats_rows / lb_stats / lb_my_rank / lb_review_queue / lb_user_photo / 讚檢查全部經呢度
create or replace view public.lb_countable as
 SELECT c.id, c.user_id, c.trip_id, c.species, c.spot, c.weight_kg, c.date, c.created_at
   FROM (catches c
     JOIN fishing_trips t ON (((t.id = c.trip_id) AND (t.user_id = c.user_id))))
  WHERE (c.leaderboard_eligible AND (c.user_id IS NOT NULL) AND (NOT is_banned(c.user_id)) AND (c.created_at >= t.started_at) AND ((t.ended_at IS NULL) OR (c.created_at <= (t.ended_at + '00:10:00'::interval))))
    AND ((NOT c.is_test) OR is_admin());

-- 5) 代表相：用戶揀咗測試魚獲做代表相，公眾唔顯示（退回非測試魚獲）
create or replace function public.lb_user_photo(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.photo_url from public.lb_rep_photo r join public.catches c on c.id = r.catch_id
      where r.user_id = p_user and c.user_id = p_user and not c.admin_excluded
        and (not c.is_test or public.is_admin())
        and position('/catch-photos/' || p_user::text || '/' in coalesce(c.photo_url, '')) > 0),
    (select c.photo_url from public.lb_countable lc join public.catches c on c.id = lc.id
      left join public.species_limits sl on sl.species = c.species
      where c.user_id = p_user and position('/catch-photos/' || p_user::text || '/' in coalesce(c.photo_url, '')) > 0
        and (sl.max_kg is null or c.weight_kg <= sl.max_kg
             or exists (select 1 from public.lb_catch_approval a where a.catch_id = c.id and a.weight_kg = c.weight_kg))
      order by c.weight_kg desc nulls last, c.created_at desc limit 1));
$$;
revoke all on function public.lb_user_photo(uuid) from public, anon, authenticated;

-- 6) 後台待審核列表：多回傳 is_test（後台標「測試」）
create or replace function public.admin_lb_pending()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
           'id', c.id, 'photo_url', c.photo_url, 'proof_path', c.proof_path,
           'species', c.species, 'weight_kg', c.weight_kg, 'max_kg', s.max_kg,
           'over_limit', (s.max_kg is not null and c.weight_kg > s.max_kg),
           'is_test', c.is_test,
           'date', c.date, 'created_at', c.created_at, 'user_id', c.user_id, 'display_name', u.display_name)
           order by c.created_at)
    from public.catches c
    left join public.users u on u.id = c.user_id
    left join public.species_limits s on s.species = c.species
   where c.id in (select public.lb_pending_ids())), '[]'::jsonb);
end $$;
revoke all on function public.admin_lb_pending() from public, anon;
grant execute on function public.admin_lb_pending() to authenticated;

-- 7) 後台：清走測試魚獲（p_catch = null → 全部；否則只刪嗰一條，而且一定要係測試魚獲）
--    批准（lb_catch_approval）同代表相（lb_rep_photo）跟 FK on delete cascade；指向該魚獲嘅讚喺度刪。
--    回傳被刪魚獲嘅 user_id / photo_url / proof_path，俾後台用 Storage API 刪相檔（SQL 刪唔到實際檔案）。
create or replace function public.admin_purge_test_catches(p_catch uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb; n int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_catch is not null and not exists (select 1 from public.catches where id = p_catch and is_test) then
    raise exception 'not a test catch';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'user_id', user_id, 'photo_url', photo_url, 'proof_path', proof_path)), '[]'::jsonb)
    into v from public.catches where is_test and (p_catch is null or id = p_catch);
  delete from public.lb_likes where board = 'biggest'
     and target in (select id from public.catches where is_test and (p_catch is null or id = p_catch));
  delete from public.catches where is_test and (p_catch is null or id = p_catch);
  get diagnostics n = row_count;
  perform public.admin_log('purge_test_catches', 'catch', coalesce(p_catch::text, 'all'), jsonb_build_object('count', n));
  return v;
end $$;
revoke all on function public.admin_purge_test_catches(uuid) from public, anon;
grant execute on function public.admin_purge_test_catches(uuid) to authenticated;
