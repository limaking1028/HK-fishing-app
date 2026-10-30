-- v184：改名規則（喺 DB 強制執行，客戶端直接 UPDATE 都繞唔過）
--  • 名字 2–12 個字（trim 後按 Unicode code point 計；一個普通 emoji = 1 個字，組合 emoji 可能算多個）
--  • 唔准撞名（唔分大小寫、去頭尾空白；unique index 兜底）
--  • 每 30 日只可以改一次（第一次自己改名唔使等）
--  • 禁用字：官方、管理員、釣港 同粗口（public.banned_name_words，可以喺 Dashboard 加減）
--  • 每次改名記錄喺 public.user_name_changes，只有管理員可以經 admin_name_changes() 讀
--  • 管理員（public.admins）唔受長度／禁用字／30 日限制，但都唔可以同人撞名
-- 錯誤訊息碼（前端會轉做廣東話）：NAME_TOO_SHORT / NAME_TOO_LONG / NAME_TAKEN / NAME_BANNED / NAME_COOLDOWN:<可改日期 YYYY-MM-DD>

begin;

-- 1) 禁用字表
create table if not exists public.banned_name_words (
  word text primary key check (word = lower(word) and word !~ '\s'),
  note text
);
alter table public.banned_name_words enable row level security;   -- 冇 policy：客戶端讀寫都唔得
revoke all on public.banned_name_words from anon, authenticated;

insert into public.banned_name_words(word, note) values
  ('官方','保留字'),('管理員','保留字'),('管理员','保留字（簡體）'),('釣港','保留字'),('钓港','保留字（簡體）'),
  ('admin','保留字（英文）'),('official','保留字（英文）'),
  ('屌','粗口'),('𨳒','粗口'),('𨳊','粗口'),('撚','粗口'),('𨶙','粗口'),('閪','粗口'),('柒','粗口'),('㞗','粗口'),('鳩','粗口'),('鸠','粗口（簡體）'),
  ('仆街','粗口'),('扑街','粗口'),('冚家','粗口'),('冚家鏟','粗口'),('含家','粗口'),('戇鳩','粗口'),('on9','粗口'),('diu','粗口'),('丟你','粗口'),('丢你','粗口（簡體）'),
  ('頂你個肺','粗口'),('食屎','粗口'),('臭西','粗口'),('死八婆','粗口'),('老味','粗口'),
  ('屄','粗口'),('肏','粗口'),('操你','粗口'),('幹你','粗口'),('干你','粗口（簡體）'),('他媽','粗口'),('他妈','粗口（簡體）'),('媽的','粗口'),('妈的','粗口（簡體）'),
  ('傻逼','粗口'),('傻屄','粗口'),('煞筆','粗口'),('雞巴','粗口'),('鸡巴','粗口（簡體）'),('婊子','粗口'),('賤人','粗口'),('贱人','粗口（簡體）'),
  ('fuck','粗口'),('fuk','粗口'),('shit','粗口'),('bitch','粗口'),('cunt','粗口'),('asshole','粗口'),('wtf','粗口'),('nigger','粗口')
on conflict (word) do nothing;

-- 2) 改名紀錄表
create table if not exists public.user_name_changes (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  old_name text,
  new_name text not null,
  changed_at timestamptz not null default now(),
  changed_by uuid
);
create index if not exists user_name_changes_user_idx on public.user_name_changes (user_id, changed_at desc);
create index if not exists user_name_changes_at_idx on public.user_name_changes (changed_at desc);
alter table public.user_name_changes enable row level security;  -- 冇 policy：只經 admin RPC 讀
revoke all on public.user_name_changes from anon, authenticated;

-- 3) 記錄最後一次自己改名時間（30 日計時用；客戶端改唔到，trigger 會蓋返）
alter table public.users add column if not exists name_changed_at timestamptz;

-- 4) 正規化（全形→半形、細楷、去空白同符號），用嚟對禁用字
create or replace function public.name_norm(p text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select regexp_replace(lower(normalize(coalesce(p,''), NFKC)), '[[:space:][:punct:]_·•・。，、！？~～\-]+', '', 'g')
$$;

create or replace function public.name_has_banned(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.banned_name_words w where strpos(public.name_norm(p), public.name_norm(w.word)) > 0)
$$;
revoke all on function public.name_has_banned(text) from public, anon, authenticated;

-- 5) 主 trigger
create or replace function public.users_name_rules() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new text := btrim(coalesce(new.display_name, ''));
  v_old text := btrim(coalesce(old.display_name, ''));
  v_len int;
  v_actor uuid := auth.uid();
  v_exempt boolean;
  v_next date;
