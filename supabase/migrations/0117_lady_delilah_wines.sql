-- =============================================================================
--  0117_lady_delilah_wines   (DATA)
--
--  The wines 0114 left unlinked (no clear catalog bottle). Re-checked every
--  catalog and invoice item, including inactive ones:
--   * already in the catalog under their vintage:
--       Chianti Fonterutoli '16 -> Castello di Fonterutoli, 'Gran Selezione', Chianti 2016 750ml
--       Pinot Noir Tyler '23    -> Tyler, 'Sta. Rita Hills', Pinot Noir 2023 750ml
--       CAB SAUV Phelps '22     -> Joseph Phelps, Cabernet Sauvignon 2022 750ml
--                                  (0114 had linked the no-vintage Phelps Cab; re-pointed)
--   * not in the catalog at this vintage / at all -> 6 new items, named like
--     the catalog's vintage items ("Producer, Wine Vintage 750ml"), the wine as
--     the menu names it (Faiveley and Chave exist only as other vintages or
--     cuvees; d'Issan, Arzuaga, Matthiasson Chardonnay, Cliff Lede Sauvignon
--     Blanc not at all).
--  Links as 0114: bottle = 1 each, glass = 5 fl.oz.
--  None of these wines has a price anywhere (catalog, any venue, any invoice),
--  so none is priced here; the first Lady Delilah invoice, or a price set in
--  the admin, prices them.
--  ROLLBACK: 0117_ROLLBACK_lady_delilah_wines.sql
-- =============================================================================
begin;

