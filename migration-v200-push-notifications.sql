-- v200: review-only migration. DO NOT execute against production or test projects without owner approval.
-- No cron job or extension is enabled here. Later schedule send-push using a secret-backed
-- URL and PUSH_SEND_SECRET via the project's scheduler; never embed credentials in SQL.
begin;
create table if not exists public.device_tokens (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.users(id) on delete cascade,
 platform text not null check (platform in ('ios','android','web')),
 token_type text not null check (token_type in ('apns','webpush')),
 token text not null unique check (length(token) between 16 and 8192),
 enabled boolean not null default true,
 created_at timestamptz not null default now(), last_seen_at timestamptz not null default now(),
 check ((token_type='apns' and platform='ios') or (token_type='webpush' and platform in ('android','web')))
);
create table if not exists public.notification_prefs (
 user_id uuid primary key references public.users(id) on delete cascade,
 enabled boolean not null default false,
 record_broken boolean not null default true, overtaken boolean not null default true,
 updated_at timestamptz not null default now()
);
create table if not exists public.notification_outbox (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.users(id) on delete cascade,
 type text not null check (type in ('record_broken','overtaken')),
 board text not null check (board in ('biggest','quantity','species','species_record')),
 period text not null default 'all' check (period='all'), species text,
 dedupe_key text not null, notification_day date not null,
 title text not null, body text not null, data jsonb not null,
 send_after timestamptz not null, sent_at timestamptz,
 status text not null default 'pending' check (status in ('pending','sending','sent','skipped','failed')),
 attempts integer not null default 0, claim_id uuid, claimed_at timestamptz, delivered_token_ids uuid[] not null default '{}',
 unique (user_id,type,dedupe_key,notification_day)
);
create index if not exists push_due_idx on public.notification_outbox(send_after) where status in ('pending','sending');
-- Per-row before-images support multi-row statements; rows are consumed in the same transaction.
create table if not exists public.lb_notify_state (id text primary key, snapshot jsonb not null, created_at timestamptz not null default now());
alter table public.device_tokens enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.lb_notify_state enable row level security;
revoke all on public.device_tokens, public.notification_prefs, public.notification_outbox, public.lb_notify_state from public, anon, authenticated;
grant select,insert,update,delete on public.device_tokens,public.notification_prefs to authenticated;
grant all on public.device_tokens,public.notification_prefs,public.notification_outbox,public.lb_notify_state to service_role;
drop policy if exists push_own_device on public.device_tokens;
create policy push_own_device on public.device_tokens to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
drop policy if exists push_own_prefs on public.notification_prefs;
create policy push_own_prefs on public.notification_prefs to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

-- Public VAPID key only; no private key is ever stored in app_config.
create or replace function public.push_public_config() returns text
language sql stable security definer set search_path = public as $$
 select value #>> '{}' from public.app_config where key='vapid_public_key';
$$;
revoke all on function public.push_public_config() from public,anon,authenticated;
grant execute on function public.push_public_config() to authenticated;
-- Owner may later set app_config.value to a JSON string containing the PUBLIC key in test.

-- Transfer a physical device's opaque token on account switch. No token is returned or disclosed.
create or replace function public.push_register_device(p_token text,p_platform text,p_token_type text) returns void
language plpgsql security definer set search_path = public as $$
begin
 if auth.uid() is null or public.is_banned(auth.uid()) then raise exception 'not authorized'; end if;
 if not exists (select 1 from public.notification_prefs where user_id=auth.uid() and enabled) then return; end if;
 insert into public.device_tokens(user_id,platform,token_type,token) values(auth.uid(),p_platform,p_token_type,p_token)
 on conflict(token) do update set user_id=excluded.user_id,platform=excluded.platform,token_type=excluded.token_type,enabled=true,last_seen_at=now();
end $$;
revoke all on function public.push_register_device(text,text,text) from public,anon,authenticated;
grant execute on function public.push_register_device(text,text,text) to authenticated;

