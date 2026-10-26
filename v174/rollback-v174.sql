-- v174 rollback：刪走創始釣友 trigger／函數／表（已派嘅號會冇咗；要保留就先 export founders）
begin;
drop trigger if exists trg_founders_assign on public.catches;
drop function if exists public.founders_assign();
drop function if exists public.lb_founder_nos(uuid[]);
drop function if exists public.my_founder_no();
drop function if exists public.founder_remaining();
drop table if exists public.founders;
commit;
