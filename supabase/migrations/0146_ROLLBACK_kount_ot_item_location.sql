-- ROLLBACK for 0146_kount_ot_item_location: items lose their location (all read as the E&E warehouse again).
begin;
alter table public.kount_ot_items drop column if exists location;
commit;
