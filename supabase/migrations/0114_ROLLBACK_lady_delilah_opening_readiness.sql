-- ROLLBACK for 0114_lady_delilah_opening_readiness
begin;
delete from public.new_recipe_pos_skus s using public.new_recipes r
 where s.recipe_id = r.id and s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and r.notes like 'Lady Delilah POS link (0114,%';
delete from public.new_recipe_ingredients ri using public.new_recipes r
 where ri.recipe_id = r.id and r.notes like 'Lady Delilah POS link (0114,%';
delete from public.new_recipes where notes like 'Lady Delilah POS link (0114,%';
update public.new_recipe_ingredients ri
   set quantity = 2, source = 'Lady Delilah default -- Poppy 2 fl.oz rule'
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.recipe_id = ri.recipe_id and s.pos_sku in ('Don Julio Blanco', 'Ketel One', 'Tanqueray', 'Mount Gay Silver', 'Fernet Branca', 'Johnny Walker Black Label')
   and ri.quantity = 1.5 and ri.unit = 'fl.oz';
update public.new_recipes r set name = replace(r.name, ' 1.5oz ', ' 2oz ')
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.recipe_id = r.id and s.pos_sku in ('Don Julio Blanco', 'Ketel One', 'Tanqueray', 'Mount Gay Silver', 'Fernet Branca', 'Johnny Walker Black Label');
delete from public.kount_venue_cost_overrides where venue_id = 'v14' and set_by = 'ld-proxy-costing-2026-10-27';
delete from public.venue_item_settings where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and notes = 'Lady Delilah: linked to a POS item (0114, 2026-10-27)';
-- '<name> Base Item' ingredient names 0114 created and nothing else uses are left in place (harmless, global map).
commit;
