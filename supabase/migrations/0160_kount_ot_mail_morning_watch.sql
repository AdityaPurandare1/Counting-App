-- =============================================================================
--  0160_kount_ot_mail_morning_watch   (the 9 o'clock pull cannot stop silently again)
--
--  2026-11-10: every 9 o'clock call (8:00-9:50 PT, 12 of them) got 401 "Missing
--  authorization header" from the edge gateway: the 11/09 deploy of kount-order-mail
--  went out without --no-verify-jwt (the repo had no config.toml), and the pg_cron
--  call signs nothing (x-kount-cron only). Nothing said so: cron.job_run_details reads
--  "succeeded" (the request was queued), and last_run simply did not move.
--  The user: "can we fix so the 9am run doesnt stop again".
--
--    kount_ot_mail_account.last_fetch_at      stamped by the function when a pull has
--                                             read the mail (not a 'continued' run)
--    kount_ot_mail_account.morning_request_id the job's last call (net._http_response id)
--    kount_ot_mail_account.morning_called_at  when it was made
--
--  The job: every 10 minutes, 9:00-13:59 Los Angeles time (16-21 UTC covers PDT and
--  PST), calling ONLY while today's mail is unread (last_fetch_at before 9:00 today):
--  one pull a morning, and a missed one is retried until 2 pm. It also sends the
--  public anon JWT (vault 'kount_edge_anon_jwt', the key the admin site ships), so the
--  gateway lets it through even if verify_jwt is ever switched on again.
--  The function makes the same decision (scheduledPullDue, shared orderTracker.ts).
--
--  kount_ot_mail_status adds last_fetch_at and morning {called_at, status, error}:
--  the admin's bell and Inbox warn from 10:00 when today's mail is unread, with why.
-- =============================================================================
begin;

alter table public.kount_ot_mail_account add column if not exists last_fetch_at timestamptz;
alter table public.kount_ot_mail_account add column if not exists morning_request_id bigint;
alter table public.kount_ot_mail_account add column if not exists morning_called_at timestamptz;
comment on column public.kount_ot_mail_account.last_fetch_at is 'When a pull last read the mail (0160); the 9 o''clock job retries until 2 pm while it is before 9:00 today';
comment on column public.kount_ot_mail_account.morning_request_id is 'The 9 o''clock job''s last call (net._http_response.id, 0160), for the admin''s "why"';
comment on column public.kount_ot_mail_account.morning_called_at is 'When the 9 o''clock job last called the function (0160)';

-- the last pull that read the mail before this: 11/09 11:34 PT (Aditya's Pull now); 11/10's 9 o'clock never ran
update public.kount_ot_mail_account set last_fetch_at = '2026-11-09T19:34:02.450Z' where id = 1 and last_fetch_at is null;

select cron.alter_job(
  job_id   := (select jobid from cron.job where jobname = 'kount-order-mail-morning'),
  schedule := '*/10 16-21 * * *',
  command  := $cmd$
  update public.kount_ot_mail_account
     set morning_request_id = net.http_post(
           url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-order-mail',
           headers := jsonb_strip_nulls(jsonb_build_object(
             'Content-Type', 'application/json',
             'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'kount_edge_anon_jwt'),
             'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron'))),
           body := '{"action":"cron"}'::jsonb,
           timeout_milliseconds := 10000),
         morning_called_at = now()
   where id = 1
     and token_secret_id is not null
     and extract(hour from now() at time zone 'America/Los_Angeles') between 9 and 13
     and (last_fetch_at is null
          or last_fetch_at < (date_trunc('day', now() at time zone 'America/Los_Angeles') + interval '9 hours') at time zone 'America/Los_Angeles')
  $cmd$);

create or replace function public.kount_ot_mail_status()
returns jsonb
language plpgsql
stable security definer
set search_path = public, pg_temp
as $$
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  return (select jsonb_build_object(
      'mailbox', a.mailbox, 'connected', a.token_secret_id is not null, 'connected_by', a.connected_by, 'connected_at', a.connected_at,
      'signing_in', a.device_code is not null and a.device_code_expires_at > now(),
      'vendor_domains', to_jsonb(a.vendor_domains), 'doc_kinds', to_jsonb(a.doc_kinds), 'auto_create', a.auto_create, 'suggested_domains', a.suggested_domains,
      'fetched_through', a.fetched_through,
      'running', a.running_since is not null and a.running_since > now() - interval '10 minutes',
      'last_run', a.last_run,
      -- 0160: when the mail was last read, and what the 9 o'clock job's last call got back
      'last_fetch_at', a.last_fetch_at,
      'morning', jsonb_build_object(
        'called_at', a.morning_called_at,
        'status', (select r.status_code from net._http_response r where r.id = a.morning_request_id),
        'error', (select left(coalesce(r.error_msg, case when r.status_code >= 300 then r.content::text end), 300)
                    from net._http_response r where r.id = a.morning_request_id)))
    from public.kount_ot_mail_account a where a.id = 1);
end
$$;

commit;

-- verification: the job's new schedule and gate, the columns, and the key it signs with
select (select schedule from cron.job where jobname = 'kount-order-mail-morning') as schedule,
       (select position('kount_edge_anon_jwt' in command) > 0 and position('last_fetch_at' in command) > 0 from cron.job where jobname = 'kount-order-mail-morning') as job_gated_and_signed,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kount_ot_mail_account'
          and column_name in ('last_fetch_at', 'morning_request_id', 'morning_called_at')) as new_columns,
       (select count(*) from vault.secrets where name = 'kount_edge_anon_jwt') as anon_key_in_vault;
