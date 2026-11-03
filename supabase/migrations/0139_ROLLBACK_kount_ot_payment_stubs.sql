-- ROLLBACK for 0139_kount_ot_payment_stubs: removes the check-stub documents and the
-- 'payment' kind, and puts 0138's exact-number kount_ot_r365_ap back.
begin;
delete from public.kount_ot_documents where kind = 'payment';
alter table public.kount_ot_documents drop constraint if exists kount_ot_documents_kind_check;
alter table public.kount_ot_documents add constraint kount_ot_documents_kind_check
  check (kind in ('quote', 'confirmation', 'invoice', 'shipping', 'other'));
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
commit;
