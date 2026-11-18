-- =============================================================================
--  0178_kount_ot_thread_quiet   ("Follow up" on quiet orders, admin v1.28 / phone v2.38)
--
--  The user (2026-11-18): "for any order without a new email in the thread for
--  over 3 days, needs a status marker saying followup required or something ...
--  it should also have a filter for those".
--
--    kount_ot_orders.last_email_at / last_email_from
--        the latest e-mail in the order's threads (its documents', the Inbox's and
--        its tracking's conversations), any sender - ours too: a message we sent
--        two days ago means we are waiting, not idle - no drafts, no bounces.
--        Stamped by the mail pull (kount-order-mail threadPhase, service role)
--        during the day's hourly check; only ever moves forward.
--    kount_ot_orders.thread_checked_at
--        when the pull last read the order's threads: the least recently checked
--        go first when a check runs out of time.
--    kount_ot_order_touch()
--        orders only: those stamps record e-mails, not an edit of the order, so
--        they leave updated_at alone (the Updated column, the follow-up timers of
--        0153). Every other update, a no-op one too, touches updated_at as
--        kount_ot_touch() does.
--
--  The screens flag an open order with a line not delivered yet when its last
--  e-mail (this, or 0153's last_vendor_email_at) is more than 3 days old.
--
--  Read = the table's existing grants / RLS; only the function writes these
--  columns. No data changes.
--
--  ROLLBACK: 0178_ROLLBACK_kount_ot_thread_quiet.sql
-- =============================================================================
begin;

alter table public.kount_ot_orders
  add column if not exists last_email_at timestamptz,
  add column if not exists last_email_from text,
  add column if not exists thread_checked_at timestamptz;

comment on column public.kount_ot_orders.last_email_at is 'The latest e-mail in the order''s threads, any sender (0178); stamped by the mail pull';
comment on column public.kount_ot_orders.last_email_from is 'Who sent that e-mail (0178): the address';
comment on column public.kount_ot_orders.thread_checked_at is 'When the mail pull last read the order''s threads (0178)';

create or replace function public.kount_ot_order_touch()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
begin
  -- the mail pull's thread stamps alone (0178) are not an update of the order
  if (to_jsonb(new) - '{updated_at,last_email_at,last_email_from,thread_checked_at}'::text[])
     = (to_jsonb(old) - '{updated_at,last_email_at,last_email_from,thread_checked_at}'::text[])
     and (new.last_email_at, new.last_email_from, new.thread_checked_at) is distinct from (old.last_email_at, old.last_email_from, old.thread_checked_at) then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end
$fn$;

drop trigger if exists kount_ot_orders_touch on public.kount_ot_orders;
create trigger kount_ot_orders_touch before update on public.kount_ot_orders
  for each row execute function public.kount_ot_order_touch();

commit;

-- check:
-- select (select count(*) from information_schema.columns where table_name = 'kount_ot_orders'
--          and column_name in ('last_email_at', 'last_email_from', 'thread_checked_at')) as cols,   -- 3
--        (select tgfoid::regproc::text from pg_trigger where tgname = 'kount_ot_orders_touch') as touch; -- kount_ot_order_touch
