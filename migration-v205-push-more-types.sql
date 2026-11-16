-- v205; REVIEW ONLY. Depends on v200/#73. No remote SQL, extension or cron is executed here.
begin;
alter table public.notification_prefs
 add column if not exists tide_window boolean not null default true,
 add column if not exists lb_chance boolean not null default true,
 add column if not exists trip_open boolean not null default true,
 add column if not exists weekly_summary boolean not null default true,
 add column if not exists inactive boolean not null default true;
alter table public.notification_outbox drop constraint if exists notification_outbox_type_check;
alter table public.notification_outbox add constraint notification_outbox_type_check check(type in ('record_broken','overtaken','tide_window','lb_chance','trip_open','weekly_summary','inactive'));
alter table public.notification_outbox alter column board drop not null;
alter table public.notification_outbox drop constraint if exists notification_outbox_period_check;
alter table public.notification_outbox add constraint notification_outbox_period_check check(period in ('all','month'));
alter table public.notification_outbox
 add column if not exists priority smallint not null default 5 check(priority between 1 and 7),
 add column if not exists expires_at timestamptz,
 add column if not exists skip_reason text;
create table if not exists public.notification_dedupe (
 user_id uuid not null references public.users(id) on delete cascade,
 type text not null, dedupe_key text not null,
 created_at timestamptz not null default now(), meta jsonb not null default '{}',
 primary key(user_id,type,dedupe_key)
);
alter table public.notification_dedupe enable row level security;
revoke all on public.notification_dedupe from public,anon,authenticated;
grant all on public.notification_dedupe to service_role;
create index if not exists notification_dedupe_age_idx on public.notification_dedupe(created_at);

create or replace function public.push_type_enabled(p public.notification_prefs,p_type text) returns boolean
language sql immutable security definer set search_path = public as $$
 select coalesce(case p_type when 'record_broken' then p.record_broken when 'overtaken' then p.overtaken
 when 'tide_window' then p.tide_window when 'lb_chance' then p.lb_chance when 'trip_open' then p.trip_open
 when 'weekly_summary' then p.weekly_summary when 'inactive' then p.inactive else false end,false);
$$;
create or replace function public.push_priority(p_type text) returns smallint
language sql immutable security definer set search_path = public as $$
 select case p_type when 'overtaken' then 1 when 'record_broken' then 2 when 'trip_open' then 3
 when 'tide_window' then 4 when 'lb_chance' then 5 when 'weekly_summary' then 6 when 'inactive' then 7 end::smallint;
$$;
update public.notification_outbox set priority=public.push_priority(type);
create or replace function public.push_audience(p_user uuid,p_type text) returns boolean
language sql stable security definer set search_path = public as $$
 select exists(select 1 from public.users u join public.notification_prefs p on p.user_id=u.id
 where u.id=p_user and p.enabled and public.push_type_enabled(p,p_type) and not public.is_banned(u.id)
 and not exists(select 1 from public.founders_excluded f where f.user_id=u.id)
 and exists(select 1 from public.device_tokens d where d.user_id=u.id and d.enabled));
$$;
create or replace function public.push_after_quiet(p_at timestamptz) returns timestamptz
language sql immutable security definer set search_path = public as $$
 select case when (p_at at time zone 'Asia/Hong_Kong')::time >= time '23:00'
 then (((p_at at time zone 'Asia/Hong_Kong')::date+1)+time '07:00') at time zone 'Asia/Hong_Kong'
 when (p_at at time zone 'Asia/Hong_Kong')::time < time '07:00'
 then ((p_at at time zone 'Asia/Hong_Kong')::date+time '07:00') at time zone 'Asia/Hong_Kong' else p_at end;
$$;
create or replace function public.push_route_data(p jsonb) returns jsonb
language plpgsql immutable security definer set search_path = public as $$
declare v text:=coalesce(p->>'view',''); r jsonb;
begin
 if v not in ('leaderboard','map','trips','my') then v:='leaderboard'; end if;
 r:=jsonb_build_object('view',v);
 if v='leaderboard' then
  r:=r||jsonb_build_object('lbType',case when p->>'lbType' in ('biggest','quantity','species') then p->>'lbType' else 'biggest' end,
   'lbPeriod',case when p->>'lbPeriod' in ('all','month') then p->>'lbPeriod' else 'all' end);
 elsif v='map' then
  r:=r||jsonb_build_object('mapTab','tide');
  if p->>'station' in ('QUB','TPK','CCH','TAO','SPW','TBT','SAI','KCQ','LAM','CHK','TCT','PEN') then r:=r||jsonb_build_object('station',p->>'station'); end if;
 end if;
 return r;
