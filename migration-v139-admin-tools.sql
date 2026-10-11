-- ============================================================
-- v139：後台工具
--   1. feedback：App 內「回報問題／意見」（用戶只可新增同睇自己嘅）
--   2. admin_audit：管理員操作記錄（誰、幾時、做咗乜、原因）
--   3. 管理函數：意見列表／標記已處理、操作記錄列表、紅點數字 admin_badges()
--   4. admin_set_excluded / admin_set_ban 加可選嘅 p_reason，並寫入操作記錄；
--      admin_review_set 同樣寫入操作記錄
--
-- 可重複執行。需要先執行 v112。
-- ============================================================

-- ===== 1. 意見箱 =====
create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  category    text not null default 'other' check (category in ('bug','idea','other')),
  message     text not null check (char_length(message) between 1 and 1000),
  app_version text check (app_version is null or char_length(app_version) <= 20),
  user_agent  text check (user_agent is null or char_length(user_agent) <= 300),
  status      text not null default 'new' check (status in ('new','done')),
  admin_note  text check (admin_note is null or char_length(admin_note) <= 500),
  created_at  timestamptz not null default now(),
  handled_at  timestamptz
);
create index if not exists feedback_status_created_idx on public.feedback (status, created_at desc);
alter table public.feedback enable row level security;

drop policy if exists feedback_insert_own on public.feedback;
create policy feedback_insert_own on public.feedback for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists feedback_select_own on public.feedback;
create policy feedback_select_own on public.feedback for select to authenticated
  using (user_id = auth.uid());
revoke all on public.feedback from anon;
revoke all on public.feedback from authenticated;
grant select, insert on public.feedback to authenticated;   -- 用戶只可新增同睇自己嘅（RLS 再限制）

-- 新增時強制預設值，並限制每人每小時最多 5 則（防濫發）
create or replace function public.feedback_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.status := 'new';
  new.admin_note := null;
  new.handled_at := null;
  new.created_at := now();
  if (select count(*) from public.feedback f where f.user_id = new.user_id and f.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'rate_limit';
  end if;
  return new;
end $$;
drop trigger if exists feedback_before_insert on public.feedback;
create trigger feedback_before_insert before insert on public.feedback
  for each row execute function public.feedback_before_insert();

-- ===== 2. 操作記錄 =====
create table if not exists public.admin_audit (
  id          bigserial primary key,
  admin_id    uuid,
  admin_email text,
  action      text not null,
  target_type text,
  target_id   text,
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists admin_audit_created_idx on public.admin_audit (created_at desc);
alter table public.admin_audit enable row level security;      -- 無 policy
revoke all on public.admin_audit from anon, authenticated;

create or replace function public.admin_log(p_action text, p_type text, p_target text, p_detail jsonb)
returns void language sql security definer set search_path = public, auth as $$
  insert into public.admin_audit (admin_id, admin_email, action, target_type, target_id, detail)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_action, p_type, p_target, coalesce(p_detail, '{}'::jsonb));
$$;
revoke all on function public.admin_log(text, text, text, jsonb) from public, anon, authenticated;

-- ===== 3. 會寫操作記錄嘅管理動作 =====
drop function if exists public.admin_set_excluded(uuid, boolean);
create or replace function public.admin_set_excluded(p_catch uuid, p_excluded boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.catches;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.catches set admin_excluded = p_excluded where id = p_catch returning * into r;
  perform public.admin_log(case when p_excluded then 'exclude_catch' else 'restore_catch' end, 'catch', p_catch::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_reason,''), 200), ''), 'species', r.species, 'weight_kg', r.weight_kg,
                       'owner', (select display_name from public.users where id = r.user_id)));
  return jsonb_build_object('id', r.id, 'eligible', r.leaderboard_eligible, 'reason', r.ineligible_reason, 'excluded', r.admin_excluded);
end $$;

drop function if exists public.admin_set_ban(uuid, boolean);
create or replace function public.admin_set_ban(p_user uuid, p_banned boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_user = auth.uid() or exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'cannot ban admin';
  end if;
  update auth.users set banned_until = case when p_banned then now() + interval '100 years' else null end where id = p_user;
  perform public.admin_log(case when p_banned then 'ban_user' else 'unban_user' end, 'user', p_user::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_reason,''), 200), ''),
                       'name', (select display_name from public.users where id = p_user)));
end $$;

create or replace function public.admin_review_set(p_trip uuid, p_species text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status = 'pending' then
    delete from public.lb_review where trip_id = p_trip and species = p_species;
  elsif p_status in ('approved','rejected') then
    insert into public.lb_review (trip_id, species, status, note) values (p_trip, p_species, p_status, p_note)
    on conflict (trip_id, species) do update set status = excluded.status, note = excluded.note, reviewed_at = now();
  else
    raise exception 'bad status';
  end if;
  perform public.admin_log('review_' || p_status, 'trip', p_trip::text,
    jsonb_build_object('species', p_species, 'reason', nullif(left(coalesce(p_note,''), 200), '')));
end $$;

-- ===== 4. 意見箱／操作記錄／紅點 =====
create or replace function public.admin_feedback_list(p_status text default null, p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', f.id, 'category', f.category, 'message', f.message, 'app_version', f.app_version,
             'user_agent', f.user_agent, 'status', f.status, 'admin_note', f.admin_note, 'created_at', f.created_at,
             'handled_at', f.handled_at, 'user_id', f.user_id, 'display_name', u.display_name, 'email', a.email) x
      from public.feedback f
      left join public.users u on u.id = f.user_id
      left join auth.users a on a.id = f.user_id
     where p_status is null or p_status = '' or f.status = p_status
     order by f.created_at desc
     limit least(greatest(p_limit, 1), 300)) z), '[]'::jsonb);
end $$;

create or replace function public.admin_feedback_set(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_status not in ('new','done') then raise exception 'bad status'; end if;
  update public.feedback
     set status = p_status,
         admin_note = nullif(left(coalesce(p_note, ''), 500), ''),
         handled_at = case when p_status = 'done' then now() else null end
   where id = p_id;
  perform public.admin_log('feedback_' || p_status, 'feedback', p_id::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_note,''), 200), '')));
end $$;

create or replace function public.admin_audit_list(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', l.id, 'admin_email', l.admin_email, 'action', l.action, 'target_type', l.target_type,
             'target_id', l.target_id, 'detail', l.detail, 'created_at', l.created_at) x
      from public.admin_audit l
     order by l.created_at desc
     limit least(greatest(p_limit, 1), 300)) z), '[]'::jsonb);
end $$;

create or replace function public.admin_badges()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'pending_reviews', (select count(*) from public.lb_review_queue),
    'new_feedback',    (select count(*) from public.feedback where status = 'new'));
end $$;

do $$
declare f text;
begin
  foreach f in array array['admin_set_excluded(uuid,boolean,text)','admin_set_ban(uuid,boolean,text)',
    'admin_review_set(uuid,text,text,text)','admin_feedback_list(text,int)','admin_feedback_set(uuid,text,text)',
    'admin_audit_list(int)','admin_badges()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