-- Keep the existing ranking functions/signatures untouched. Filter is_test even for an admin actor.
create or replace function public.push_lb_snapshot() returns jsonb
language sql volatile security definer set search_path = public as $$
 with weights as (
   select w.* from public.lb_weight_cand() w join public.catches c on c.id=w.id
    where w.ok and not c.is_test and not c.admin_excluded and c.leaderboard_eligible
      and not exists(select 1 from public.founders_excluded f where f.user_id=w.user_id)
 ), best as (
   select distinct on(user_id) * from weights order by user_id,weight_kg desc,date,created_at
 ), winners as (
   (select 'biggest'::text board,''::text species,user_id,weight_kg value from best order by weight_kg desc,date,created_at limit 1)
   union all
   select 'species_record',species,user_id,weight_kg from (
     select distinct on(species) * from weights order by species,weight_kg desc,date,created_at
   ) s
   union all
   select 'quantity','',s.user_id,s.catch_count::numeric from public.lb_stats_rows('all','quantity') s where s.pos=1
   union all
   select 'species','',s.user_id,s.species_count::numeric from public.lb_stats_rows('all','species') s where s.pos=1
 ) select coalesce(jsonb_agg(to_jsonb(w)),'[]'::jsonb) from winners w;
$$;
-- lb_stats_rows sees the actor's auth claims. The trigger below temporarily clears the claims
-- during snapshots so is_admin() cannot include is_test catches in quantity/species rankings.

create or replace function public.push_enqueue_one(p_user uuid,p_type text,p_board text,p_species text) returns void
language plpgsql security definer set search_path = public as $$
declare
 hk timestamp := now() at time zone 'Asia/Hong_Kong'; due timestamptz := now();
 label text; msg text;
begin
 if p_user is null or public.is_banned(p_user)
   or not exists(select 1 from public.users where id=p_user)
   or exists(select 1 from public.founders_excluded where user_id=p_user)
   or not exists(select 1 from public.notification_prefs p where p.user_id=p_user and p.enabled
      and case p_type when 'record_broken' then p.record_broken else p.overtaken end)
   or not exists(select 1 from public.device_tokens t where t.user_id=p_user and t.enabled) then return; end if;
 if hk::time >= time '22:00' then due := ((hk::date+1)+time '08:00') at time zone 'Asia/Hong_Kong';
 elsif hk::time < time '08:00' then due := (hk::date+time '08:00') at time zone 'Asia/Hong_Kong'; end if;
 label := case p_board when 'biggest' then '重量王者（全期）' when 'quantity' then '數量王者（全期）' when 'species' then '品種王者（全期）' else p_species || '嘅最重紀錄' end;
 msg := case when p_type='record_broken' then
   case when p_board='species_record' then '恭喜！你刷新咗' || label || '！' else '恭喜！你登上' || label || '第 1 名' end
   else '有人超越咗你喺' || label || '，快啲返嚟奪回！' end;
 insert into public.notification_outbox(user_id,type,board,species,dedupe_key,notification_day,title,body,data,send_after)
 values(p_user,p_type,p_board,nullif(p_species,''),p_board||':'||coalesce(p_species,''),(due at time zone 'Asia/Hong_Kong')::date,
   '釣港',msg,jsonb_build_object('view','leaderboard','lbType',case when p_board='species_record' then 'biggest' else p_board end,'lbPeriod','all'),due)
 on conflict(user_id,type,dedupe_key,notification_day) do nothing;
end $$;

create or replace function public.push_enqueue_lb_changes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
 actor uuid; before_rows jsonb; after_rows jsonb; n jsonb; old_row jsonb;
 claims text; legacy_sub text; event_key text;
