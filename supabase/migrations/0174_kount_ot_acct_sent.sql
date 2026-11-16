-- =============================================================================
--  0174_kount_ot_acct_sent   (invoices sent to accounting, admin v1.20)
--
--  The user (2026-11-16): "1 more distinction for the invoices we receive. I want it
--  to scan if those invoices are being sent to accounting. hwoodap@iqbackoffice.com
--  and hwoodga@iqbackoffice.com ... These are the 2 emails where things go either of
--  them".
--
--    kount_ot_lines.acct_sent_at / acct_sent_to / acct_sent_by / acct_sent_subject /
--    acct_message_id
--        the first e-mail to either mailbox (to / cc / bcc) naming the line's invoice
--        number in its subject, body or attachment names, stamped by the mail pull
--        (kount-order-mail accountingPhase, service role); acct_sent_to = every one of
--        the two it went to ('AP', 'GA', 'AP, GA')
--    kount_ot_line_touch()
--        lines only: those stamps record an e-mail of the past, so they leave
--        updated_at alone — the first pull stamps 90 days of e-mails, which must not
--        make every order look updated today (Updated column, follow-up timers).
--        Every other update (a no-op one too) still touches updated_at as
--        kount_ot_touch() does. A line whose invoice # changes to another
--        invoice loses the stamps (and 0153's pay_requested_at / ap_query_no),
--        so the new invoice is never shown as sent on the old one's e-mail.
--    kount_ot_inv_token(text)   the pull's invoiceToken, for that comparison
--
--  The pull (kount-order-mail accountingPhase) searches Outlook per unpaid,
--  not-yet-found invoice; our own e-mail to AP / GA also sets pay_requested_at
--  (it is the payment request), a vendor's own does not.
--
--  Read = the table's existing grants / RLS (purchasing:order-tracker); only the
--  function writes these columns. No data changes.
-- =============================================================================
begin;

alter table public.kount_ot_lines add column if not exists acct_sent_at timestamptz;
alter table public.kount_ot_lines add column if not exists acct_sent_to text;
alter table public.kount_ot_lines add column if not exists acct_sent_by text;
alter table public.kount_ot_lines add column if not exists acct_sent_subject text;
alter table public.kount_ot_lines add column if not exists acct_message_id text;
comment on column public.kount_ot_lines.acct_sent_at is 'When its invoice was first e-mailed to accounting (hwoodap@ / hwoodga@iqbackoffice.com), found by the mail pull (0174)';
comment on column public.kount_ot_lines.acct_sent_to is 'Which accounting mailboxes its invoice went to: AP, GA or AP, GA (0174)';
comment on column public.kount_ot_lines.acct_sent_by is 'Who sent that first e-mail to accounting (0174)';
comment on column public.kount_ot_lines.acct_sent_subject is 'That e-mail''s subject (0174)';
comment on column public.kount_ot_lines.acct_message_id is 'That e-mail''s Outlook (immutable) id (0174)';

-- an invoice # as the pull compares them (invoiceToken): E&E's INV-2026-123456 out of a longer text, else upper-trimmed
create or replace function public.kount_ot_inv_token(p text)
returns text language sql immutable set search_path to 'public', 'pg_temp' as $fn$
  select coalesce(substring(upper(coalesce(p, '')) from 'INV-[0-9]{4}-[0-9]{5,7}'), upper(trim(coalesce(p, ''))))
$fn$;

create or replace function public.kount_ot_line_touch()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
begin
  -- a line moved to another invoice keeps nothing found for the old one: sent to accounting (0174) and the payment
  -- request (0153) are found again for the new number by the next pull
  if public.kount_ot_inv_token(new.invoice_number) is distinct from public.kount_ot_inv_token(old.invoice_number) then
    new.acct_sent_at := null; new.acct_sent_to := null; new.acct_sent_by := null; new.acct_sent_subject := null; new.acct_message_id := null;
    new.pay_requested_at := null; new.ap_query_no := null;
  end if;
  -- the mail pull's sent-to-accounting stamps (0174) alone are not an update of the line (any other update,
  -- a no-op one included, touches it as before)
  if (new.acct_sent_at, new.acct_sent_to, new.acct_sent_by, new.acct_sent_subject, new.acct_message_id)
       is distinct from (old.acct_sent_at, old.acct_sent_to, old.acct_sent_by, old.acct_sent_subject, old.acct_message_id)
     and (to_jsonb(new) - '{updated_at,acct_sent_at,acct_sent_to,acct_sent_by,acct_sent_subject,acct_message_id}'::text[])
       = (to_jsonb(old) - '{updated_at,acct_sent_at,acct_sent_to,acct_sent_by,acct_sent_subject,acct_message_id}'::text[]) then
    new.updated_at := old.updated_at;
    return new;
  end if;
  new.updated_at := now();
  return new;
end
$fn$;
revoke all on function public.kount_ot_line_touch() from public, anon, authenticated;

drop trigger if exists kount_ot_lines_touch on public.kount_ot_lines;
create trigger kount_ot_lines_touch before update on public.kount_ot_lines
  for each row execute function public.kount_ot_line_touch();

-- verification: 5 columns, the lines' touch trigger on the new function, the other tables' untouched
do $$
begin
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kount_ot_lines'
        and column_name in ('acct_sent_at', 'acct_sent_to', 'acct_sent_by', 'acct_sent_subject', 'acct_message_id')) <> 5 then
    raise exception '0174: expected the 5 acct_ columns on kount_ot_lines';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'kount_ot_lines_touch' and tgrelid = 'public.kount_ot_lines'::regclass
                   and tgfoid = 'public.kount_ot_line_touch'::regproc) then
    raise exception '0174: kount_ot_lines_touch is not on kount_ot_line_touch()';
  end if;
  if (select count(*) from pg_trigger where tgfoid = 'public.kount_ot_touch'::regproc) <> 3 then
    raise exception '0174: expected kount_ot_touch() still on orders, items and inbox';
  end if;
end
$$;

commit;
