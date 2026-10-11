-- v133：排行榜資料層面唔再回傳釣點（spot）
-- 重量王者排行榜 RPC lb_biggest 原本會回傳每條魚嘅釣點名稱；而家移除該欄。
-- 返回欄位改變，所以要先 DROP 再重建。可重覆執行。
-- 舊版 App 不受影響（畫面本來已唔顯示釣點）。

drop function if exists public.lb_biggest(text);

create function public.lb_biggest(p_period text default 'all')
returns table (
  pos int, catch_id uuid, display_name text, is_mine boolean,
  species text, species_icon text, weight_kg numeric, catch_date date, catch_time time
)
language sql
stable
security definer
set search_path = public
as $$
  with best as (
    select distinct on (c.user_id) c.*
      from public.catches c
     where c.leaderboard_eligible and c.user_id is not null and not public.is_banned(c.user_id)
       and c.date >= public.lb_period_start(p_period)
     order by c.user_id, c.weight_kg desc, c.date asc, c.created_at asc
  )
  select (row_number() over (order by b.weight_kg desc, b.date asc, b.created_at asc))::int,
         b.id, u.display_name, (b.user_id = auth.uid()),
         b.species, b.species_icon, b.weight_kg, b.date, b.time
    from best b
    left join public.users u on u.id = b.user_id
   order by 1
   limit 100;
$$;

revoke all on function public.lb_biggest(text) from public, anon;
grant execute on function public.lb_biggest(text) to authenticated;