end $$;
create or replace function public.push_enqueue_generic(p_user uuid,p_type text,p_dedupe text,p_title text,p_body text,p_data jsonb,p_send_after timestamptz,p_expires_at timestamptz) returns uuid
language plpgsql security definer set search_path = public as $$
declare due timestamptz:=coalesce(p_send_after,now()); expiry timestamptz:=p_expires_at; result uuid; safe jsonb:=public.push_route_data(p_data);
begin
 if not public.push_audience(p_user,p_type) or public.push_priority(p_type) is null then return null; end if;
 if p_type in ('record_broken','overtaken','trip_open') then due:=public.push_after_quiet(due); expiry:=null;
 else expiry:=coalesce(expiry,((due at time zone 'Asia/Hong_Kong')::date+time '23:00') at time zone 'Asia/Hong_Kong'); end if;
 insert into public.notification_dedupe(user_id,type,dedupe_key) values(p_user,p_type,p_dedupe) on conflict do nothing;
 if not found then return null; end if;
 insert into public.notification_outbox(user_id,type,board,period,dedupe_key,notification_day,title,body,data,send_after,expires_at,priority)
 values(p_user,p_type,case when safe->>'view'='leaderboard' then safe->>'lbType' end,coalesce(safe->>'lbPeriod','all'),p_dedupe,
  (due at time zone 'Asia/Hong_Kong')::date,p_title,p_body,safe,due,expiry,public.push_priority(p_type))
 on conflict(user_id,type,dedupe_key,notification_day) do nothing returning id into result;
 return result;
end $$;
-- Replace the original enqueue without changing v200 or the rank-change trigger.
create or replace function public.push_enqueue_one(p_user uuid,p_type text,p_board text,p_species text) returns void
language plpgsql security definer set search_path = public as $$
declare label text; msg text; due timestamptz:=public.push_after_quiet(now()); result uuid;
begin
 if p_type not in ('record_broken','overtaken') or not public.push_audience(p_user,p_type) then return; end if;
 if exists(select 1 from public.notification_outbox o where o.user_id=p_user and o.type=p_type and o.board=p_board
  and coalesce(o.species,'')=coalesce(p_species,'') and o.notification_day=(due at time zone 'Asia/Hong_Kong')::date) then return; end if;
 label:=case p_board when 'biggest' then '重量王者（全期）' when 'quantity' then '數量王者（全期）' when 'species' then '品種王者（全期）' else p_species||'嘅最重紀錄' end;
 msg:=case when p_type='record_broken' then case when p_board='species_record' then '恭喜！你刷新咗'||label||'！' else '恭喜！你登上'||label||'第 1 名' end else '有人超越咗你喺'||label||'，快啲返嚟奪回！' end;
 result:=public.push_enqueue_generic(p_user,p_type,p_board||':'||coalesce(p_species,'')||':'||(due at time zone 'Asia/Hong_Kong')::date,'釣港',msg,
 jsonb_build_object('view','leaderboard','lbType',case when p_board='species_record' then 'biggest' else p_board end,'lbPeriod','all'),due,null);
 if result is not null then update public.notification_outbox set board=p_board,species=nullif(p_species,'') where id=result; end if;
end $$;

