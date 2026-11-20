-- =============================================================================
--  0165_kount_ot_venue_scope   (SECURITY: order tracker by venue)
--
--  2026-11-10, Aditya: "create the security such that i can give access to
--  managers to the order tracker as well but only for the venues that they are
--  at" -- the full tracker (prices, quotes, documents, editing) for their venues,
--  the warehouse complete, given per person (the Order tracker tick in User access).
--
--  The rule: Order tracker + All venues (or a Keva global corporate) = every venue,
--  as today; Order tracker WITHOUT All venues = only the venues on their account
--  (app_users.venue_ids). All 14 people holding it on 11/10 have All venues, so
--  nobody's access changes here (guarded below).
--  For someone limited to their venues:
--    orders      theirs + shared (multi-venue) orders with a line of theirs; they
--                create orders only for their venues; header changes / delete only
--                on an order wholly theirs (its venue theirs, no other venue's line)
--    lines       only their venues' (a line without a venue goes with its order)
--    documents   only on orders wholly theirs (a shared order's PDF shows others' prices)
--    events, tracking   of orders they see (tracking changed/removed only on theirs)
--    bibles      their venues'
--    warehouse   items + stock moves all visible; a document may add a catalog item;
--                item edits and stock moves for all venues only
--    inbox, mailbox settings, R365 payments lookup   all venues only
--    storage     kount-order-docs: their documents / bibles, or a fresh upload no row
--                claims yet (the review stores the PDF before its document exists)
--  The Order prices permission reads under the same venue rule.
--  Helpers (SECURITY DEFINER, so the policies don't recurse): kount_ot_scope,
--  kount_ot_order_venue, kount_ot_order_visible, kount_ot_order_mine,
--  kount_ot_line_visible, kount_ot_object_visible.
--  NOTE for 0154 (Venue orders, not applied): its kount_ot_venue_scope() returns
--  null (= every venue) for anyone with Order tracker; after this, use
--  kount_ot_scope() instead, or a venue-limited tracker user would see every venue there.
--  The kount-order-mail Edge Function needs All venues for its user calls too
--  (redeploy with this).
--  ROLLBACK: 0165_ROLLBACK_kount_ot_venue_scope.sql
-- =============================================================================
begin;

do $$
declare v text;
begin
  select string_agg(email, ', ') into v from public.app_users
   where is_active and ('purchasing:order-tracker' = any (features) or 'purchasing:order-prices' = any (features))
     and not 'access:all-venues' = any (features);
  if v is not null then
    raise exception '0165: these people hold Order tracker / Order prices without All venues and would be limited to their venues: %', v;
  end if;
end $$;

-- ── the caller's venues ────────────────────────────────────────────────────────────────
-- null = every venue (All venues, a Keva global corporate, or the service role); else the venues on
-- their account ('{}' = none). The Order tracker permission no longer means every venue by itself.
create or replace function public.kount_ot_scope()
returns text[] language sql stable security definer set search_path = public as $$
  select case
           when coalesce(auth.role(), '') = 'service_role' then null
           when public.kount_is_corporate() then null
           else coalesce((select u.venue_ids from public.app_users u
                           where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and u.is_active = true
                           limit 1), '{}'::text[])
         end;
$$;

-- an order's venue (definer: the lines / documents policies read orders without recursing into theirs)
create or replace function public.kount_ot_order_venue(p_order uuid)
returns text language sql stable security definer set search_path = public as $$
  select o.venue_id from public.kount_ot_orders o where o.id = p_order;
$$;

-- an order the caller sees: every venue, its venue is theirs, or a line on it is for their venue (a shared order)
create or replace function public.kount_ot_order_visible(p_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or exists (select 1 from public.kount_ot_orders o where o.id = p_order and o.venue_id = any (x.s))
      or exists (select 1 from public.kount_ot_lines l where l.order_id = p_order and l.venue_id = any (x.s))
    from (select public.kount_ot_scope() as s) x;
$$;

-- an order wholly the caller's: its venue is theirs and no line on it is for another venue
create or replace function public.kount_ot_order_mine(p_order uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or (exists (select 1 from public.kount_ot_orders o where o.id = p_order and o.venue_id = any (x.s))
          and not exists (select 1 from public.kount_ot_lines l
                           where l.order_id = p_order and l.venue_id is not null and not (l.venue_id = any (x.s))))
    from (select public.kount_ot_scope() as s) x;
$$;

-- a line for the caller's venues (its own venue, or none and its order's)
create or replace function public.kount_ot_line_visible(p_line uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or exists (select 1 from public.kount_ot_lines l join public.kount_ot_orders o on o.id = l.order_id
                  where l.id = p_line and (l.venue_id = any (x.s) or (l.venue_id is null and o.venue_id = any (x.s))))
    from (select public.kount_ot_scope() as s) x;
$$;

-- a file in kount-order-docs the caller may open: a document on an order wholly theirs, their venue's bible,
-- or a fresh upload nothing claims yet (the review stores the PDF before its document row exists)
create or replace function public.kount_ot_object_visible(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or exists (select 1 from public.kount_ot_documents d where d.storage_path = p_name and public.kount_ot_order_mine(d.order_id))
      or exists (select 1 from public.kount_ot_bibles b where b.storage_path = p_name and b.venue_id = any (x.s))
      or (not exists (select 1 from public.kount_ot_documents d where d.storage_path = p_name)
          and not exists (select 1 from public.kount_ot_bibles b where b.storage_path = p_name)
          and not exists (select 1 from public.kount_ot_inbox i where i.storage_path = p_name))
    from (select public.kount_ot_scope() as s) x;
$$;

revoke all on function public.kount_ot_scope(), public.kount_ot_order_venue(uuid), public.kount_ot_order_visible(uuid),
  public.kount_ot_order_mine(uuid), public.kount_ot_line_visible(uuid), public.kount_ot_object_visible(text) from public, anon;
grant execute on function public.kount_ot_scope(), public.kount_ot_order_venue(uuid), public.kount_ot_order_visible(uuid),
  public.kount_ot_order_mine(uuid), public.kount_ot_line_visible(uuid), public.kount_ot_object_visible(text) to authenticated, service_role;

-- ── the policies (all replaced; per command where the rule differs) ────────────────────
drop policy if exists kount_ot_bibles_read on public.kount_ot_bibles;
drop policy if exists kount_ot_bibles_write on public.kount_ot_bibles;
drop policy if exists kount_ot_documents_read on public.kount_ot_documents;
drop policy if exists kount_ot_documents_write on public.kount_ot_documents;
drop policy if exists kount_ot_events_corporate_read on public.kount_ot_events;
drop policy if exists kount_ot_inbox_corporate_read on public.kount_ot_inbox;
drop policy if exists kount_ot_inbox_corporate_update on public.kount_ot_inbox;
drop policy if exists kount_ot_items_read on public.kount_ot_items;
drop policy if exists kount_ot_items_write on public.kount_ot_items;
drop policy if exists kount_ot_lines_read on public.kount_ot_lines;
drop policy if exists kount_ot_lines_write on public.kount_ot_lines;
drop policy if exists kount_ot_orders_read on public.kount_ot_orders;
drop policy if exists kount_ot_orders_write on public.kount_ot_orders;
drop policy if exists kount_ot_stock_moves_read on public.kount_ot_stock_moves;
drop policy if exists kount_ot_stock_moves_write on public.kount_ot_stock_moves;
drop policy if exists kount_ot_tracking_read on public.kount_ot_tracking;
drop policy if exists kount_ot_tracking_write on public.kount_ot_tracking;
drop policy if exists kount_order_docs_delete on storage.objects;
drop policy if exists kount_order_docs_read on storage.objects;
drop policy if exists kount_order_docs_update on storage.objects;
drop policy if exists kount_order_docs_write on storage.objects;

create policy kount_ot_orders_read on public.kount_ot_orders for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or public.kount_ot_order_visible(id)));
create policy kount_ot_orders_insert on public.kount_ot_orders for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));
create policy kount_ot_orders_update on public.kount_ot_orders for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_order_mine(id))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));
create policy kount_ot_orders_delete on public.kount_ot_orders for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_order_mine(id));
create policy kount_ot_lines_read on public.kount_ot_lines for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));
create policy kount_ot_lines_insert on public.kount_ot_lines for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));
create policy kount_ot_lines_update on public.kount_ot_lines for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));
create policy kount_ot_lines_delete on public.kount_ot_lines for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));
create policy kount_ot_documents_read on public.kount_ot_documents for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));
create policy kount_ot_documents_write on public.kount_ot_documents for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));
create policy kount_ot_events_corporate_read on public.kount_ot_events for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or (public.kount_ot_order_visible(order_id) and (line_id is null or public.kount_ot_line_visible(line_id)))));
create policy kount_ot_tracking_read on public.kount_ot_tracking for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_visible(order_id)));
create policy kount_ot_tracking_insert on public.kount_ot_tracking for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_visible(order_id)));
create policy kount_ot_tracking_update on public.kount_ot_tracking for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));
create policy kount_ot_tracking_delete on public.kount_ot_tracking for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));
create policy kount_ot_inbox_corporate_read on public.kount_ot_inbox for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);
create policy kount_ot_inbox_corporate_update on public.kount_ot_inbox for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);
create policy kount_ot_bibles_read on public.kount_ot_bibles for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));
create policy kount_ot_bibles_write on public.kount_ot_bibles for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));
create policy kount_ot_items_read on public.kount_ot_items for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices')));
create policy kount_ot_items_insert on public.kount_ot_items for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')));
create policy kount_ot_items_update on public.kount_ot_items for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);
create policy kount_ot_items_delete on public.kount_ot_items for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);
create policy kount_ot_stock_moves_read on public.kount_ot_stock_moves for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices')));
create policy kount_ot_stock_moves_write on public.kount_ot_stock_moves for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);
create policy kount_order_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'kount-order-docs' and ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and public.kount_ot_object_visible(name));
create policy kount_order_docs_write on storage.objects for insert to authenticated
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')));
create policy kount_order_docs_update on storage.objects for update to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name))
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name));
create policy kount_order_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name));

