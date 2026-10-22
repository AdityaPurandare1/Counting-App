-- ROLLBACK for 0106 (cascades the new recipes' ingredients and POS links; shared Delilah recipes untouched)
begin;
delete from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0';
delete from public.new_recipes where item_category = 'Lady Delilah pours' and name like '% · Lady Delilah';
delete from public.venue_item_settings where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and notes = 'Lady Delilah: linked to a POS item (0106, 2026-10-22)';
delete from public.new_recipe_ingredient_master_map nm where nm.ingredient_name in ('Mount Gay Silver 750ml Base Item','Acqua Panna 1L Bottle','Coke 8oz Glass Bottle')
   and not exists (select 1 from public.new_recipe_ingredients ri where ri.ingredient_name = nm.ingredient_name);
commit;