begin
 if TG_TABLE_NAME='catches' then
   if not new.leaderboard_eligible or new.is_test or new.admin_excluded then return new; end if;
   if TG_OP='UPDATE' then
     if old.leaderboard_eligible or old.admin_excluded or old.is_test then return new; end if;
   end if;
   actor := new.user_id;
 elsif TG_TABLE_NAME='lb_catch_approval' then
   select c.user_id into actor from public.catches c where c.id=new.catch_id and c.leaderboard_eligible and not c.is_test and not c.admin_excluded;
 elsif TG_TABLE_NAME='lb_species_review' then
   if new.status<>'approved' then return new; end if;
   if TG_OP='UPDATE' then if old.status='approved' then return new; end if; end if;
   select c.user_id into actor from public.catches c where c.id=new.catch_id and c.leaderboard_eligible and not c.is_test and not c.admin_excluded;
 elsif TG_TABLE_NAME='lb_review' then
   if new.status<>'approved' then return new; end if;
   if TG_OP='UPDATE' then if old.status='approved' then return new; end if; end if;
   select c.user_id into actor from public.catches c where c.trip_id=new.trip_id and c.species=new.species and c.leaderboard_eligible and not c.is_test and not c.admin_excluded limit 1;
 end if;
 if actor is null or public.is_banned(actor) or exists(select 1 from public.founders_excluded where user_id=actor) then return new; end if;
 -- Transaction-scoped serialization prevents two simultaneous approvals claiming the same before image.
 perform pg_advisory_xact_lock(200,1);
 claims := current_setting('request.jwt.claims',true); legacy_sub := current_setting('request.jwt.claim.sub',true);
 perform set_config('request.jwt.claims','{}',true); perform set_config('request.jwt.claim.sub','',true);
 after_rows := public.push_lb_snapshot();
 perform set_config('request.jwt.claims',coalesce(claims,''),true); perform set_config('request.jwt.claim.sub',coalesce(legacy_sub,''),true);
 event_key := txid_current()::text || ':' || TG_TABLE_NAME || ':' || coalesce(to_jsonb(new)->>'id',to_jsonb(new)->>'catch_id',coalesce(to_jsonb(new)->>'user_id',to_jsonb(new)->>'trip_id') || ':' || (to_jsonb(new)->>'species'));
 if TG_WHEN='BEFORE' then
   delete from public.lb_notify_state where created_at < now()-interval '1 day';
   insert into public.lb_notify_state(id,snapshot) values(event_key,after_rows) on conflict(id) do update set snapshot=excluded.snapshot;
 else
   delete from public.lb_notify_state where id=event_key returning snapshot into before_rows;
   if before_rows is null then return new; end if;
   for n in select * from jsonb_array_elements(after_rows) loop
     select x into old_row from jsonb_array_elements(before_rows) x where x->>'board'=n->>'board' and x->>'species'=n->>'species';
     -- Quantity/species incumbents are not records: notify only when the holder changes.
     if n->>'board' in ('quantity','species') and old_row is not null
        and n->>'user_id'=old_row->>'user_id' then continue; end if;
     -- Only a new public catch/review by the actual new leader may generate notifications.
     if (n->>'user_id')::uuid=actor and (old_row is null or
          ((n->>'value')::numeric >= (old_row->>'value')::numeric and
           (n->>'user_id'<>old_row->>'user_id' or (n->>'value')::numeric > (old_row->>'value')::numeric))) then
       perform public.push_enqueue_one(actor,'record_broken',n->>'board',n->>'species');
       if old_row is not null and old_row->>'user_id'<>n->>'user_id' then
         perform public.push_enqueue_one((old_row->>'user_id')::uuid,'overtaken',n->>'board',n->>'species');
       end if;
     end if;
   end loop;

 end if;
 return new;
exception when others then
 -- This block runs for BOTH BEFORE and AFTER. Roll back only notification work,
 -- including temporary auth claims, so a push failure never rejects a catch/review.
 return new;
end $$;
-- BEFORE name sorts after the existing eligibility BEFORE triggers.
do $$ declare t text; begin
 foreach t in array array['catches','lb_catch_approval','lb_species_review','lb_review'] loop
   execute format('drop trigger if exists zz_push_before on public.%I',t);
   execute format('drop trigger if exists zz_push_after on public.%I',t);
   execute format('create trigger zz_push_before before insert or update on public.%I for each row execute function public.push_enqueue_lb_changes()',t);
   execute format('create trigger zz_push_after after insert or update on public.%I for each row execute function public.push_enqueue_lb_changes()',t);
 end loop;
end $$;

