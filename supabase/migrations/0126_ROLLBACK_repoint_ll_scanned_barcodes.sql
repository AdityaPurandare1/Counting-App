-- ROLLBACK for 0126: put each moved barcode back on the archived item it was on.
begin;

update public.master_item_upcs x
   set master_item_id = b.old_master
  from public._mig0126_upc_repoint b
 where b.upc_normalized = x.upc_normalized and x.master_item_id = b.new_master;

drop table if exists public._mig0126_upc_repoint;

commit;