create or replace function public.push_last_seen(p_user uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
 select coalesce(greatest(u.last_login_at,
  (select max(d.last_seen_at) from public.device_tokens d where d.user_id=u.id),
  (select ((max(a.day)+1)::timestamp at time zone 'Asia/Hong_Kong')-interval '1 microsecond' from public.app_usage a where a.user_id=u.id)),u.created_at)
 from public.users u where u.id=p_user;
$$;
create or replace function public.push_cleanup_dedupe() returns void
language plpgsql security definer set search_path = public as $$
begin
 delete from public.notification_dedupe d where d.created_at<now()-interval '90 days' and
 (d.type not in ('trip_open','inactive')
  or (d.type='trip_open' and not exists(select 1 from public.fishing_trips t where 'trip:'||t.id::text=d.dedupe_key and t.ended_at is null))
  or (d.type='inactive' and public.push_last_seen(d.user_id)>d.created_at));
end $$;

create or replace function public.push_claim_outbox(p_limit integer default 50) returns setof public.notification_outbox
language plpgsql security definer set search_path = public as $$
declare day_start timestamptz:=((now() at time zone 'Asia/Hong_Kong')::date::timestamp at time zone 'Asia/Hong_Kong');
 tomorrow timestamptz:=(((now() at time zone 'Asia/Hong_Kong')::date+1)+time '07:00') at time zone 'Asia/Hong_Kong';
 item record; claimed public.notification_outbox; total integer:=0;
begin
 -- Serialize claim budgeting across workers; provider requests happen after this transaction.
 perform pg_advisory_xact_lock(205,1);
 perform public.push_cleanup_dedupe();
 update public.notification_outbox set status='skipped',skip_reason='expired' where status in ('pending','sending') and expires_at<=now();
 update public.notification_outbox o set status='skipped',skip_reason='not_allowed' where o.status in ('pending','sending') and not public.push_audience(o.user_id,o.type);
 update public.notification_outbox set status='failed' where status='sending' and attempts>=5 and claimed_at<now()-interval '10 minutes';
 update public.notification_outbox set status='pending',claim_id=null where status='sending' and attempts<5 and claimed_at<now()-interval '10 minutes';
 if public.push_after_quiet(now())>now() then
  update public.notification_outbox set send_after=public.push_after_quiet(now()) where status='pending' and send_after<=now() and type in ('record_broken','overtaken','trip_open');
  return;
 end if;
 -- Preserve v200's per-board/type daily limit even when an immediate backlog rolls over.
 update public.notification_outbox o set status='skipped',skip_reason='daily_dedupe'
 where o.status='pending' and o.send_after<=now() and o.type in ('record_broken','overtaken') and exists(
  select 1 from public.notification_outbox sent where sent.id<>o.id and sent.user_id=o.user_id and sent.type=o.type
   and sent.board is not distinct from o.board and sent.species is not distinct from o.species
   and (sent.status in ('sent','sending') or cardinality(sent.delivered_token_ids)>0)
   and greatest(sent.sent_at,sent.claimed_at)>=day_start);
 with duplicates as (
  select id,row_number() over(partition by user_id,type,board,species order by
   case when cardinality(delivered_token_ids)>0 then 0 else 1 end,send_after,id) n
  from public.notification_outbox where status='pending' and send_after<=now() and type in ('record_broken','overtaken')
 ) update public.notification_outbox o set status='skipped',skip_reason='daily_dedupe' from duplicates d where o.id=d.id and d.n>1;
 -- Lock candidate rows separately: PostgreSQL forbids FOR UPDATE on a window query.
 perform 1 from public.notification_outbox where status='pending' and send_after<=now() for update;
 for item in
  with used as (
   select user_id,count(*) as n from public.notification_outbox where
    (status in ('sent','sending') and greatest(sent_at,claimed_at)>=day_start)
    or (cardinality(delivered_token_ids)>0 and greatest(sent_at,claimed_at)>=day_start)
   group by user_id
  ), ranked as (
   select o.id,o.type,o.priority,o.send_after,coalesce(u.n,0) as used,
    (cardinality(o.delivered_token_ids)>0 and greatest(o.sent_at,o.claimed_at)>=day_start) as already_counted,
    sum(case when cardinality(o.delivered_token_ids)>0 and greatest(o.sent_at,o.claimed_at)>=day_start then 0 else 1 end)
     over(partition by o.user_id order by o.priority,o.send_after,o.id) as slot
   from public.notification_outbox o left join used u on u.user_id=o.user_id
   where o.status='pending' and o.send_after<=now() and o.attempts<5
  ) select * from ranked order by priority,send_after,id
 loop
  if item.already_counted or item.slot<=greatest(0,2-item.used) then
   if total<greatest(1,least(p_limit,100)) then
    update public.notification_outbox set status='sending',claim_id=gen_random_uuid(),claimed_at=now(),attempts=attempts+1
    where id=item.id and status='pending' returning * into claimed;
    if found then total:=total+1; return next claimed; end if;
   end if;
  elsif item.type in ('record_broken','overtaken','trip_open') then
   update public.notification_outbox set send_after=tomorrow where id=item.id and status='pending';
  else
   update public.notification_outbox set status='skipped',skip_reason='daily_cap' where id=item.id and status='pending';
  end if;
 end loop;
end $$;
create or replace function public.push_delivery_allowed(p_job uuid,p_claim uuid,p_device uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
 update public.notification_outbox set status='skipped',skip_reason='expired'
 where id=p_job and claim_id=p_claim and status='sending' and expires_at<=now();
 -- A batch crossing 23:00 must defer immediate jobs, not discard them.
 if public.push_after_quiet(now())>now() then
  update public.notification_outbox set status='pending',claim_id=null,send_after=public.push_after_quiet(now())
  where id=p_job and claim_id=p_claim and status='sending' and type in ('record_broken','overtaken','trip_open');
  return false;
 end if;
 return exists(select 1 from public.notification_outbox o join public.device_tokens d on d.user_id=o.user_id and d.id=p_device
 where o.id=p_job and o.claim_id=p_claim and o.status='sending' and d.enabled and public.push_audience(o.user_id,o.type)
 and o.send_after<=now() and (o.expires_at is null or o.expires_at>now()));
end $$;

-- A public monthly projection for internal scheduling; original lb_* APIs remain untouched.
create or replace function public.push_monthly_ranks() returns table(board text,user_id uuid,pos integer,value numeric)
language plpgsql security definer set search_path = public as $$
declare claims text:=current_setting('request.jwt.claims',true); legacy text:=current_setting('request.jwt.claim.sub',true);
begin
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 return query
 with weights as (
  select distinct on(w.user_id) w.user_id,w.weight_kg,w.date,w.created_at
  from public.lb_weight_cand() w join public.catches c on c.id=w.id
  where w.ok and w.date>=public.lb_period_start('month') and not c.is_test and not c.admin_excluded
  order by w.user_id,w.weight_kg desc,w.date,w.created_at
 ) select 'biggest'::text,w.user_id,row_number() over(order by w.weight_kg desc,w.date,w.created_at)::int,w.weight_kg from weights w
 union all select 'quantity',r.user_id,r.pos,r.catch_count::numeric from public.lb_stats_rows('month','quantity') r
 union all select 'species',r.user_id,r.pos,r.species_count::numeric from public.lb_stats_rows('month','species') r;
 perform set_config('request.jwt.claims',coalesce(claims,''),true); perform set_config('request.jwt.claim.sub',coalesce(legacy,''),true);
exception when others then
 perform set_config('request.jwt.claims',coalesce(claims,''),true); perform set_config('request.jwt.claim.sub',coalesce(legacy,''),true); raise;
end $$;
create or replace function public.push_schedule_trip_open() returns integer
language plpgsql security definer set search_path = public as $$
declare t record; n integer:=0;
begin
 for t in select id,user_id from public.fishing_trips where ended_at is null and user_id is not null and started_at<=now()-interval '6 hours' and started_at>=now()-interval '24 hours' loop
  if public.push_enqueue_generic(t.user_id,'trip_open','trip:'||t.id,'釣港','你嘅行程已經開咗 6 個鐘，記得記低魚獲同按結束行程 🎣','{"view":"trips"}',now(),null) is not null then n:=n+1; end if;
 end loop;
 return n;
end $$;
create or replace function public.push_schedule_lb_chance() returns integer
language plpgsql security definer set search_path = public as $$
declare item record; n integer:=0; hk timestamp:=now() at time zone 'Asia/Hong_Kong';
begin
 for item in
  with ranks as materialized(select * from public.push_monthly_ranks()),
  boards as (select * from (values('quantity','數量王者',3),('species','品種王者',2),('biggest','重量王者',0)) b(board,label,gap_limit)),
  active as(select distinct user_id from public.catches where not is_test and created_at>=now()-interval '60 days' and created_at<=now() and user_id is not null),
  options as(
   select a.user_id,b.board,
    case when totals.n<10 then 1 else greatest(1,tenth.value-coalesce(mine.value,0)+1)::int end effort,
    case when totals.n<10 then '本月'||b.label||'仲有 '||(10-totals.n)||' 個位，記低一條就有機會上榜！'
    else '再釣 '||greatest(1,tenth.value-mine.value+1)::int||case when b.board='quantity' then ' 條' else ' 種' end||'就入到本月'||b.label||'前 10！' end body
   from active a cross join boards b
   left join ranks mine on mine.user_id=a.user_id and mine.board=b.board
   left join ranks tenth on tenth.board=b.board and tenth.pos=10
   cross join lateral(select count(*)::int n from ranks r where r.board=b.board) totals
   where public.push_audience(a.user_id,'lb_chance') and (mine.pos is null or mine.pos>10)
   and (totals.n<10 or (b.board<>'biggest' and mine.pos between 11 and 20 and tenth.value-mine.value<=b.gap_limit))
  ) select distinct on(user_id) * from options order by user_id,effort,case board when 'quantity' then 1 when 'species' then 2 else 3 end
 loop
  if public.push_enqueue_generic(item.user_id,'lb_chance','lb:'||to_char(hk,'IYYY-IW'),'釣港',item.body,
   jsonb_build_object('view','leaderboard','lbType',item.board,'lbPeriod','month'),(hk::date+time '19:00') at time zone 'Asia/Hong_Kong',(hk::date+time '23:00') at time zone 'Asia/Hong_Kong') is not null then n:=n+1; end if;
 end loop;
 return n;
end $$;
create or replace function public.push_schedule_weekly() returns integer
language plpgsql security definer set search_path = public as $$
declare u record; n integer:=0; trip_n integer; fish_n integer; species_n integer; ranks jsonb; mine jsonb; previous jsonb; improved record;
 hk timestamp:=now() at time zone 'Asia/Hong_Kong'; week_start timestamptz; key text; msg text; result uuid;
begin
 week_start:=date_trunc('week',hk) at time zone 'Asia/Hong_Kong'; key:='week:'||to_char(hk,'IYYY-IW');
 select coalesce(jsonb_agg(to_jsonb(r)),'[]') into ranks from public.push_monthly_ranks() r;
 for u in select id from public.users where public.push_audience(id,'weekly_summary') loop
  select count(*)::int into trip_n from public.fishing_trips where user_id=u.id and started_at>=week_start and started_at<=now();
  select count(*)::int,count(distinct species)::int into fish_n,species_n from public.catches where user_id=u.id and not is_test and date>=(week_start at time zone 'Asia/Hong_Kong')::date and date<=hk::date;
  select coalesce(jsonb_object_agg(r->>'board',(r->>'pos')::int),'{}') into mine from jsonb_array_elements(ranks) r where (r->>'user_id')::uuid=u.id;
  if trip_n=0 and fish_n=0 then continue; end if;
  select meta->'ranks' into previous from public.notification_dedupe where user_id=u.id and type='weekly_summary' and dedupe_key<>key and meta->>'month'=to_char(hk,'YYYY-MM') order by created_at desc,dedupe_key desc limit 1;
  msg:='今個禮拜你出咗 '||trip_n||' 次釣，記低 '||fish_n||' 條（'||species_n||' 種）。';
  select e.key board,e.value::int pos into improved from jsonb_each_text(mine) e
   where (previous->>e.key)::int>e.value::int order by (previous->>e.key)::int-e.value::int desc,e.key limit 1;
  if found then msg:=msg||'本月'||case improved.board when 'quantity' then '數量王者' when 'species' then '品種王者' else '重量王者' end||'你升咗去第 '||improved.pos||' 名！'; end if;
  result:=public.push_enqueue_generic(u.id,'weekly_summary',key,'釣港',msg,'{"view":"trips"}',(hk::date+time '18:00') at time zone 'Asia/Hong_Kong',(hk::date+time '23:00') at time zone 'Asia/Hong_Kong');
  if result is not null then update public.notification_dedupe set meta=jsonb_build_object('month',to_char(hk,'YYYY-MM'),'ranks',mine) where user_id=u.id and type='weekly_summary' and dedupe_key=key; n:=n+1; end if;
 end loop;
 return n;
end $$;
create or replace function public.push_tide_candidates_enqueue(p_day date,p_stations jsonb,p_spot_map jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare t record; st jsonb; station_code text; display_name text; main_name text; n integer:=0; hk timestamp:=now() at time zone 'Asia/Hong_Kong';
begin
 if p_day<>hk::date+1 then return 0; end if;
 for t in select distinct on(user_id) * from public.fishing_trips where user_id is not null order by user_id,started_at desc,id loop
  if t.started_at>now() or t.started_at<now()-interval '90 days' or not public.push_audience(t.user_id,'tide_window') then continue; end if;
  select m->>'s' into station_code from jsonb_array_elements(p_spot_map) with ordinality maps(m,i)
   where exists(select 1 from jsonb_array_elements_text(m->'p') p where position(p in coalesce(t.spot,''))>0)
   order by i limit 1;
  if station_code is null and t.latitude is not null and t.longitude is not null then
   select s->>'code' into station_code from jsonb_array_elements(p_stations) s
    order by power((s->>'lat')::numeric-t.latitude,2)+power(((s->>'lng')::numeric-t.longitude)*cos(radians(t.latitude)),2),s->>'code' limit 1;
  end if;
  station_code:=coalesce(station_code,'QUB');
  select s into st from jsonb_array_elements(p_stations) s where s->>'code'=station_code limit 1;
  if st is null or not coalesce((st->>'good')::boolean,false) or coalesce(st->>'start','') !~ '^[0-2][0-9]:[0-5][0-9]$' or coalesce(st->>'end','') !~ '^[0-2][0-9]:[0-5][0-9]$' then continue; end if;
  main_name:=trim(split_part(coalesce(t.spot,''),'（',1));
  display_name:=case when main_name in ('魚排','碼頭','離島','馬灣','大澳','石澳','大美督','港珠橋墩','流浮山蠔排') then main_name when main_name='秘點' then '你嘅秘點'
   else (case station_code when 'QUB' then '鰂魚涌' when 'TPK' then '大埔滘' when 'CCH' then '長洲' when 'TAO' then '大澳' when 'SPW' then '石壁' when 'TBT' then '尖鼻咀' when 'SAI' then '西貢' when 'KCQ' then '青衣' when 'LAM' then '南丫島' when 'CHK' then '赤鱲角' when 'TCT' then '東涌' when 'PEN' then '坪洲' end)||'一帶' end;
  if display_name is null then continue; end if;
  if public.push_enqueue_generic(t.user_id,'tide_window','tide:'||p_day,'釣港','聽日 '||(st->>'start')||'–'||(st->>'end')||' '||display_name||'漲潮，天文台預測'||(st->>'phrase')||'，啱晒開竿！',
   jsonb_build_object('view','map','mapTab','tide','station',station_code),(hk::date+time '20:00') at time zone 'Asia/Hong_Kong',(hk::date+time '23:00') at time zone 'Asia/Hong_Kong') is not null then n:=n+1; end if;
 end loop;
 return n;
end $$;
create or replace function public.push_inactive_enqueue(p_weekend_good boolean,p_phrase text) returns integer
language plpgsql security definer set search_path = public as $$
declare u record; seen timestamptz; n integer:=0; hk timestamp:=now() at time zone 'Asia/Hong_Kong'; msg text;
begin
 msg:=case when p_weekend_good then '好耐冇見！呢個週末'||left(p_phrase,40)||'，啱晒出去開竿 🎣' else '好耐冇見！睇下呢個週末嘅潮汐，計劃下次出釣啦。' end;
 for u in select id from public.users where public.push_audience(id,'inactive') loop
  seen:=public.push_last_seen(u.id);
  if seen is null or seen>now()-interval '7 days' then continue; end if;
  if public.push_enqueue_generic(u.id,'inactive','inactive:'||(seen at time zone 'Asia/Hong_Kong')::date,'釣港',msg,'{"view":"map","mapTab":"tide"}',
   (hk::date+time '19:30') at time zone 'Asia/Hong_Kong',(hk::date+time '23:00') at time zone 'Asia/Hong_Kong') is not null then n:=n+1; end if;
 end loop;
 return n;
end $$;
-- Add cleanup to the same v200 wrapper: no additional wrapping/renaming.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
 if auth.uid() is null then raise exception 'not authenticated'; end if;
 delete from public.notification_dedupe where user_id=auth.uid();
 delete from public.device_tokens where user_id=auth.uid();
 delete from public.notification_prefs where user_id=auth.uid();
 delete from public.notification_outbox where user_id=auth.uid();
 perform public.push_delete_account_previous();
end $$;
-- Default PUBLIC execute is revoked for every new internal function; only service_role can call it.
do $$ declare f text; begin
 foreach f in array array[
 'push_type_enabled(public.notification_prefs,text)','push_priority(text)','push_audience(uuid,text)','push_after_quiet(timestamptz)',
 'push_route_data(jsonb)','push_enqueue_generic(uuid,text,text,text,text,jsonb,timestamptz,timestamptz)',
 'push_last_seen(uuid)','push_cleanup_dedupe()','push_monthly_ranks()','push_schedule_trip_open()',
 'push_schedule_lb_chance()','push_schedule_weekly()','push_tide_candidates_enqueue(date,jsonb,jsonb)','push_inactive_enqueue(boolean,text)',
 'push_claim_outbox(integer)','push_delivery_allowed(uuid,uuid,uuid)','push_enqueue_one(uuid,text,text,text)'
 ] loop
  execute 'revoke all on function public.'||f||' from public,anon,authenticated';
  execute 'grant execute on function public.'||f||' to service_role';
 end loop;
end $$;
commit;
