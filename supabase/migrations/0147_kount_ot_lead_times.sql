-- =============================================================================
--  0147_kount_ot_lead_times   (when an order went to the vendor, when it arrived)
--
--  The user (2026-11-03): "pull when the order was sent to the vendor along with
--  how many days/weeks/months has it been without confirming it was delivered
--  in the app so that data can be used to estimate lead time on products within
--  the bibles".
--
--    kount_ot_orders.sent_on / sent_source
--        email    the first e-mail from h.wood TO the vendor in the order's threads
--                 (the morning pull reads it; a forward to AP never counts)
--        sheet    the Order Date on the user's tracker sheet (import 2026-11-02)
--        po_date  only the PO date was known (an invoice's date: later than sent)
--        manual   typed in the order panel — the pull never overwrites it
--
--    kount_ot_lines.delivered_on / delivered_source
--        app      the day the line was first marked Delivered / Received in Kount
--                 (stamped by the trigger below, whichever path set the status)
--        eta      backfill: a line the sheet already had as delivered, dated by its
--                 ETA (no delivered date existed anywhere) — an estimate
--        manual   typed in the order panel
--
--  Lead time = delivered_on - sent_on; still open = today - sent_on.
-- =============================================================================
begin;

alter table public.kount_ot_orders
  add column if not exists sent_on date,
  add column if not exists sent_source text check (sent_source in ('email', 'sheet', 'po_date', 'manual'));

alter table public.kount_ot_lines
  add column if not exists delivered_on date,
  add column if not exists delivered_source text check (delivered_source in ('app', 'eta', 'manual'));

comment on column public.kount_ot_orders.sent_on is 'Day the order went to the vendor (0147); sent_source says how it is known';
comment on column public.kount_ot_lines.delivered_on is 'Day the line was delivered (0147): stamped when first marked Delivered/Received; delivered_source says how it is known';

-- the day a line becomes Delivered / Received, from whichever path moved it (the order panel, a document,
-- a delivery-status sheet); moved back before delivery or cancelled = not delivered any more
create or replace function public.kount_ot_line_delivered_on()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  was_delivered boolean := tg_op = 'UPDATE' and old.status in ('DELIVERED', 'RECEIVED');
begin
  if new.status in ('DELIVERED', 'RECEIVED') then
    -- only on the step into delivery: Delivered -> Received keeps the day it came (or that it is unknown)
    if new.delivered_on is null and not was_delivered then
      new.delivered_on := (now() at time zone 'America/Los_Angeles')::date;
      new.delivered_source := 'app';
    end if;
  elsif new.delivered_on is not null and (tg_op = 'INSERT' or was_delivered) then
    new.delivered_on := null;
    new.delivered_source := null;
  end if;
  if new.delivered_on is null then new.delivered_source := null; end if;
  return new;
end $$;

drop trigger if exists kount_ot_lines_delivered_on on public.kount_ot_lines;
create trigger kount_ot_lines_delivered_on
  before insert or update of status, delivered_on on public.kount_ot_lines
  for each row execute function public.kount_ot_line_delivered_on();

-- backfill: the sheet's Order Date, else the PO date (the morning pull replaces both with the e-mail's day)
update public.kount_ot_orders
   set sent_on = ordered_on,
       sent_source = case when notes like '%[sheet 2026-11-02]%' then 'sheet' else 'po_date' end
 where sent_on is null and ordered_on is not null;

-- backfill: every delivered line so far was marked on 11/2-11/3 (sheet import / delivery sheets), so that day
-- says nothing; its ETA is the best estimate there is (never later than the day it was marked)
update public.kount_ot_lines
   set delivered_on = least(expected_on, (status_at at time zone 'America/Los_Angeles')::date),
       delivered_source = 'eta'
 where status in ('DELIVERED', 'RECEIVED') and delivered_on is null and expected_on is not null;

commit;
