-- ROLLBACK for 0136_kount_order_mail_doc_kinds: back to every document type
-- (0135's status function). The vendor list is left as it is.
begin;
drop function if exists public.kount_ot_mail_set_doc_kinds(text[]);
create or replace function public.kount_ot_mail_status()
returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  return (select jsonb_build_object(
      'mailbox', a.mailbox, 'connected', a.token_secret_id is not null, 'connected_by', a.connected_by, 'connected_at', a.connected_at,
      'signing_in', a.device_code is not null and a.device_code_expires_at > now(),
      'vendor_domains', to_jsonb(a.vendor_domains), 'suggested_domains', a.suggested_domains,
      'fetched_through', a.fetched_through,
      'running', a.running_since is not null and a.running_since > now() - interval '10 minutes',
      'last_run', a.last_run)
    from public.kount_ot_mail_account a where a.id = 1);
end
$fn$;
alter table public.kount_ot_mail_account drop column if exists doc_kinds;
commit;
