-- =============================================================================
--  0136_kount_order_mail_doc_kinds   (which documents the morning pull takes)
--
--  The user (2026-11-02): "I only want invoices from EE for starters" — more
--  vendors get added one at a time. kount_ot_mail_account.doc_kinds says which
--  document types the pull takes ('invoice' also takes credit memos). With a
--  subset set, only attachments whose file name or email subject looks like one
--  of those types are opened at all, and a PDF the reader finds to be another
--  type is skipped (it can be brought back from the Inbox). Start: E&E only
--  (eemercantile.co), invoices only.
--  ROLLBACK: 0136_ROLLBACK_kount_order_mail_doc_kinds.sql
-- =============================================================================
begin;

alter table public.kount_ot_mail_account
  add column if not exists doc_kinds text[] not null default array['quote', 'confirmation', 'invoice', 'shipping'];

create or replace function public.kount_ot_mail_status()
returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  return (select jsonb_build_object(
      'mailbox', a.mailbox, 'connected', a.token_secret_id is not null, 'connected_by', a.connected_by, 'connected_at', a.connected_at,
      'signing_in', a.device_code is not null and a.device_code_expires_at > now(),
      'vendor_domains', to_jsonb(a.vendor_domains), 'doc_kinds', to_jsonb(a.doc_kinds), 'suggested_domains', a.suggested_domains,
      'fetched_through', a.fetched_through,
      'running', a.running_since is not null and a.running_since > now() - interval '10 minutes',
      'last_run', a.last_run)
    from public.kount_ot_mail_account a where a.id = 1);
end
$fn$;

create or replace function public.kount_ot_mail_set_doc_kinds(p_kinds text[])
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
declare v text[];
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}') into v
    from unnest(coalesce(p_kinds, '{}')) k where k in ('quote', 'confirmation', 'invoice', 'shipping');
  if cardinality(v) = 0 then raise exception 'Pick at least one document type'; end if;
  update public.kount_ot_mail_account set doc_kinds = v, updated_at = now() where id = 1;
end
$fn$;
revoke all on function public.kount_ot_mail_set_doc_kinds(text[]) from public, anon;
grant execute on function public.kount_ot_mail_set_doc_kinds(text[]) to authenticated;

-- the user's starting point: E&E invoices only
update public.kount_ot_mail_account set vendor_domains = array['eemercantile.co'], doc_kinds = array['invoice'], updated_at = now() where id = 1;

commit;