begin
  if tg_op = 'INSERT' then
    -- 新帳戶：預設名（例如「釣友」+電郵前綴）唔合規或者撞名，就自動改做唯一嘅「釣友xxxxxx」，唔會令註冊失敗
    new.name_changed_at := null;
    new.display_name := v_new;
    if char_length(v_new) not between 2 and 12 or public.name_has_banned(v_new)
       or exists (select 1 from public.users u where lower(btrim(u.display_name)) = lower(v_new)) then
      loop
        new.display_name := '釣友' || lpad((floor(random()*1000000))::int::text, 6, '0');
        exit when not exists (select 1 from public.users u where lower(btrim(u.display_name)) = lower(new.display_name));
      end loop;
    end if;
    return new;
  end if;

  -- UPDATE：客戶端唔可以自己改計時欄（只有冇登入身份嘅 Dashboard／service role 可以手動改）
  if v_actor is not null then new.name_changed_at := old.name_changed_at; end if;
  if new.display_name is not distinct from old.display_name then return new; end if;
  if v_new = v_old then new.display_name := old.display_name; return new; end if;

  -- 冇登入身份（Dashboard／service role／內部函數）或者管理員：唔受長度、禁用字、30 日限制
  v_exempt := v_actor is null or exists (select 1 from public.admins a where a.user_id = v_actor);
  v_len := char_length(v_new);
  if not v_exempt then
    if v_len < 2 then raise exception 'NAME_TOO_SHORT' using errcode = 'P0001'; end if;
    if v_len > 12 then raise exception 'NAME_TOO_LONG' using errcode = 'P0001'; end if;
    if public.name_has_banned(v_new) then raise exception 'NAME_BANNED' using errcode = 'P0001'; end if;
  elsif v_len = 0 then
    raise exception 'NAME_TOO_SHORT' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.users u where u.id <> old.id and lower(btrim(u.display_name)) = lower(v_new)) then
    raise exception 'NAME_TAKEN' using errcode = 'P0001';
  end if;
  -- 30 日：第一次自己改名（name_changed_at 係 null）唔使等
  if not v_exempt and old.name_changed_at is not null and old.name_changed_at > now() - interval '30 days' then
    v_next := ((old.name_changed_at + interval '30 days') at time zone 'Asia/Hong_Kong')::date;
    raise exception 'NAME_COOLDOWN:%', v_next using errcode = 'P0001';
  end if;

  new.display_name := v_new;
  -- 原本係空名（第一次設定）唔開始計 30 日
  if v_old <> '' then new.name_changed_at := now(); end if;
  insert into public.user_name_changes(user_id, old_name, new_name, changed_by)
    values (old.id, nullif(old.display_name, ''), v_new, v_actor);
  return new;
end $$;
revoke all on function public.users_name_rules() from public, anon, authenticated;

drop trigger if exists trg_users_name_rules on public.users;
create trigger trg_users_name_rules
  before insert or update of display_name, name_changed_at on public.users
  for each row execute function public.users_name_rules();

-- 6) 唔准撞名（兜底；現有資料已確認冇重複）
create unique index if not exists users_display_name_ci_key on public.users (lower(btrim(display_name)));

-- 7) 管理員讀改名紀錄
create or replace function public.admin_name_changes(p_limit int default 200)
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select json_agg(x order by x.changed_at desc) from (
    select c.id, c.user_id, c.old_name, c.new_name, c.changed_at, c.changed_by,
           (c.changed_by is distinct from c.user_id) as by_other, u.display_name as current_name
    from public.user_name_changes c left join public.users u on u.id = c.user_id
    order by c.changed_at desc limit least(greatest(coalesce(p_limit,200),1),1000)) x), '[]'::json);
end $$;
revoke all on function public.admin_name_changes(int) from public, anon;
grant execute on function public.admin_name_changes(int) to authenticated;

commit;