create or replace function public.push_claim_outbox(p_limit integer default 50)
returns setof public.notification_outbox language plpgsql security definer set search_path = public as $$
begin
 -- Recheck preferences/bans at send time, including jobs deferred overnight.
 update public.notification_outbox o set status='skipped' where o.status in ('pending','sending') and (
   public.is_banned(o.user_id) or exists(select 1 from public.founders_excluded f where f.user_id=o.user_id)
   or not exists(select 1 from public.notification_prefs p where p.user_id=o.user_id and p.enabled and case o.type when 'record_broken' then p.record_broken else p.overtaken end)
   or not exists(select 1 from public.device_tokens d where d.user_id=o.user_id and d.enabled));
 update public.notification_outbox o set status='failed' where status='sending' and attempts>=5 and claimed_at<now()-interval '10 minutes';
 update public.notification_outbox o set status='skipped' where o.status='pending' and exists(
   select 1 from public.notification_outbox s where s.id<>o.id and s.user_id=o.user_id and s.type=o.type and s.dedupe_key=o.dedupe_key
   and s.sent_at >= (date_trunc('day',now() at time zone 'Asia/Hong_Kong') at time zone 'Asia/Hong_Kong'));
 -- Never send at night, even when a scheduler retries an older daytime job.
 if (now() at time zone 'Asia/Hong_Kong')::time >= time '22:00'
    or (now() at time zone 'Asia/Hong_Kong')::time < time '08:00' then return; end if;
 return query
 with due as (
   select id from public.notification_outbox where send_after<=now() and attempts<5
     and (status='pending' or (status='sending' and claimed_at < now()-interval '10 minutes'))
     and not exists(select 1 from public.notification_outbox older where older.user_id=notification_outbox.user_id and older.type=notification_outbox.type and older.dedupe_key=notification_outbox.dedupe_key and older.status in ('pending','sending') and (older.send_after,older.id)<(notification_outbox.send_after,notification_outbox.id))
   order by send_after for update skip locked limit greatest(1,least(p_limit,100))
 ) update public.notification_outbox o set status='sending',claim_id=gen_random_uuid(),claimed_at=now(),attempts=o.attempts+1
   from due where o.id=due.id returning o.*;
end $$;

-- Service-only send-time authorization, including changes after a job was claimed.
create or replace function public.push_delivery_allowed(p_job uuid,p_claim uuid,p_device uuid) returns boolean
language sql volatile security definer set search_path = public as $$
 select exists(select 1 from public.notification_outbox o
 join public.notification_prefs p on p.user_id=o.user_id
 join public.device_tokens d on d.user_id=o.user_id and d.id=p_device
 where o.id=p_job and o.claim_id=p_claim and o.status='sending' and d.enabled and p.enabled
 and case o.type when 'record_broken' then p.record_broken else p.overtaken end
 and not public.is_banned(o.user_id)
 and not exists(select 1 from public.founders_excluded f where f.user_id=o.user_id)
 and (now() at time zone 'Asia/Hong_Kong')::time >= time '08:00'
 and (now() at time zone 'Asia/Hong_Kong')::time < time '22:00');
$$;
revoke all on function public.push_delivery_allowed(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.push_delivery_allowed(uuid,uuid,uuid) to service_role;

-- Preserve the actual installed delete_my_account() implementation, including changes absent
-- from this repository. Wrap it once; rerunning this file must not wrap the wrapper again.
do $$ begin
 if to_regprocedure('public.push_delete_account_previous()') is null then
   if to_regprocedure('public.delete_my_account()') is null then raise exception 'delete_my_account missing; inspect test schema first'; end if;
   alter function public.delete_my_account() rename to push_delete_account_previous;
 end if;
end $$;
revoke all on function public.push_delete_account_previous() from public,anon,authenticated;
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
 if auth.uid() is null then raise exception 'not authenticated'; end if;
 delete from public.device_tokens where user_id=auth.uid();
 delete from public.notification_prefs where user_id=auth.uid();
 delete from public.notification_outbox where user_id=auth.uid();
 perform public.push_delete_account_previous();
end $$;
revoke all on function public.delete_my_account() from public,anon,authenticated;
grant execute on function public.delete_my_account() to authenticated;
revoke all on function public.push_lb_snapshot(),public.push_enqueue_one(uuid,text,text,text),public.push_enqueue_lb_changes(),public.push_claim_outbox(integer) from public,anon,authenticated;
grant execute on function public.push_claim_outbox(integer) to service_role;
commit;
