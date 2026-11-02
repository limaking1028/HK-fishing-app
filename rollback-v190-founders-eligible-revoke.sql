-- 撤回 v190：還原 founders_assign／admin_set_ban／founder_remaining 原本定義（prod pg_get_functiondef 抄落嚟），
-- 刪新 trigger 同兩個新函數。唔郁 founders／founders_excluded 資料；founders_revoked 表保留做紀錄（要刪可以手動 drop）。
-- 注意：還原後派號會用返 max(no)+1，如果最大嗰個號曾經被取消，會再派出同一個號。
begin;
drop trigger if exists trg_founders_assign_upd on public.catches;
drop trigger if exists catches_a_lock_created_at on public.catches;
drop function if exists public.catches_lock_created_at();
drop function if exists public.admin_revoke_founder(uuid, text);
drop function if exists public.admin_founder_no(uuid);

create or replace function public.founders_assign()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_no int; i int := 0;
begin
  if new.user_id is null or coalesce(new.is_test, false) then return new; end if;
  if exists (select 1 from public.founders where user_id = new.user_id) then return new; end if;
  if exists (select 1 from public.founders_excluded where user_id = new.user_id) then return new; end if;   -- v174b
  if not exists (select 1 from public.users where id = new.user_id) then return new; end if;
  loop
    i := i + 1;
    select coalesce(max(no), 0) + 1 into v_no from public.founders;
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

create or replace function public.founder_remaining()
 returns integer
 language sql
 stable security definer
 set search_path to 'public'
as $function$ select greatest(0, 100 - (select count(*)::int from public.founders)) $function$;

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
end $function$;
commit;
