-- ROLLBACK for 0129: move every repointed row back to the archived twin.
-- (Rows the migration dropped because the survivor already had one are not
-- restored; they were duplicates of the survivor's row.)
begin;

update public.purchase_items p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0129' and r.table_name = 'purchase_items' and p.id::text = r.row_id::text;
update public.invoice_lines p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0129' and r.table_name = 'invoice_lines' and p.id::text = r.row_id::text;
update public.menu_item_recipe_map p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0129' and r.table_name = 'menu_item_recipe_map' and p.id::text = r.row_id::text;
update public.recipe_items p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0129' and r.table_name = 'recipe_items' and p.id::text = r.row_id::text;
update public.procurement_movements p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0129' and r.table_name = 'procurement_movements' and p.id::text = r.row_id::text;

update public.kount_venue_cost_overrides o set master_item_id = k.old_master from public._mig0129_kount_repoints k where k.table_name = 'kount_venue_cost_overrides' and o.venue_id = k.row_key and o.master_item_id = k.new_master;
update public.master_item_upcs x set master_item_id = k.old_master from public._mig0129_kount_repoints k where k.table_name = 'master_item_upcs' and x.upc_normalized = k.row_key and x.master_item_id = k.new_master;
update public.kount_carried_items c set master_item_id = k.old_master from public._mig0129_kount_repoints k where k.table_name = 'kount_carried_items' and c.id::text = k.row_key;
update public.kount_venue_catalog v set master_item_id = k.old_master from public._mig0129_kount_repoints k where k.table_name = 'kount_venue_catalog' and v.venue_id = k.row_key and v.master_item_id = k.new_master;
update public.kount_entries e set master_item_id = k.old_master from public._mig0129_kount_repoints k where k.table_name = 'kount_entries' and e.id::text = k.row_key;

drop table if exists public._mig0129_kount_repoints;
drop table if exists public._mig0129_pairs;

commit;
