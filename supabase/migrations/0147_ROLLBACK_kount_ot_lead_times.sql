-- ROLLBACK for 0147_kount_ot_lead_times: no sent / delivered days (lead times go away).
begin;
drop trigger if exists kount_ot_lines_delivered_on on public.kount_ot_lines;
drop function if exists public.kount_ot_line_delivered_on();
alter table public.kount_ot_lines drop column if exists delivered_source, drop column if exists delivered_on;
alter table public.kount_ot_orders drop column if exists sent_source, drop column if exists sent_on;
commit;
