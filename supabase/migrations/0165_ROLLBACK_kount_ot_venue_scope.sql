-- ROLLBACK for 0165: the order tracker policies and the six functions exactly as they were
-- before (captured live on 2026-11-10), then the helpers dropped. Everyone with the Order
-- tracker permission sees every venue again.
begin;
drop policy if exists kount_ot_orders_read on public.kount_ot_orders;
drop policy if exists kount_ot_orders_insert on public.kount_ot_orders;
drop policy if exists kount_ot_orders_update on public.kount_ot_orders;
drop policy if exists kount_ot_orders_delete on public.kount_ot_orders;
drop policy if exists kount_ot_lines_read on public.kount_ot_lines;
drop policy if exists kount_ot_lines_insert on public.kount_ot_lines;
drop policy if exists kount_ot_lines_update on public.kount_ot_lines;
drop policy if exists kount_ot_lines_delete on public.kount_ot_lines;
drop policy if exists kount_ot_documents_read on public.kount_ot_documents;
drop policy if exists kount_ot_documents_write on public.kount_ot_documents;
drop policy if exists kount_ot_events_corporate_read on public.kount_ot_events;
drop policy if exists kount_ot_tracking_read on public.kount_ot_tracking;
drop policy if exists kount_ot_tracking_insert on public.kount_ot_tracking;
drop policy if exists kount_ot_tracking_update on public.kount_ot_tracking;
drop policy if exists kount_ot_tracking_delete on public.kount_ot_tracking;
drop policy if exists kount_ot_inbox_corporate_read on public.kount_ot_inbox;
drop policy if exists kount_ot_inbox_corporate_update on public.kount_ot_inbox;
drop policy if exists kount_ot_bibles_read on public.kount_ot_bibles;
drop policy if exists kount_ot_bibles_write on public.kount_ot_bibles;
drop policy if exists kount_ot_items_read on public.kount_ot_items;
drop policy if exists kount_ot_items_insert on public.kount_ot_items;
drop policy if exists kount_ot_items_update on public.kount_ot_items;
drop policy if exists kount_ot_items_delete on public.kount_ot_items;
drop policy if exists kount_ot_stock_moves_read on public.kount_ot_stock_moves;
drop policy if exists kount_ot_stock_moves_write on public.kount_ot_stock_moves;
drop policy if exists kount_order_docs_read on storage.objects;
drop policy if exists kount_order_docs_write on storage.objects;
drop policy if exists kount_order_docs_update on storage.objects;
drop policy if exists kount_order_docs_delete on storage.objects;

create policy kount_ot_bibles_read on public.kount_ot_bibles for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_bibles_write on public.kount_ot_bibles for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_documents_read on public.kount_ot_documents for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_documents_write on public.kount_ot_documents for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_events_corporate_read on public.kount_ot_events for select to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_inbox_corporate_read on public.kount_ot_inbox for select to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_inbox_corporate_update on public.kount_ot_inbox for update to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_items_read on public.kount_ot_items for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_items_write on public.kount_ot_items for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_lines_read on public.kount_ot_lines for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_lines_write on public.kount_ot_lines for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_orders_read on public.kount_ot_orders for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_orders_write on public.kount_ot_orders for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_stock_moves_read on public.kount_ot_stock_moves for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_stock_moves_write on public.kount_ot_stock_moves for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_ot_tracking_read on public.kount_ot_tracking for select to authenticated
  using ((kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text)));
create policy kount_ot_tracking_write on public.kount_ot_tracking for all to authenticated
  using (kount_has_feature('purchasing:order-tracker'::text))
  with check (kount_has_feature('purchasing:order-tracker'::text));
create policy kount_order_docs_delete on storage.objects for delete to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND kount_has_feature('purchasing:order-tracker'::text)));
create policy kount_order_docs_read on storage.objects for select to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND (kount_has_feature('purchasing:order-tracker'::text) OR kount_has_feature('purchasing:order-prices'::text))));
create policy kount_order_docs_update on storage.objects for update to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND kount_has_feature('purchasing:order-tracker'::text)))
  with check (((bucket_id = 'kount-order-docs'::text) AND kount_has_feature('purchasing:order-tracker'::text)));
create policy kount_order_docs_write on storage.objects for insert to authenticated
  with check (((bucket_id = 'kount-order-docs'::text) AND kount_has_feature('purchasing:order-tracker'::text)));

CREATE OR REPLACE FUNCTION public.kount_ot_mail_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.kount_ot_mail_disconnect()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  delete from vault.secrets where id = (select token_secret_id from public.kount_ot_mail_account where id = 1);
  update public.kount_ot_mail_account set token_secret_id = null, mailbox = null, connected_by = null, connected_at = null,
    device_code = null, device_code_expires_at = null, updated_at = now()
  where id = 1;
end
$function$
;

CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_auto_create(p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  update public.kount_ot_mail_account set auto_create = coalesce(p_on, true), updated_at = now() where id = 1;
end
$function$
;

CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_doc_kinds(p_kinds text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text[];
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}') into v
    from unnest(coalesce(p_kinds, '{}')) k where k in ('quote', 'confirmation', 'invoice', 'shipping');
  if cardinality(v) = 0 then raise exception 'Pick at least one document type'; end if;
  update public.kount_ot_mail_account set doc_kinds = v, updated_at = now() where id = 1;
end
$function$
;

CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_domains(p_domains text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text[];
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct d order by d), '{}') into v
    from (select lower(btrim(regexp_replace(x, '^.*@', ''))) as d from unnest(coalesce(p_domains, '{}')) x) t
   where d ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' and d not in ('hwoodgroup.com');
  update public.kount_ot_mail_account set vendor_domains = v,
    suggested_domains = suggested_domains - v,
    updated_at = now() where id = 1;
end
$function$
;

CREATE OR REPLACE FUNCTION public.kount_ot_r365_ap(p_numbers text[], p_since date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v    jsonb;
  v_ap uuid[];
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true and coalesce(auth.role(), '') <> 'service_role' then
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
    -- "AP Invoice - <vendor> - <number>": the vendors of the asked invoices. R365 also posts an invoice as
    -- "INV-2026-857309 Delilah LA" (split per venue), "INV-2026-291876/2", "INV-2026-688306-D" — the
    -- INV-yyyy-nnnnnn token is what matches
    select distinct substr(a.transaction_name, 14, length(a.transaction_name) - 16 - length(a.number)) as vendor
    from ap a
    where a.type = 'AP Invoice' and upper(substring(a.number from '(?i)INV-[0-9]{4}-[0-9]{5,7}')) = any(p_numbers)
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
$function$
;

drop function if exists public.kount_ot_object_visible(text);
drop function if exists public.kount_ot_line_visible(uuid);
drop function if exists public.kount_ot_order_mine(uuid);
drop function if exists public.kount_ot_order_visible(uuid);
drop function if exists public.kount_ot_order_venue(uuid);
drop function if exists public.kount_ot_scope();
commit;
