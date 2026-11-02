-- v190：創始編號只派畀「合資格魚獲」（leaderboard_eligible）＋後台取消編號
-- ⚠️ 只係 migration 檔，未喺 prod 執行；要主人批准先套用。撤回：rollback-v190-founders-eligible-revoke.sql
-- 規則：
--   * founders_assign()：保留原有檢查（is_test、已有編號、founders_excluded、users 有紀錄、上限 100、unique 重試），
--     另加：魚獲要 leaderboard_eligible、唔係 admin_excluded、用戶未被停用。
--   * 觸發：INSERT（原有 trg_founders_assign）＋ 新增 UPDATE 時 leaderboard_eligible 由 false/null 變 true。
--     catches_eligibility 係 BEFORE INSERT OR UPDATE，所以 AFTER trigger 睇到嘅係最終判定。
--   * 已有 founders 紀錄一律唔郁、唔重新編號；5e4fa205 永遠係 #1。
--   * admin_revoke_founder(p_user, p_reason)：原因必填；刪 founders 紀錄（號碼留空，唔重排）、號碼寫入 founders_revoked（墓碑，號碼永不再派、計入 100），
--     admin_log('founder_revoke')。拒絕 5e4fa205。唔會加入 founders_excluded（主人：「被取消嘅人可以再拎過新編號」）。
--   * 被取消／解除停用之後，只有喺「最後一次取消」同「最後一次解除停用」之後新建立（created_at）嘅合資格魚獲先會派新號；
--     舊魚獲（包括之後先變合資格嘅 UPDATE）唔會派。解除停用唔會還返舊號。
--   * admin_set_ban：停用時自動取消創始編號（其餘邏輯一字不改）。
--   * founder_remaining()：已取消嘅號碼都計作已用（因為唔會再派）。
--   * catches.created_at 鎖定：普通用戶（auth.uid() 有值、唔係管理員）INSERT 時一律用 now()，UPDATE 時保留舊值。
--     App 從來唔送 created_at（魚獲時間用 date／time 欄），所以唔影響離線補傳、編輯同排行榜；service role／SQL Editor 唔受影響。
-- 唔停用任何 trigger、唔改 catches 資料。
begin;

-- 墓碑：已取消嘅號碼（唔會再派）
create table if not exists public.founders_revoked (
  no int primary key,
  user_id uuid not null,
  reason text,
  revoked_by uuid,
  revoked_at timestamptz not null default now()
);
alter table public.founders_revoked enable row level security;
revoke all on public.founders_revoked from anon, authenticated;
create index if not exists founders_revoked_user_idx on public.founders_revoked (user_id);

-- v190：created_at 由伺服器寫，普通用戶改唔到（防止改時間避過取消／解封後嘅截止時間）
create or replace function public.catches_lock_created_at()
 returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if TG_OP = 'INSERT' then new.created_at := now();
    else new.created_at := old.created_at; end if;
  end if;
  return new;
end $$;
revoke all on function public.catches_lock_created_at() from public, anon, authenticated;
drop trigger if exists catches_a_lock_created_at on public.catches;
-- 名以 catches_a 開頭：BEFORE trigger 按名排序，喺 catches_eligibility 之前行
create trigger catches_a_lock_created_at before insert or update on public.catches
  for each row execute function public.catches_lock_created_at();

