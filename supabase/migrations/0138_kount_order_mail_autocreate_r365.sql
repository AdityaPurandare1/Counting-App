-- =============================================================================
--  0138_kount_order_mail_autocreate_r365   (orders without a click; Paid from R365)
--
--  1. The user (2026-11-02): the pull creates orders by itself from quotes
--     and invoices (kount_ot_mail_account.auto_create, default on). A quote /
--     invoice / confirmation that matches no order starts one — only when no
--     review check fires; the next documents of the thread then update it.
--  2. "Payments made or not can be pulled from R365 OData. Under transactions"
--     — KevaOS already syncs R365 transactions into ledger_journal_entries.
--     kount_ot_r365_ap(numbers, since) returns, for the vendors of those
--     invoice numbers, every AP Invoice and AP Payment since `since`, one row
--     per R365 transaction, read from the Accounts Payable rows only (indexed
--     by account + date: 0.1 s instead of 24 s over 2.2M rows). R365 payment
--     rows do not name the invoices they pay; kount-order-mail matches them by
--     company + amount (matchR365Payments) and marks those lines PAID.
--     Read-only on ledger_journal_entries (a KevaOS table; nothing added to it).
--  ROLLBACK: 0138_ROLLBACK_kount_order_mail_autocreate_r365.sql
-- =============================================================================
begin;

alter table public.kount_ot_mail_account add column if not exists auto_create boolean not null default true;

create or replace function public.kount_ot_mail_status()
returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_is_corporate() is not true then
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
$fn$;

create or replace function public.kount_ot_mail_set_auto_create(p_on boolean)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  update public.kount_ot_mail_account set auto_create = coalesce(p_on, true), updated_at = now() where id = 1;
end
$fn$;
revoke all on function public.kount_ot_mail_set_auto_create(boolean) from public, anon;
grant execute on function public.kount_ot_mail_set_auto_create(boolean) to authenticated;

create or replace function public.kount_ot_r365_ap(p_numbers text[], p_since date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v    jsonb;
  v_ap uuid[];
begin
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  -- the Accounts Payable accounts as a list FIRST: as a sub-select the planner scans all 2.2M rows (8 s timeout);
  -- as an array it uses the (gl_account_id, posting_date) index
  select array_agg(g.id) into v_ap from public.gl_accounts g where g.name ilike 'accounts payable%';
  with ap as (
    -- every R365 AP invoice and AP payment has exactly one row on an Accounts Payable account
    select e.r365_transaction_id, e.transaction_type as type, e.transaction_number as number, e.posting_date, e.venue_id,
           e.transaction_name, e.debit, e.credit
    from public.ledger_journal_entries e
    where e.gl_account_id = any(v_ap)
      and e.posting_date >= p_since
      and e.transaction_type in ('AP Invoice', 'AP Payment')
  ),
  ours as (
    -- "AP Invoice - <vendor> - <number>": the vendors of the asked invoices
    select distinct substr(a.transaction_name, 14, length(a.transaction_name) - 16 - length(a.number)) as vendor
    from ap a
    where a.type = 'AP Invoice' and a.number = any(p_numbers)
      and right(a.transaction_name, length(a.number) + 3) = ' - ' || a.number
  ),
  tx as (
    select a.type, a.number, min(a.posting_date)::text as date, min(a.venue_id::text) as venue, o.vendor,
           round(sum(case when a.type = 'AP Invoice' then a.credit - a.debit else a.debit - a.credit end), 2) as amount
    from ap a
    join ours o on left(a.transaction_name, length(a.type) + 6 + length(o.vendor)) = a.type || ' - ' || o.vendor || ' - '
    group by a.r365_transaction_id, a.type, a.number, o.vendor
  )
  select coalesce(jsonb_agg(to_jsonb(tx)), '[]'::jsonb) into v from tx;
  return v;
end
$fn$;
revoke all on function public.kount_ot_r365_ap(text[], date) from public, anon;
grant execute on function public.kount_ot_r365_ap(text[], date) to authenticated, service_role;

commit;
