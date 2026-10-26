-- v169 秘點：share_catch_get 對「秘點」魚獲只回傳 spot='秘點'、area=null（伺服器端遮蔽，Worker 唔使改）
-- 唔改任何資料；只 CREATE OR REPLACE 一個 function。lat/lng 照留喺 catches（排行榜資格用），本 function 從來唔回傳座標。
-- 街名收埋（主人批准）：spot 只喺官方釣點白名單（index.html FISHING_SPOTS 名＋'其他'）先原樣回傳（「主名（備註）」只回主名）；
-- 其他（GPS 反查街名／用戶自己打嘅名，資料上分唔開）一律回 spot='香港'，area 只有係十八區名先回傳，否則 null。資料本身唔改。
-- 另：anon 對 catches 有 table-level SELECT（RLS 冇 anon policy，實際讀到 0 行）— 收緊做 defence-in-depth。
begin;

create or replace function public.share_catch_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.catches; ranks jsonb; v_secret boolean; v_main text; v_spot text; v_area text;
  c_official constant text[] := array['魚排','碼頭','離島','馬灣','大澳','石澳','大美督','港珠橋墩','流浮山蠔排','其他'];
  c_district constant text[] := array['中西區','灣仔','東區','南區','油尖旺','深水埗','九龍城','黃大仙','觀塘','荃灣','屯門','元朗','北區','大埔','西貢','沙田','葵青','離島'];
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{12}$' then return null; end if;
  select x.* into c from public.catch_shares s join public.catches x on x.id = s.catch_id
   where s.token = p_token and not x.is_test and not x.admin_excluded and x.user_id is not null
     and not public.is_banned(x.user_id);
  if c.id is null then return null; end if;
  v_secret := (c.spot = '秘點' or c.spot like '秘點（%');
  v_main := btrim(split_part(coalesce(c.spot, ''), '（', 1));
  if v_secret then v_spot := '秘點'; v_area := null;
  elsif v_main = any(c_official) then v_spot := v_main; v_area := case when c.spot_area = any(c_district) then c.spot_area end;
  else v_spot := '香港'; v_area := case when c.spot_area = any(c_district) then c.spot_area end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('board', 'biggest', 'period', p.p, 'rank', b.pos) order by p.o), '[]'::jsonb)
    into ranks
    from (values ('all', 1), ('year', 2), ('quarter', 3), ('month', 4)) p(p, o)
    join lateral (select pos from public.lb_biggest(p.p) where catch_id = c.id) b on true;
  return jsonb_build_object('species', c.species, 'icon', c.species_icon, 'weight_kg', c.weight_kg,
                            'spot', v_spot, 'area', v_area,
                            'date', c.date, 'ranks', ranks);
end $$;

revoke select on public.catches from anon;

commit;
