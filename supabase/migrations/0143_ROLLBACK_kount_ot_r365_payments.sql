-- ROLLBACK for 0143_kount_ot_r365_payments: the payment references go (line statuses are untouched).
begin;
alter table public.kount_ot_lines drop column if exists r365_payments;
commit;
