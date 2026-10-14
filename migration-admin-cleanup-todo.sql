-- ============================================================
-- 管理後台：測試數據清理 + 上架待辦
--
--   1. admin_user_stats(p_user)              查看某帳戶嘅魚獲／行程數量（清理前預覽）
--   2. admin_set_user_excluded(...)          將某帳戶全部魚獲移出／恢復排行榜（建議先用呢個）
--   3. admin_delete_user_records(...)        永久刪除某帳戶全部魚獲同行程（要輸入 DELETE；唔會刪帳戶）
--   4. launch_todos 表 + admin_todo_list / admin_todo_save / admin_todo_delete
--
-- 所有函數都先檢查 is_admin()；刪除動作會寫入 admin_audit。
-- 需要先執行 v112（admins／is_admin／admin_log）同 v139。
-- 可重複執行。
-- ============================================================

-- ===== 1. 用戶數據統計（預覽用）=====
create or replace function public.admin_user_stats(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'user_id',        p_user,
    'display_name',   (select display_name from public.users where id = p_user),
    'is_admin',       exists (select 1 from public.admins where user_id = p_user),
    'catch_count',    (select count(*) from public.catches where user_id = p_user),
    'excluded_count', (select count(*) from public.catches where user_id = p_user and admin_excluded),
    'trip_count',     (select count(*) from public.fishing_trips where user_id = p_user),
    'open_trip_count',(select count(*) from public.fishing_trips where user_id = p_user and ended_at is null),
    'first_catch_at', (select min(created_at) from public.catches where user_id = p_user),
    'last_catch_at',  (select max(created_at) from public.catches where user_id = p_user)
  );
end $$;

-- ===== 2. 整體排除／恢復排行榜（唔刪數據）=====
create or replace function public.admin_set_user_excluded(p_user uuid, p_excluded boolean, p_reason text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.catches
     set admin_excluded = p_excluded
   where user_id = p_user and admin_excluded is distinct from p_excluded;
  get diagnostics n = row_count;
  perform public.admin_log(
    case when p_excluded then 'exclude_user_catches' else 'restore_user_catches' end,
    'user', p_user::text,
    jsonb_build_object('count', n, 'reason', nullif(left(coalesce(p_reason, ''), 200), '')));
  return n;
end $$;

-- ===== 3. 永久刪除某用戶嘅魚獲同行程（不可復原；帳戶保留）=====
create or replace function public.admin_delete_user_records(p_user uuid, p_confirm text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare nc integer; nt integer;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_confirm is distinct from 'DELETE' then raise exception 'confirm_required'; end if;
  if exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'cannot delete admin records';
  end if;

  -- 先清理排行榜審核紀錄（依附於行程）
  delete from public.lb_review
   where trip_id in (select id from public.fishing_trips where user_id = p_user);

  delete from public.catches where user_id = p_user;
  get diagnostics nc = row_count;

  delete from public.fishing_trips where user_id = p_user;
  get diagnostics nt = row_count;

  perform public.admin_log('delete_user_records', 'user', p_user::text,
    jsonb_build_object('catches', nc, 'trips', nt,
                       'reason', nullif(left(coalesce(p_reason, ''), 200), '')));

  return jsonb_build_object('catches', nc, 'trips', nt);
end $$;

-- ===== 4. 上架待辦 =====
create table if not exists public.launch_todos (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 200),
  status      text not null default 'todo' check (status in ('todo', 'doing', 'done')),
  note        text check (note is null or char_length(note) <= 1000),
  due_date    date,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.launch_todos enable row level security;   -- 無 policy，只可經函數存取
revoke all on public.launch_todos from anon, authenticated;

create or replace function public.admin_todo_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(t) order by t.sort_order, t.created_at)
      from public.launch_todos t
  ), '[]'::jsonb);
end $$;

-- p_id 為空 = 新增（需要 p_title）；p_id 有值 = 只更新非空欄位
create or replace function public.admin_todo_save(
  p_id     uuid default null,
  p_title  text default null,
  p_status text default null,
  p_note   text default null,
  p_due    date default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.launch_todos;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status is not null and p_status not in ('todo', 'doing', 'done') then
    raise exception 'invalid_status';
  end if;

  if p_id is null then
    if p_title is null or btrim(p_title) = '' then raise exception 'title_required'; end if;
    insert into public.launch_todos (title, status, note, due_date, sort_order)
    values (left(btrim(p_title), 200), coalesce(p_status, 'todo'), left(p_note, 1000), p_due,
            coalesce((select max(sort_order) + 1 from public.launch_todos), 0))
    returning * into r;
  else
    update public.launch_todos
       set title      = coalesce(left(btrim(p_title), 200), title),
           status     = coalesce(p_status, status),
           note       = coalesce(left(p_note, 1000), note),
           due_date   = coalesce(p_due, due_date),
           updated_at = now()
     where id = p_id
    returning * into r;
    if r.id is null then raise exception 'not_found'; end if;
  end if;

  return to_jsonb(r);
end $$;

create or replace function public.admin_todo_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from public.launch_todos where id = p_id;
end $$;

-- 初始待辦（重複執行唔會重複加入）
insert into public.launch_todos (title, status, sort_order)
select v.title, v.status, v.ord
  from (values
    ('填入 upload key 指紋到 assetlinks.json', 'done', 1),
    ('生成 keystore 並打包 AAB', 'done', 2),
    ('完成 Google Cloud OAuth 設定', 'done', 3),
    ('更新 GOOGLE_PLAY_DEPLOY.md 與 privacy.html', 'done', 4),
    ('更換 keystore 同 key 密碼（已曝光）', 'todo', 5),
    ('備份 Supabase 相關表格為 CSV', 'todo', 6),
    ('清理測試數據（排行榜、魚獲、行程、回饋）', 'todo', 7),
    ('清理手機 Chrome 網站數據', 'todo', 8),
    ('建立 App 存取權測試帳號並加入範例數據', 'todo', 9),
    ('完成 Play 開發者帳戶身份驗證（上傳證件）', 'doing', 10),
    ('驗證 Android 流動裝置（需要 Android 手機）', 'todo', 11),
    ('驗證聯絡電話', 'todo', 12),
    ('建立 Play 應用程式並填寫商店資料', 'todo', 13),
    ('準備手機截圖（1080×1920）', 'todo', 14),
    ('完成 Data safety 與內容分級問卷', 'todo', 15),
    ('上傳 AAB 到封閉測試軌道', 'todo', 16),
    ('加入 Play App Signing 指紋到 assetlinks.json', 'todo', 17),
    ('邀請 12 位測試者，連續 14 日參與封閉測試', 'todo', 18)
  ) as v(title, status, ord)
 where not exists (select 1 from public.launch_todos t where t.title = v.title);

-- ===== 權限：只允許已登入用戶呼叫函數（函數內部再檢查 is_admin）=====
do $$
declare f text;
begin
  foreach f in array array[
    'admin_user_stats(uuid)',
    'admin_set_user_excluded(uuid,boolean,text)',
    'admin_delete_user_records(uuid,text,text)',
    'admin_todo_list()',
    'admin_todo_save(uuid,text,text,text,date)',
    'admin_todo_delete(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
