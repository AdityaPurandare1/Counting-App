-- =============================================================================
--  0153_kount_ot_followups   (To send: follow-ups + payment requests, admin v1.04)
--
--  The user (2026-11-05): "a followup mechanism that would email on my behalf if we
--  dont get any update on an order for 3 days" + payment-request drafts (they write
--  "Payment Request - EE Mercantile (...) INV-... - $..." to AP for every invoice).
--  Drafts first: the admin lists what to send and Compose opens it filled in; when IT
--  grants mailbox write, the same list becomes real Outlook drafts.
--
--    kount_ot_followups            what was composed from To send: a vendor follow-up,
--                                  a payment request (its invoices), or "done for today"
--                                  on a reminder; who / which day stamped here
--    kount_ot_lines.pay_requested_at, ap_query_no
--                                  the mail pull finds the team's payment requests and
--                                  AP's 'Query No=...' replies (any sender of the team)
--    kount_ot_orders.last_vendor_email_at
--                                  the vendor's latest e-mail on the order (its thread /
--                                  its invoice #): a reply is an update, no follow-up
--  Read / log = purchasing:order-tracker (as every kount_ot_* table since 0149).
-- =============================================================================
begin;

alter table public.kount_ot_orders add column if not exists last_vendor_email_at timestamptz;
alter table public.kount_ot_lines add column if not exists pay_requested_at timestamptz;
alter table public.kount_ot_lines add column if not exists ap_query_no text;
comment on column public.kount_ot_lines.pay_requested_at is 'When a payment request for its invoice went to AP (0153, found in the mailbox)';
comment on column public.kount_ot_lines.ap_query_no is 'AP''s query number for that payment request (''Query No=005-485-081'')';
comment on column public.kount_ot_orders.last_vendor_email_at is 'The vendor''s latest e-mail on this order (0153): a reply counts as an update';

create table if not exists public.kount_ot_followups (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.kount_ot_orders (id) on delete cascade,
  kind             text not null check (kind in ('vendor', 'payment', 'self')),
  sent_on          date not null default ((now() at time zone 'America/Los_Angeles')::date),
  by_email         text,
  invoice_numbers  text[],
  note             text,
  created_at       timestamptz not null default now()
);
comment on table public.kount_ot_followups is 'Follow-ups / payment requests composed from the Order tracker''s To send (0153)';
create index if not exists kount_ot_followups_order_idx on public.kount_ot_followups (order_id, created_at desc);

-- who and which day come from the session, never from the client
create or replace function public.kount_ot_followup_stamp()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
begin
  new.by_email := coalesce(nullif(auth.jwt() ->> 'email', ''), current_user);
  new.sent_on := (now() at time zone 'America/Los_Angeles')::date;
  new.created_at := now();
  return new;
end
$fn$;
drop trigger if exists kount_ot_followups_stamp on public.kount_ot_followups;
create trigger kount_ot_followups_stamp before insert on public.kount_ot_followups
  for each row execute function public.kount_ot_followup_stamp();
revoke all on function public.kount_ot_followup_stamp() from public, anon, authenticated;

alter table public.kount_ot_followups enable row level security;
revoke all on table public.kount_ot_followups from public, anon, authenticated;
grant select, insert, delete on table public.kount_ot_followups to authenticated;
drop policy if exists kount_ot_followups_read on public.kount_ot_followups;
create policy kount_ot_followups_read on public.kount_ot_followups for select to authenticated
  using (public.kount_has_feature('purchasing:order-tracker'));
drop policy if exists kount_ot_followups_log on public.kount_ot_followups;
create policy kount_ot_followups_log on public.kount_ot_followups for insert to authenticated
  with check (public.kount_has_feature('purchasing:order-tracker'));
-- Undo: only your own, the same day
drop policy if exists kount_ot_followups_undo on public.kount_ot_followups;
create policy kount_ot_followups_undo on public.kount_ot_followups for delete to authenticated
  using (public.kount_has_feature('purchasing:order-tracker') and by_email = (auth.jwt() ->> 'email')
         and sent_on = (now() at time zone 'America/Los_Angeles')::date);

-- ── verification ─────────────────────────────────────────────────────────────
select (select count(*) from information_schema.columns where table_name = 'kount_ot_lines' and column_name in ('pay_requested_at', 'ap_query_no')) as line_cols,
       (select count(*) from information_schema.columns where table_name = 'kount_ot_orders' and column_name = 'last_vendor_email_at') as order_col,
       (select count(*) from pg_policies where tablename = 'kount_ot_followups') as policies;
-- expect: 2, 1, 3

commit;
