-- =============================================================================
--  0175_kount_ot_mail_stub_checks   (check stubs looked for again during the day)
--
--  The user (2026-11-17): "if the stubs are sent, can we get them checked again
--  during the day after the daily run please".
--
--  The 9 o'clock pull files the check stubs / payment proofs e-mailed from our own
--  mailbox once a day, so a stub sent to a vendor at 2 pm stayed under "Stubs to
--  send" until the next morning. This job calls kount-order-mail {action:'stub_check'}
--  once an hour at :30, 10:30-17:30 Los Angeles time (every hour UTC, gated here on
--  the Los Angeles hour, so PDT and PST both work), only once today's morning pull
--  has read the mail (last_fetch_at at or after 9:00 today) and Outlook is connected.
--  The function makes the same decision (stubCheckDue, shared orderTracker.ts) and
--  runs the stub step alone over the last 2 days of our own e-mails, under the
--  pull lock; what it found goes into last_run.stub_check (the morning's totals stay).
--
--  Same call as the morning job (0160): the anon JWT for the gateway and the
--  x-kount-cron secret, both from the vault. No table changes.
-- =============================================================================
begin;

select cron.schedule('kount-order-mail-stubs', '30 * * * *', $cmd$
  select net.http_post(
           url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-order-mail',
           headers := jsonb_strip_nulls(jsonb_build_object(
             'Content-Type', 'application/json',
             'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'kount_edge_anon_jwt'),
             'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron'))),
           body := '{"action":"stub_check"}'::jsonb,
           timeout_milliseconds := 10000)
    from public.kount_ot_mail_account a
   where a.id = 1
     and a.token_secret_id is not null
     and extract(hour from now() at time zone 'America/Los_Angeles') between 10 and 17
     and a.last_fetch_at >= (date_trunc('day', now() at time zone 'America/Los_Angeles') + interval '9 hours') at time zone 'America/Los_Angeles'
  $cmd$);

commit;
