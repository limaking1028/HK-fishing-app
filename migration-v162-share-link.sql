-- ============================================================
-- v162：分享私隱修正 — 短連結 ?c=<token>，由伺服器讀真數據
--
-- 主人批准（2026-10-26 08:51 MYT，經泥馬王）：「批准：先修分享私隱問題，跟住做成績卡同 WhatsApp 一揀分享（只開 PR，上線再問我）」
-- 設計（App 經理定）：
--   * catch_shares：token（12 字元隨機，72 bit，唔可以估／逐個試）→ catch_id。用戶撳「分享」先建立（自己魚獲先得）。
--     表冇任何 anon / authenticated 權限，只經以下兩個 SECURITY DEFINER RPC。
--   * share_catch_create(p_catch)：authenticated；只可以分享自己、非測試、未被排除嘅魚獲；同一條魚獲重用同一個 token。
--   * share_catch_get(p_token)：唯一新增 anon 權限（未登入嘅朋友都要睇到）。只回傳：魚種、icon、重量、釣點名、地區、日期、
--     同伺服器計嘅重量王者名次（只計已批准、公開頭 10 名）。唔回傳 user id、顯示名、GPS、備註、相、釣法魚餌。
--     測試魚獲、被排除、已停用帳戶、搵唔到 → 回傳 null（同樣結果，分唔到原因）。
-- 可重複執行。需要先執行 v160。
-- ============================================================

create table if not exists public.catch_shares (
  token      text primary key check (token ~ '^[A-Za-z0-9_-]{12}$'),
  catch_id   uuid not null unique references public.catches(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.catch_shares enable row level security;
revoke all on public.catch_shares from public, anon, authenticated;

create or replace function public.share_catch_create(p_catch uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.catches c
                  where c.id = p_catch and c.user_id = auth.uid() and not c.is_test and not c.admin_excluded) then
    raise exception 'not shareable';
  end if;
  select token into t from public.catch_shares where catch_id = p_catch;
  if t is not null then return t; end if;
  loop
    t := translate(encode(gen_random_bytes(9), 'base64'), '+/', '-_');
    begin
      insert into public.catch_shares (token, catch_id) values (t, p_catch);
      return t;
    exception when unique_violation then
      select token into t from public.catch_shares where catch_id = p_catch;   -- 同時撳兩次
      if t is not null then return t; end if;
    end;
  end loop;
end $$;
revoke all on function public.share_catch_create(uuid) from public, anon;
grant execute on function public.share_catch_create(uuid) to authenticated;

create or replace function public.share_catch_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.catches; ranks jsonb;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{12}$' then return null; end if;
  select x.* into c from public.catch_shares s join public.catches x on x.id = s.catch_id
   where s.token = p_token and not x.is_test and not x.admin_excluded and x.user_id is not null
     and not public.is_banned(x.user_id);
  if c.id is null then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('board', 'biggest', 'period', p.p, 'rank', b.pos) order by p.o), '[]'::jsonb)
    into ranks
    from (values ('all', 1), ('year', 2), ('quarter', 3), ('month', 4)) p(p, o)
    join lateral (select pos from public.lb_biggest(p.p) where catch_id = c.id) b on true;
  return jsonb_build_object('species', c.species, 'icon', c.species_icon, 'weight_kg', c.weight_kg,
                            'spot', c.spot, 'area', nullif(c.spot_area, ''), 'date', c.date, 'ranks', ranks);
end $$;
revoke all on function public.share_catch_get(text) from public;
grant execute on function public.share_catch_get(text) to anon, authenticated;
