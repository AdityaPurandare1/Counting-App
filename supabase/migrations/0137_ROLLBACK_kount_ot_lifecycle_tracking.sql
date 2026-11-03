-- ROLLBACK for 0137_kount_ot_lifecycle_tracking: drops the tracking table and
-- function and restores 0132's status cycle. Lines at a status 0132 did not
-- have are mapped back (REQUESTED -> ORDERED, RECEIVED -> DELIVERED); run only
-- if that is acceptable.
begin;
drop function if exists public.kount_ot_add_tracking(jsonb);
drop table if exists public.kount_ot_tracking;
alter table public.kount_ot_lines drop constraint if exists kount_ot_lines_status_check;
update public.kount_ot_lines set status = 'ORDERED' where status = 'REQUESTED';
update public.kount_ot_lines set status = 'DELIVERED' where status = 'RECEIVED';
alter table public.kount_ot_lines add constraint kount_ot_lines_status_check check (status in
  ('QUOTED', 'ORDERED', 'CONFIRMED', 'IN_PRODUCTION', 'SHIPPED', 'DELIVERED', 'INVOICED', 'PAID', 'CANCELLED'));
alter table public.kount_ot_lines alter column status set default 'ORDERED';
commit;
