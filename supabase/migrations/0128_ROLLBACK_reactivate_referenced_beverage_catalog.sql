-- ROLLBACK for 0128: undo the twin merges, restore every touched item, drop the filed barcodes.
begin;

delete from public.master_item_upcs where source = 'purchase_items_backfill_0128';

-- Twin merges: put repointed rows back on the old twin, re-insert dropped rows.
update public.master_item_upcs x set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'master_item_upcs' and x.id::text = r.row_id;
update public.kount_entries e set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'kount_entries' and e.id::text = r.row_id;
update public.kount_recounts k set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'kount_recounts' and k.id::text = r.row_id;
update public.purchase_items p set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'purchase_items' and p.id::text = r.row_id;
update public.new_recipe_ingredient_master_map m set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'new_recipe_ingredient_master_map' and m.ingredient_name = r.row_id;
update public.kount_venue_cost_overrides o set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'kount_venue_cost_overrides' and o.venue_id = r.row_id and o.master_item_id = r.new_master;
update public.venue_item_settings s set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'venue_item_settings' and s.id::text = r.row_id;
update public.kount_venue_catalog v set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'kount_venue_catalog' and v.venue_id = r.row_id and v.master_item_id = r.new_master;
update public.kount_carried_items c set master_item_id = r.old_master from public._mig0128_repoints r where r.table_name = 'kount_carried_items' and c.id::text = r.row_id;
insert into public.kount_venue_cost_overrides select (jsonb_populate_record(null::public.kount_venue_cost_overrides, row)).* from public._mig0128_deleted where table_name = 'kount_venue_cost_overrides' on conflict do nothing;
insert into public.venue_item_settings select (jsonb_populate_record(null::public.venue_item_settings, row)).* from public._mig0128_deleted where table_name = 'venue_item_settings' on conflict do nothing;
insert into public.kount_venue_catalog select (jsonb_populate_record(null::public.kount_venue_catalog, row)).* from public._mig0128_deleted where table_name = 'kount_venue_catalog' on conflict do nothing;
insert into public.kount_carried_items select (jsonb_populate_record(null::public.kount_carried_items, row)).* from public._mig0128_deleted where table_name = 'kount_carried_items' on conflict do nothing;

update public.master_items m
   set is_active = r.prev_is_active, merged_into_id = r.prev_merged_into, category = r.prev_category,
       base_size = r.prev_base_size, base_unit = r.prev_base_unit, updated_at = r.prev_updated_at
  from public._mig0128_items r
 where r.id = m.id;

drop table if exists public._mig0128_deleted;
drop table if exists public._mig0128_repoints;
drop table if exists public._mig0128_merges;
drop table if exists public._mig0128_items;

commit;
