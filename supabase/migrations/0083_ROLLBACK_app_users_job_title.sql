begin;
alter table public.app_users drop column if exists job_title;
select ' rolled back 0083' as status;
commit;
