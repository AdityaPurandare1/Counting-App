-- Rollback for 0176_kount_price_check: the two jobs, the four functions and the four tables (every check with them).
-- Undeploy or ignore kount-price-check first (it only answers people and the jobs).
begin;
select cron.unschedule('kount-price-check-work');
select cron.unschedule('kount-price-check-weekly');
drop function if exists public.kount_pc_claim(int);
drop function if exists public.kount_pc_run_add(uuid, numeric, int);
drop function if exists public.kount_pc_set_quote(uuid, text, text, numeric, text);
drop function if exists public.kount_pc_set_settings(boolean, numeric, numeric, text);
drop table if exists public.kount_pc_checks;
drop table if exists public.kount_pc_items;
drop table if exists public.kount_pc_runs;
drop table if exists public.kount_pc_settings;
commit;