create or replace function public.founders_assign()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_no int; i int := 0; v_cut timestamptz;
begin
  if new.user_id is null or coalesce(new.is_test, false) then return new; end if;
  if not coalesce(new.leaderboard_eligible, false) or coalesce(new.admin_excluded, false) then return new; end if;   -- v190
  if exists (select 1 from public.founders where user_id = new.user_id) then return new; end if;
  if exists (select 1 from public.founders_excluded where user_id = new.user_id) then return new; end if;   -- v174b
  if not exists (select 1 from public.users where id = new.user_id) then return new; end if;
  if exists (select 1 from auth.users where id = new.user_id and banned_until > now()) then return new; end if;   -- v190
  -- v190：取消／解除停用之後，要喺嗰個時間之後新建立嘅魚獲先算；未來時間嘅 created_at 唔信
  if new.created_at > now() + interval '5 minutes' then return new; end if;
  select greatest((select max(revoked_at) from public.founders_revoked where user_id = new.user_id),
                  (select max(created_at) from public.admin_audit where action = 'unban_user' and target_id = new.user_id::text))
    into v_cut;
  if v_cut is not null and (new.created_at is null or new.created_at <= v_cut) then return new; end if;
  loop
    i := i + 1;
    select greatest(coalesce((select max(no) from public.founders), 0),
                    coalesce((select max(no) from public.founders_revoked), 0)) + 1 into v_no;   -- v190：唔再用已取消嘅號
    if v_no > 100 then return new; end if;
    begin
      insert into public.founders (user_id, no, first_catch_at) values (new.user_id, v_no, coalesce(new.created_at, now()));
      return new;
    exception when unique_violation then
      if exists (select 1 from public.founders where user_id = new.user_id) or i >= 10 then return new; end if;
    end;
  end loop;
exception when others then
  return new;   -- 派號失敗都唔阻記錄魚獲
end $function$;

-- v190：之後重新判定變成合資格都派號（原有 AFTER INSERT trigger 唔郁）
drop trigger if exists trg_founders_assign_upd on public.catches;
create trigger trg_founders_assign_upd after update on public.catches
  for each row when (new.leaderboard_eligible and not coalesce(old.leaderboard_eligible, false))
  execute function public.founders_assign();

create or replace function public.founder_remaining()
 returns integer
 language sql
 stable security definer
 set search_path to 'public'
as $function$ select greatest(0, 100 - (select count(*)::int from public.founders) - (select count(*)::int from public.founders_revoked)) $function$;

create or replace function public.admin_founder_no(p_user uuid)
 returns integer
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (select no from public.founders where user_id = p_user);
end $function$;

create or replace function public.admin_revoke_founder(p_user uuid, p_reason text default null)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_no int;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_user = '5e4fa205-add7-42d0-9ac4-6a1fe8ab6985'::uuid then raise exception 'cannot revoke founding admin'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'reason required'; end if;
  delete from public.founders where user_id = p_user returning no into v_no;
  if v_no is null then return null; end if;
  insert into public.founders_revoked (no, user_id, reason, revoked_by)
    values (v_no, p_user, nullif(left(coalesce(p_reason,''), 200), ''), auth.uid());
  perform public.admin_log('founder_revoke', 'user', p_user::text,
    jsonb_build_object('no', v_no, 'reason', nullif(left(coalesce(p_reason,''), 200), ''),
                       'name', (select display_name from public.users where id = p_user)));
  return v_no;
end $function$;

-- admin_set_ban：同現有版本一樣，只加「停用時取消創始編號」一行
create or replace function public.admin_set_ban(p_user uuid, p_banned boolean, p_reason text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_user = auth.uid() or exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'cannot ban admin';
  end if;
  update auth.users set banned_until = case when p_banned then now() + interval '100 years' else null end where id = p_user;
  perform public.admin_log(case when p_banned then 'ban_user' else 'unban_user' end, 'user', p_user::text,
    jsonb_build_object('reason', nullif(left(coalesce(p_reason,''), 200), ''),
                       'name', (select display_name from public.users where id = p_user)));
  if p_banned and exists (select 1 from public.founders where user_id = p_user) then   -- v190
    perform public.admin_revoke_founder(p_user, '停用帳戶：' || coalesce(nullif(left(coalesce(p_reason,''), 180), ''), '—'));
  end if;
end $function$;

revoke all on function public.admin_revoke_founder(uuid, text) from public, anon;
grant execute on function public.admin_revoke_founder(uuid, text) to authenticated;
revoke all on function public.admin_founder_no(uuid) from public, anon;
grant execute on function public.admin_founder_no(uuid) to authenticated;

commit;
