-- Rollback for 0160_kount_ot_mail_morning_watch: the job as it was (9 o'clock hour only, no gate, no anon key),
-- the status RPC as it was, the three columns dropped. Deploy an admin / kount-order-mail that do not read them first.
-- (The vault secret 'kount_edge_anon_jwt' is left; it is the public anon key.)
begin;

select cron.alter_job(
  job_id   := (select jobid from cron.job where jobname = 'kount-order-mail-morning'),
  schedule := '*/10 16,17 * * *',
  command  := $cmd$
  select net.http_post(
    url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-order-mail',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron')),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 10000)
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
      'last_run', a.last_run)
    from public.kount_ot_mail_account a where a.id = 1);
end
$$;

alter table public.kount_ot_mail_account drop column if exists morning_called_at;
alter table public.kount_ot_mail_account drop column if exists morning_request_id;
alter table public.kount_ot_mail_account drop column if exists last_fetch_at;

commit;
