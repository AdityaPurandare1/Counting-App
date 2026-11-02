-- ROLLBACK for 0130: put moved rows back on the archived item, re-insert dropped rows,
-- and undo the KevaOS repoints logged with reason '0130'.
begin;

update public.kount_entries t set master_item_id = l.old_master from public._mig0130_log l where l.table_name = 'kount_entries' and l.action = 'moved' and t.id::text = l.row->>'id';
update public.kount_recounts t set master_item_id = l.old_master from public._mig0130_log l where l.table_name = 'kount_recounts' and l.action = 'moved' and t.id::text = l.row->>'id';
update public.new_recipe_ingredient_master_map t set master_item_id = l.old_master from public._mig0130_log l where l.table_name = 'new_recipe_ingredient_master_map' and t.ingredient_name = l.row->>'ingredient_name';
update public.upc_mappings t set master_item_id = l.old_master from public._mig0130_log l where l.table_name = 'upc_mappings' and t.id::text = l.row->>'id';
update public.transfer_lines t set master_item_id = l.old_master from public._mig0130_log l where l.table_name = 'transfer_lines' and t.id::text = l.row->>'id';

-- keyed tables: remove the moved copies, then restore every logged row as it was
delete from public.kount_carried_items t using public._mig0130_log l where l.table_name = 'kount_carried_items' and t.id::text = l.row->>'id';
delete from public.kount_cost_overrides t using public._mig0130_log l where l.table_name = 'kount_cost_overrides' and l.action = 'moved' and t.master_item_id = l.new_master;
delete from public.kount_venue_cost_overrides t using public._mig0130_log l where l.table_name = 'kount_venue_cost_overrides' and l.action = 'moved' and t.venue_id = l.row->>'venue_id' and t.master_item_id = l.new_master;
delete from public.kount_invoice_item_map t using public._mig0130_log l where l.table_name = 'kount_invoice_item_map' and l.action = 'moved' and t.venue_id = l.row->>'venue_id' and t.purchase_item_id::text = l.row->>'purchase_item_id' and t.master_item_id = l.new_master;
delete from public.kount_invoice_line_map t using public._mig0130_log l where l.table_name = 'kount_invoice_line_map' and l.action = 'moved' and t.venue_id = l.row->>'venue_id' and t.invoice_line_id::text = l.row->>'invoice_line_id' and t.master_item_id = l.new_master;
delete from public.kount_price_fingerprints t using public._mig0130_log l where l.table_name = 'kount_price_fingerprints' and l.action = 'moved' and t.venue_id = l.row->>'venue_id' and t.master_item_id = l.new_master and t.unit_cost::text = l.row->>'unit_cost';
insert into public.kount_carried_items select (jsonb_populate_record(null::public.kount_carried_items, row)).* from public._mig0130_log where table_name = 'kount_carried_items' on conflict do nothing;
insert into public.kount_cost_overrides select (jsonb_populate_record(null::public.kount_cost_overrides, row)).* from public._mig0130_log where table_name = 'kount_cost_overrides' on conflict do nothing;
insert into public.kount_venue_cost_overrides select (jsonb_populate_record(null::public.kount_venue_cost_overrides, row)).* from public._mig0130_log where table_name = 'kount_venue_cost_overrides' on conflict do nothing;
insert into public.kount_invoice_item_map select (jsonb_populate_record(null::public.kount_invoice_item_map, row)).* from public._mig0130_log where table_name = 'kount_invoice_item_map' on conflict do nothing;
insert into public.kount_invoice_line_map select (jsonb_populate_record(null::public.kount_invoice_line_map, row)).* from public._mig0130_log where table_name = 'kount_invoice_line_map' on conflict do nothing;
insert into public.kount_price_fingerprints select (jsonb_populate_record(null::public.kount_price_fingerprints, row)).* from public._mig0130_log where table_name = 'kount_price_fingerprints' on conflict do nothing;

update public.purchase_items p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0130' and r.table_name = 'purchase_items' and p.id::text = r.row_id::text;
update public.invoice_lines p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0130' and r.table_name = 'invoice_lines' and p.id::text = r.row_id::text;
update public.menu_item_recipe_map p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0130' and r.table_name = 'menu_item_recipe_map' and p.id::text = r.row_id::text;
update public.recipe_items p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0130' and r.table_name = 'recipe_items' and p.id::text = r.row_id::text;
update public.procurement_movements p set master_item_id = r.old_master_id from public.master_item_merge_repoints r where r.reason = '0130' and r.table_name = 'procurement_movements' and p.id::text = r.row_id::text;

drop table if exists public._mig0130_log;

commit;
