-- ROLLBACK for 0153_kount_ot_followups: no To send log (drops what was logged), no payment-request / vendor-reply marks.
begin;
drop table if exists public.kount_ot_followups;
drop function if exists public.kount_ot_followup_stamp();
alter table public.kount_ot_lines drop column if exists pay_requested_at;
alter table public.kount_ot_lines drop column if exists ap_query_no;
alter table public.kount_ot_orders drop column if exists last_vendor_email_at;
commit;