insert into public.master_items (name, category, base_size, base_unit, organization_id, is_active)
values ('Faiveley, Gevrey Chambertin 2023 750ml',               'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true),
       ('Chave, St. Joseph 2023 750ml',                         'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true),
       ('Chateau d''Issan, Margaux 2016 750ml',                 'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true),
       ('Arzuaga, Tempranillo, Ribera del Duero 2022 750ml',    'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true),
       ('Matthiasson, Chardonnay 2023 750ml',                   'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true),
       ('Cliff Lede, Sauvignon Blanc 2023 750ml',               'Wine Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true)
on conflict (organization_id, name, category) do nothing;

create temp table _w (pos text, mname text, qty numeric, unit text, note text) on commit drop;
insert into _w values
  ('BTL GEVREY CHAMBERTIN Faiveley ''23', 'Faiveley, Gevrey Chambertin 2023 750ml', 1, 'each', 'whole bottle'),
  ('GL GEVREY CHAMBERTIN Faiveley ''23',  'Faiveley, Gevrey Chambertin 2023 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('Chianti Fonterutoli ''16',            'Castello di Fonterutoli, ''Gran Selezione'', Chianti 2016 750ml', 1, 'each', 'whole bottle'),
  ('GL BORDEAUX D''Issan ''16',           'Chateau d''Issan, Margaux 2016 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('GL CHARDONNAY Matthiasson ''23',      'Matthiasson, Chardonnay 2023 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('GL ST JOSEPH Chave ''23',             'Chave, St. Joseph 2023 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('GL TEMPRANILLO Arzuaga ''22',         'Arzuaga, Tempranillo, Ribera del Duero 2022 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('Pinot Noir Tyler ''23',               'Tyler, ''Sta. Rita Hills'', Pinot Noir 2023 750ml', 1, 'each', 'whole bottle'),
  ('SAUV BLANC Cliff Lede ''23',          'Cliff Lede, Sauvignon Blanc 2023 750ml', 1, 'each', 'whole bottle');

do $$ begin
  if exists (select 1 from _w where not exists (
       select 1 from public.simphony_menu_item_dimensions d
        where d.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and lower(trim(d.name)) = lower(trim(_w.pos)))) then
    raise exception '0117: % not on the Lady Delilah menu', (select string_agg(pos, ', ') from _w where not exists (
       select 1 from public.simphony_menu_item_dimensions d
        where d.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and lower(trim(d.name)) = lower(trim(_w.pos))));
  end if;
  if exists (select 1 from _w where (select count(*) from public.master_items mi
              where mi.name = _w.mname and mi.is_active and mi.merged_into_id is null) <> 1) then
    raise exception '0117: wine not uniquely resolvable: %', (select string_agg(mname, ', ') from _w where (select count(*)
      from public.master_items mi where mi.name = _w.mname and mi.is_active and mi.merged_into_id is null) <> 1);
  end if;
  if exists (select 1 from public.new_recipe_pos_skus s join _w on lower(trim(s.pos_sku)) = lower(trim(_w.pos))
              where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') then
    raise exception '0117: a wine is already linked at Lady Delilah';
  end if;
end $$;

create temp table _x on commit drop as
select _w.*, mi.id as mid, mi.name || ' Base Item' as ing, gen_random_uuid() as rid
  from _w join public.master_items mi on mi.name = _w.mname and mi.is_active and mi.merged_into_id is null;

-- Phelps '22: point 0114's link at the 2022 vintage
insert into _x (pos, mname, qty, unit, note, mid, ing, rid)
select 'CAB SAUV Phelps ''22', mi.name, null, null, null, mi.id, mi.name || ' Base Item', null
  from public.master_items mi where mi.name = 'Joseph Phelps, Cabernet Sauvignon 2022 750ml' and mi.is_active;

insert into public.new_recipe_ingredient_master_map (ingredient_name, master_item_id)
select distinct ing, mid from _x
on conflict (ingredient_name) do nothing;

do $$ begin
  if exists (select 1 from _x join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = _x.ing
              where nm.master_item_id <> _x.mid) then
    raise exception '0117: an ingredient name already maps to a different wine';
  end if;
end $$;

insert into public.new_recipes (id, name, recipe_type, category, item_category, venue_id, yield_qty, yield_uom, is_active, notes)
select rid, pos || ' · Lady Delilah', 'beverage', 'Beverage', 'Lady Delilah pours', null, 1, 'each', true,
       'Lady Delilah POS link (0117, 2026-10-27): ' || note || '.'
  from _x where rid is not null;
insert into public.new_recipe_ingredients (recipe_id, ingredient_name, quantity, unit, sort_order, source, is_sub_recipe)
select rid, ing, qty, unit, 1, 'Lady Delilah default -- ' || note, false from _x where rid is not null;
insert into public.new_recipe_pos_skus (recipe_id, pos_sku, venue_id)
select rid, pos, 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'::uuid from _x where rid is not null;

update public.new_recipe_ingredients ri
   set ingredient_name = 'Joseph Phelps, Cabernet Sauvignon 2022 750ml Base Item',
       source = 'Lady Delilah default -- whole bottle; 2022 vintage (0117)'
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.pos_sku = 'CAB SAUV Phelps ''22'
   and ri.recipe_id = s.recipe_id and ri.ingredient_name = 'Joseph Phelps, Cabernet Sauvignon Base Item';

insert into public.venue_item_settings (venue_id, master_item_id, notes)
select distinct 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'::uuid, mid, 'Lady Delilah: linked to a POS item (0117, 2026-10-27)' from _x
on conflict (venue_id, master_item_id) do nothing;

do $$ begin
  if (select count(*) from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') <> 176 + 9 then
    raise exception '0117: expected 185 POS links';
  end if;
  if not exists (select 1 from public.new_recipe_pos_skus s join public.new_recipe_ingredients ri on ri.recipe_id = s.recipe_id
                  join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = ri.ingredient_name
                  join public.master_items mi on mi.id = nm.master_item_id
                 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.pos_sku = 'CAB SAUV Phelps ''22'
                   and mi.name = 'Joseph Phelps, Cabernet Sauvignon 2022 750ml') then
    raise exception '0117: Phelps not re-pointed';
  end if;
end $$;

select s.pos_sku pos, mi.name wine, ri.quantity::text || ' ' || ri.unit amt
  from public.new_recipe_pos_skus s join public.new_recipes r on r.id = s.recipe_id
  join public.new_recipe_ingredients ri on ri.recipe_id = r.id
  join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = ri.ingredient_name
  join public.master_items mi on mi.id = nm.master_item_id
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and mi.category ~* 'wine'
 order by mi.name, s.pos_sku;
commit;
