-- v189：後台「管理員管理」— admin_admins_list() / admin_set_admin(p_user, p_on)
-- ⚠️ 只係 migration 檔，未喺 prod 執行；要主人批准先套用。
-- 規則：
--   * 只有管理員（is_admin()）可以用；SECURITY DEFINER + 固定 search_path。
--   * 加管理員時同時加入 founders_excluded（唔計 KPI／排行榜／創始釣友）。
--   * 移除時拒絕：釣港管理員 5e4fa205（主人規則「一直保持在#1 不要改」）、最後一個管理員、自己。
--   * 移除管理員唔會自動移出 founders_excluded（數據照舊唔計，要另外決定）。
--   * 每次改動經 admin_log() 寫入 admin_audit；唔返回任何電郵。
-- 唔改任何表結構、唔停用 trigger、唔改 founders。可以重複執行（CREATE OR REPLACE）。
begin;

create or replace function public.admin_admins_list()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
             'user_id', a.user_id, 'display_name', u.display_name, 'created_at', a.created_at,
             'protected', a.user_id = '5e4fa205-add7-42d0-9ac4-6a1fe8ab6985'::uuid,
             'is_me', a.user_id = auth.uid()) order by a.created_at)
           from public.admins a left join public.users u on u.id = a.user_id), '[]'::jsonb);
end $function$;

create or replace function public.admin_set_admin(p_user uuid, p_on boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_user is null or p_on is null then raise exception 'bad args'; end if;
  if p_on then
    if not exists (select 1 from public.users where id = p_user) then raise exception 'user not found'; end if;
    insert into public.admins (user_id) values (p_user) on conflict do nothing;
    insert into public.founders_excluded (user_id, note) values (p_user, '管理員（後台加入）：唔上排行榜、唔計創始釣友、KPI 唔計')
      on conflict do nothing;
    perform public.admin_log('admin_add', 'user', p_user::text, '{}'::jsonb);
  else
    if p_user = '5e4fa205-add7-42d0-9ac4-6a1fe8ab6985'::uuid then raise exception 'cannot remove founding admin'; end if;
    if p_user = auth.uid() then raise exception 'cannot remove yourself'; end if;
    if not exists (select 1 from public.admins where user_id = p_user) then return; end if;
    if (select count(*) from public.admins) <= 1 then raise exception 'cannot remove last admin'; end if;
    delete from public.admins where user_id = p_user;
    perform public.admin_log('admin_remove', 'user', p_user::text, '{}'::jsonb);
  end if;
end $function$;

revoke all on function public.admin_admins_list() from public, anon;
revoke all on function public.admin_set_admin(uuid, boolean) from public, anon;
grant execute on function public.admin_admins_list() to authenticated;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;
commit;
