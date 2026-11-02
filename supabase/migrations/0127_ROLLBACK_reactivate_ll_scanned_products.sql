-- ROLLBACK for 0127: re-archive the products, untie the entries, put the 8
-- barcodes back, and return the approved links to pending.
begin;

update public.upc_mappings set status = 'pending', reviewed_by_email = null, reviewed_by_name = null, reviewed_at = null
 where reviewed_by_name = 'Aditya Purandare (0127)';
delete from public.master_item_upcs where source = 'scan_pending_approved_0127';

update public.kount_entries e set master_item_id = null
  from public._mig0127_entry_links l where l.entry_id = e.id and e.master_item_id = l.master_item_id;

update public.master_item_upcs x set master_item_id = b.old_master
  from public._mig0127_upc_repoint b where b.upc_normalized = x.upc_normalized and x.master_item_id = b.new_master;

update public.master_items m
   set is_active = false, merged_into_id = r.prev_merged_into, base_size = r.prev_base_size, base_unit = r.prev_base_unit, updated_at = r.prev_updated_at
  from public._mig0127_reactivated r where r.id = m.id;

drop table if exists public._mig0127_reactivated;
drop table if exists public._mig0127_entry_links;
drop table if exists public._mig0127_upc_repoint;

commit;
