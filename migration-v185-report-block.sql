-- v185：檢舉內容／用戶 + 封鎖用戶（Apple Guideline 1.2）
-- ⚠️ 只係檔案；未套用到 prod。要主人另外批准先 apply。
-- 排行榜 key：biggest = catches.id；quantity / species = users.public_id（同 lb_biggest／lb_stats 一致）
-- 客戶端唔會知道對方 user_id（私隱），所以一律經 SECURITY DEFINER RPC 由 key 反查。

create table if not exists public.content_reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  target_user_id uuid references auth.users(id) on delete cascade,
  kind           text not null check (kind in ('content','user')),
  board          text check (board is null or board in ('biggest','quantity','species')),
  target_key     uuid,
  catch_id       uuid,
  reason         text not null check (reason in ('spam','offensive','fake','photo','name','other')),
  details        text check (details is null or char_length(details) <= 500),
  status         text not null default 'open' check (status in ('open','resolved','dismissed')),
  admin_note     text check (admin_note is null or char_length(admin_note) <= 500),
  created_at     timestamptz not null default now(),
  handled_at     timestamptz
);
create index if not exists content_reports_status_idx on public.content_reports (status, created_at desc);

create table if not exists public.user_blocks (
  blocker_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

alter table public.content_reports enable row level security;
alter table public.user_blocks enable row level security;
revoke all on public.content_reports, public.user_blocks from anon;
drop policy if exists cr_insert_own on public.content_reports;
create policy cr_insert_own on public.content_reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists cr_admin_read on public.content_reports;
create policy cr_admin_read on public.content_reports for select to authenticated using (public.is_admin());
drop policy if exists cr_admin_update on public.content_reports;
create policy cr_admin_update on public.content_reports for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists ub_own_read on public.user_blocks;
create policy ub_own_read on public.user_blocks for select to authenticated using (blocker_id = auth.uid() or public.is_admin());
drop policy if exists ub_own_insert on public.user_blocks;
create policy ub_own_insert on public.user_blocks for insert to authenticated with check (blocker_id = auth.uid());
drop policy if exists ub_own_delete on public.user_blocks;
create policy ub_own_delete on public.user_blocks for delete to authenticated using (blocker_id = auth.uid());

-- 由排行榜 key 反查用戶（內部用）
create or replace function public.lb_key_user(p_board text, p_key uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case when p_board = 'biggest' then (select user_id from public.catches where id = p_key)
              when p_board in ('quantity','species') then (select id from public.users where public_id = p_key) end;
$$;
revoke all on function public.lb_key_user(text, uuid) from public, anon, authenticated;

-- 檢舉（kind: content = 呢條魚獲／相；user = 呢個用戶／名）
create or replace function public.report_lb_entry(p_board text, p_key uuid, p_kind text, p_reason text, p_details text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_target uuid; v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'login required'; end if;
  v_target := public.lb_key_user(p_board, p_key);
  if v_target is null then raise exception 'not found'; end if;
  if v_target = v_me then raise exception 'cannot report self'; end if;
  if (select count(*) from public.content_reports where reporter_id = v_me and created_at > now() - interval '1 day') >= 20 then
    raise exception 'rate limit';
  end if;
  insert into public.content_reports (reporter_id, target_user_id, kind, board, target_key, catch_id, reason, details)
  values (v_me, v_target, p_kind, p_board, p_key, case when p_board = 'biggest' then p_key end, p_reason,
          nullif(left(btrim(coalesce(p_details, '')), 500), ''));
end $$;

create or replace function public.block_lb_entry(p_board text, p_key uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_target uuid; v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'login required'; end if;
  v_target := public.lb_key_user(p_board, p_key);
  if v_target is null then raise exception 'not found'; end if;
  if v_target = v_me then raise exception 'cannot block self'; end if;
  insert into public.user_blocks (blocker_id, blocked_id) values (v_me, v_target) on conflict do nothing;
end $$;

-- 我封鎖咗邊個（顯示名 + public_id，用嚟解除封鎖）
create or replace function public.my_blocks()
returns table(public_id uuid, display_name text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select u.public_id, coalesce(u.display_name, '釣友'), b.created_at
    from public.user_blocks b join public.users u on u.id = b.blocked_id
   where b.blocker_id = auth.uid() order by b.created_at desc;
$$;

create or replace function public.unblock_user(p_public_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.user_blocks
   where blocker_id = auth.uid() and blocked_id = (select id from public.users where public_id = p_public_id);
$$;

-- 一批排行榜 key 入面，邊啲屬於我封鎖咗嘅用戶（客戶端用嚟隱藏）
create or replace function public.lb_blocked_keys(p_board text, p_keys uuid[])
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(k), '{}') from unnest(p_keys) k
   where exists (select 1 from public.user_blocks b
                  where b.blocker_id = auth.uid() and b.blocked_id = public.lb_key_user(p_board, k));
$$;

-- 後台
create or replace function public.admin_reports_list(p_status text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', r.id, 'kind', r.kind, 'board', r.board, 'reason', r.reason, 'details', r.details,
             'status', r.status, 'admin_note', r.admin_note, 'created_at', r.created_at, 'handled_at', r.handled_at,
             'reporter_id', r.reporter_id, 'reporter_name', ru.display_name,
             'target_user_id', r.target_user_id, 'target_name', tu.display_name,
             'catch_id', r.catch_id, 'species', c.species, 'weight_kg', c.weight_kg, 'photo_url', c.photo_url,
             'catch_excluded', c.admin_excluded,
             'open_against_user', (select count(*) from public.content_reports r2 where r2.target_user_id = r.target_user_id and r2.status = 'open')) x
      from public.content_reports r
      left join public.users ru on ru.id = r.reporter_id
      left join public.users tu on tu.id = r.target_user_id
      left join public.catches c on c.id = r.catch_id
     where p_status is null or r.status = p_status
     order by r.created_at desc
     limit greatest(1, least(coalesce(p_limit, 200), 500))) s), '[]'::jsonb);
end $$;

create or replace function public.admin_report_set(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('open','resolved','dismissed') then raise exception 'bad status'; end if;
  update public.content_reports
     set status = p_status, admin_note = nullif(left(coalesce(p_note, ''), 500), ''),
         handled_at = case when p_status = 'open' then null else now() end
   where id = p_id;
  perform public.admin_log('report_' || p_status, 'report', p_id::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_note, ''), 200), '')));
end $$;

revoke all on function public.report_lb_entry(text, uuid, text, text, text), public.block_lb_entry(text, uuid),
  public.my_blocks(), public.unblock_user(uuid), public.lb_blocked_keys(text, uuid[]),
  public.admin_reports_list(text, int), public.admin_report_set(uuid, text, text) from public, anon;
grant execute on function public.report_lb_entry(text, uuid, text, text, text), public.block_lb_entry(text, uuid),
  public.my_blocks(), public.unblock_user(uuid), public.lb_blocked_keys(text, uuid[]),
  public.admin_reports_list(text, int), public.admin_report_set(uuid, text, text) to authenticated;
-- 隱藏內容／停用用戶：後台沿用現有 admin_set_excluded(catch,…) 同 admin_set_ban(user,…)
