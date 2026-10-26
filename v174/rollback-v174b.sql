-- v174b rollback：還原 v174 原本嘅 founders_assign，刪走剔除表
begin;
create or replace function public.founders_assign()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_no int; i int := 0;
begin
  if new.user_id is null or coalesce(new.is_test, false) then return new; end if;
  if exists (select 1 from public.founders where user_id = new.user_id) then return new; end if;
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
revoke all on function public.founders_assign() from public, anon, authenticated;
drop table if exists public.founders_excluded;
commit;
