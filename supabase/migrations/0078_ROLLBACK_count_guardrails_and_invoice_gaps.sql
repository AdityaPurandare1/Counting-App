-- ROLLBACK for 0078
begin;
drop function if exists public.kount_count_guardrails(uuid);
drop function if exists public.kount_invoice_gaps(text, date, date);
commit;
