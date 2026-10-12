-- ROLLBACK for 0076_lady_delilah_setup
begin;
delete from public.kount_venue_cost_overrides where venue_id = 'v14' and set_by = 'lady-delilah-sgws-opening-2026-10-09';
delete from public.venue_item_settings where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and notes = 'Lady Delilah: SGWS NY opening invoices 10/8-10/9 (import 2026-10-09)';
delete from public.procurement_kount_venue_map where kount_venue_id = 'v14';
delete from public.kount_venues where id = 'v14' and not exists (select 1 from public.kount_audits where venue_id = 'v14');
delete from public.master_items m where m.organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41' and m.category = 'Liquor Cost'
   and m.name in ('Bulleit 95 Rye 10yr 750ml', 'Luxardo Maraschino 375ml', 'Mount Gay Silver 750ml')
   and not exists (select 1 from public.kount_entries e where e.master_item_id = m.id)
   and not exists (select 1 from public.purchase_items p where p.master_item_id = m.id)
   and not exists (select 1 from public.venue_item_settings v where v.master_item_id = m.id)
   and not exists (select 1 from public.kount_venue_cost_overrides o where o.master_item_id = m.id);
commit;