-- ── the mailbox functions and the R365 lookup: all venues only ─────────────────────────
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
  -- 0165: The order mailbox is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The order mailbox is limited to people with All venues' using errcode = '42501';
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
  -- 0165: The order mailbox is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The order mailbox is limited to people with All venues' using errcode = '42501';
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
  -- 0165: The order mailbox is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The order mailbox is limited to people with All venues' using errcode = '42501';
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
  -- 0165: The order mailbox is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The order mailbox is limited to people with All venues' using errcode = '42501';
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
  -- 0165: The order mailbox is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The order mailbox is limited to people with All venues' using errcode = '42501';
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
  -- 0165: The R365 payments lookup is for all venues: a person limited to their venues may not use it
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_ot_scope() is not null then
    raise exception 'The R365 payments lookup is limited to people with All venues' using errcode = '42501';
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

-- check: every policy in place, the helpers callable
select 'policies' as k, count(*)::text as v from pg_policies
 where (schemaname = 'public' and tablename like 'kount_ot%') or (schemaname = 'storage' and policyname like 'kount_order_docs%')
union all select 'helpers', count(*)::text from pg_proc where proname in
  ('kount_ot_scope','kount_ot_order_venue','kount_ot_order_visible','kount_ot_order_mine','kount_ot_line_visible','kount_ot_object_visible');
commit;
