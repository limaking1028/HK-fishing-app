-- v169 秘點：share_catch_get 對「秘點」魚獲只回傳 spot='秘點'、area=null（伺服器端遮蔽，Worker 唔使改）
-- 唔改任何資料；只 CREATE OR REPLACE 一個 function。lat/lng 照留喺 catches（排行榜資格用），本 function 從來唔回傳座標。
-- 另：anon 對 catches 有 table-level SELECT（RLS 冇 anon policy，實際讀到 0 行）— 收緊做 defence-in-depth。
begin;

create or replace function public.share_catch_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.catches; ranks jsonb; v_secret boolean;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{12}$' then return null; end if;
  select x.* into c from public.catch_shares s join public.catches x on x.id = s.catch_id
   where s.token = p_token and not x.is_test and not x.admin_excluded and x.user_id is not null
     and not public.is_banned(x.user_id);
  if c.id is null then return null; end if;
  v_secret := (c.spot = '秘點' or c.spot like '秘點（%');
  select coalesce(jsonb_agg(jsonb_build_object('board', 'biggest', 'period', p.p, 'rank', b.pos) order by p.o), '[]'::jsonb)
    into ranks
    from (values ('all', 1), ('year', 2), ('quarter', 3), ('month', 4)) p(p, o)
    join lateral (select pos from public.lb_biggest(p.p) where catch_id = c.id) b on true;
  return jsonb_build_object('species', c.species, 'icon', c.species_icon, 'weight_kg', c.weight_kg,
                            'spot', case when v_secret then '秘點' else c.spot end,
                            'area', case when v_secret then null else nullif(c.spot_area, '') end,
                            'date', c.date, 'ranks', ranks);
end $$;

revoke select on public.catches from anon;

commit;
