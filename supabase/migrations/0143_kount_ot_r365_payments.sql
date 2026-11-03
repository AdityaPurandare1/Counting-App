-- =============================================================================
--  0143_kount_ot_r365_payments   (which R365 payment paid each invoice)
--
--  The user (2026-11-03): orders marked paid with no check stub attached should
--  be flagged, so the stub can be reprinted from R365 (AP Transactions → the
--  payment → Check Stub Reprint). R365 reprints by PAYMENT, and one ACH pays
--  several invoices — so the tracker keeps, per line, the R365 payment(s) that
--  paid its invoice:
--
--    kount_ot_lines.r365_payments  [{ "number": "ACH - 24567", "date": "2026-10-22", "amount": 10926.42 }]
--
--  Filled by kount-order-mail's Paid-from-R365 step (also for lines already past
--  Paid); null = not matched to an R365 payment (paid outside R365, or not yet).
-- =============================================================================
begin;

alter table public.kount_ot_lines add column if not exists r365_payments jsonb;

comment on column public.kount_ot_lines.r365_payments is
  'R365 AP payment(s) that paid this line''s invoice: [{number, date, amount}] (0143); null = not matched to one';

commit;
