-- ROLLBACK for 0117_lady_delilah_wines
begin;
delete from public.new_recipe_pos_skus s using public.new_recipes r
 where s.recipe_id = r.id and s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and r.notes like 'Lady Delilah POS link (0117,%';
delete from public.new_recipe_ingredients ri using public.new_recipes r
 where ri.recipe_id = r.id and r.notes like 'Lady Delilah POS link (0117,%';
delete from public.new_recipes where notes like 'Lady Delilah POS link (0117,%';
update public.new_recipe_ingredients ri
   set ingredient_name = 'Joseph Phelps, Cabernet Sauvignon Base Item', source = 'Lady Delilah default -- whole bottle'
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.pos_sku = 'CAB SAUV Phelps ''22'
   and ri.recipe_id = s.recipe_id and ri.ingredient_name = 'Joseph Phelps, Cabernet Sauvignon 2022 750ml Base Item';
delete from public.venue_item_settings where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
   and notes = 'Lady Delilah: linked to a POS item (0117, 2026-10-27)';
-- the 6 wines 0117 created, if nothing has been counted or bought on them since
delete from public.new_recipe_ingredient_master_map nm using public.master_items m
 where nm.master_item_id = m.id and nm.ingredient_name = m.name || ' Base Item'
   and m.name in ('Faiveley, Gevrey Chambertin 2023 750ml', 'Chave, St. Joseph 2023 750ml', 'Chateau d''Issan, Margaux 2016 750ml',
                  'Arzuaga, Tempranillo, Ribera del Duero 2022 750ml', 'Matthiasson, Chardonnay 2023 750ml',
                  'Cliff Lede, Sauvignon Blanc 2023 750ml')
   and not exists (select 1 from public.new_recipe_ingredients ri where ri.ingredient_name = nm.ingredient_name);
delete from public.master_items m
 where m.organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41' and m.category = 'Wine Cost'
   and m.name in ('Faiveley, Gevrey Chambertin 2023 750ml', 'Chave, St. Joseph 2023 750ml', 'Chateau d''Issan, Margaux 2016 750ml',
                  'Arzuaga, Tempranillo, Ribera del Duero 2022 750ml', 'Matthiasson, Chardonnay 2023 750ml',
                  'Cliff Lede, Sauvignon Blanc 2023 750ml')
   and not exists (select 1 from public.kount_entries e where e.master_item_id = m.id)
   and not exists (select 1 from public.purchase_items p where p.master_item_id = m.id)
   and not exists (select 1 from public.kount_venue_cost_overrides o where o.master_item_id = m.id)
   and not exists (select 1 from public.new_recipe_ingredient_master_map nm where nm.master_item_id = m.id);
commit;
