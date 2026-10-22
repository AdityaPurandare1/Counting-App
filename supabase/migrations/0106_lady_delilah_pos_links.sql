-- =============================================================================
--  0106_lady_delilah_pos_links
--
--  Lady Delilah (counting v14, KevaOS a681b43a, Oracle Simphony) has 99 POS menu items auto-discovered
--  10/18 and no links. Simphony sales reach item_day_facts for the other Simphony venues (Delilah Dallas,
--  Bar Shishi), which v14 depletes from (depletion_source item_day_facts) -- so these links work the day
--  LD's Simphony feed starts (it has no Simphony rows yet: 0 detail lines).
--
--  Counting-side links only (new_recipes + new_recipe_pos_skus scoped to LD's venue, like Alphabet).
--  KevaOS's menu_item_recipe_map is NOT touched; food and modifiers need no exclusion (the POS watcher
--  skips food categories).
--   * 6 spirit pours, 2 fl.oz (Poppy rule) -> the bottles LD bought: Don Julio Blanco, Ketel One 1L,
--     Tanqueray 750ml, Mount Gay Silver 750ml, Fernet Branca, Johnnie Walker Black 1L.
--   * "$ add Bailey's" -> Baileys 1L, 1 fl.oz.
--   * 4 bottled drinks, 1 each: Aqua Panna 1L, San Pellegrino 1L, Coke 8oz glass, Red Bull 8.4oz.
--   * 4 Delilah signatures -> the shared recipes Delilah LA / Miami already use:
--     Jojo (8e06e1d6), Spicy Siena (818 1L) (c9050f7c), Sheth & Co (59f29448), Millionaire Martini (73985fd5).
--   * venue_item_settings for the newly linked bottles LD will count.
--  Not linked (no recipe anywhere -- need LD's specs): Black Swan, Luck be a Lady, Spicy Lady, Rainbow Room,
--  Red Tuxedo, Green Velvet, Famous Last Words, Not for Nothing, Migonette Martini, 1000 Miles Away,
--  ALL TOGETHER, Cafe Nocturne, Know A Guy (its shared recipe is an empty placeholder), and the "$ cosmo /
--  espresso martini / margarita / negroni / pornstar martini / vesper" upcharge items.
--  ROLLBACK: 0106_ROLLBACK_lady_delilah_pos_links.sql
-- =============================================================================
begin;

-- new ingredient names (global map, new names only -- nothing existing is re-pointed)
insert into public.new_recipe_ingredient_master_map (ingredient_name, master_item_id) values
  ('Mount Gay Silver 750ml Base Item', '63c2f805-9daa-4dcd-80af-33e111794703'),
  ('Acqua Panna 1L Bottle', '694e4e62-365c-4ffb-8245-70f0d4cc04c6'),
  ('Coke 8oz Glass Bottle', 'f6c424ba-10c7-4393-b38e-f99ea66f5bec')
on conflict (ingredient_name) do nothing;

do $$ begin
  if exists (select 1 from (values
      ('Mount Gay Silver 750ml Base Item', '63c2f805-9daa-4dcd-80af-33e111794703'::uuid),
      ('Acqua Panna 1L Bottle', '694e4e62-365c-4ffb-8245-70f0d4cc04c6'::uuid),
      ('Coke 8oz Glass Bottle', 'f6c424ba-10c7-4393-b38e-f99ea66f5bec'::uuid)) x(n, m)
     join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = x.n where nm.master_item_id <> x.m) then
    raise exception '0106: an ingredient name already maps to a different bottle';
  end if;
  if exists (select 1 from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') then
    raise exception '0106: Lady Delilah already has recipe links -- review before re-running';
  end if;
end $$;

create temp table _r (pos text, rname text, ing text, qty numeric, unit text, note text, rid uuid default gen_random_uuid()) on commit drop;
insert into _r (pos, rname, ing, qty, unit, note) values
  ('Don Julio Blanco',          'Don Julio Blanco 2oz · Lady Delilah',   'Don Julio Blanco 750ml Base Item',  2, 'fl.oz', 'Poppy 2 fl.oz rule'),
  ('Ketel One',                 'Ketel One 2oz · Lady Delilah',          'Ketel One 1L Base Item',            2, 'fl.oz', 'Poppy 2 fl.oz rule'),
  ('Tanqueray',                 'Tanqueray 2oz · Lady Delilah',          'Tanqueray 750ml Base Item',         2, 'fl.oz', 'Poppy 2 fl.oz rule; LD buys 750ml'),
  ('Mount Gay Silver',          'Mount Gay Silver 2oz · Lady Delilah',   'Mount Gay Silver 750ml Base Item',  2, 'fl.oz', 'Poppy 2 fl.oz rule; LD buys 750ml'),
  ('Fernet Branca',             'Fernet Branca 2oz · Lady Delilah',      'Fernet Branca 750ml Base Item',     2, 'fl.oz', 'Poppy 2 fl.oz rule'),
  ('Johnny Walker Black Label', 'Johnnie Walker Black 2oz · Lady Delilah', 'Johnnie Walker Black 1L Base Item', 2, 'fl.oz', 'Poppy 2 fl.oz rule; LD buys 1L'),
  ('$ add Bailey''s',           'Add Baileys 1oz · Lady Delilah',        'Baileys 1L Base Item',              1, 'fl.oz', 'add-on pour'),
  ('Aqua Panna 1L',             'Acqua Panna 1L bottle · Lady Delilah',  'Acqua Panna 1L Bottle',             1, 'each',  'whole bottle'),
  ('San Pellegrino',            'San Pellegrino 1L bottle · Lady Delilah', 'San Pellegrino 1L Base Item',     1, 'each',  'whole bottle; 1L assumed, confirm'),
  ('Coke',                      'Coke 8oz bottle · Lady Delilah',        'Coke 8oz Glass Bottle',             1, 'each',  'whole bottle; 8oz glass assumed (Delilah standard), confirm'),
  ('Red Bull',                  'Red Bull can · Lady Delilah',           'Red Bull 8.4fl.oz Base Item',       1, 'each',  'whole can');

insert into public.new_recipes (id, name, recipe_type, category, item_category, venue_id, yield_qty, yield_uom, is_active, notes)
select rid, rname, 'beverage', 'Beverage', 'Lady Delilah pours', null, 1, 'each', true,
       'Lady Delilah POS link (0106, 2026-10-22): ' || note || '.'
  from _r;
insert into public.new_recipe_ingredients (recipe_id, ingredient_name, quantity, unit, sort_order, source, is_sub_recipe)
select rid, ing, qty, unit, 1, 'Lady Delilah default -- ' || note, false from _r;
insert into public.new_recipe_pos_skus (recipe_id, pos_sku, venue_id)
select rid, pos, 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'::uuid from _r;

-- the shared Delilah signature recipes (same recipe ids Delilah LA / Miami use)
insert into public.new_recipe_pos_skus (recipe_id, pos_sku, venue_id) values
  ('8e06e1d6-5778-483c-b1a2-9150927d6b6f', 'Jojo',                'a681b43a-5cba-4656-b8bd-ae6d86e744c0'),
  ('c9050f7c-5737-47e4-9a01-9c3f01d455c6', 'Spicy Siena',         'a681b43a-5cba-4656-b8bd-ae6d86e744c0'),
  ('59f29448-8534-4d90-bd0c-3b7b6f6d07c5', 'Sheth & Co',          'a681b43a-5cba-4656-b8bd-ae6d86e744c0'),
  ('73985fd5-1d2c-41b1-b453-f0318d0058f5', 'Millionaire Martini', 'a681b43a-5cba-4656-b8bd-ae6d86e744c0');

-- bottles the new links deplete that LD's opening invoices did not register
insert into public.venue_item_settings (venue_id, master_item_id, notes)
select 'a681b43a-5cba-4656-b8bd-ae6d86e744c0', m, 'Lady Delilah: linked to a POS item (0106, 2026-10-22)'
  from (values ('694e4e62-365c-4ffb-8245-70f0d4cc04c6'::uuid), ('f13c96fd-aa64-4da8-b81f-066753aa8633'::uuid),
               ('f6c424ba-10c7-4393-b38e-f99ea66f5bec'::uuid), ('264a8ccd-a8bd-4622-9105-06a386d97d0f'::uuid),
               ('004ac288-0c52-4850-aff1-cb81ef70807e'::uuid), ('071caa59-85a3-4d00-98f7-40a0aca7d84e'::uuid)) v(m)
on conflict (venue_id, master_item_id) do nothing;

-- every LD link must end on an active bottle
do $$ begin
  if (select count(*) from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') <> 15 then
    raise exception '0106: expected 15 POS links';
  end if;
  if exists (
    select 1 from public.new_recipe_pos_skus s
      join public.new_recipes r on r.id = s.recipe_id
      join public.new_recipe_ingredients ri on ri.recipe_id = r.id and coalesce(ri.is_sub_recipe, false) = false
      left join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = ri.ingredient_name
      left join public.master_items mi on mi.id = nm.master_item_id
     where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
       and r.item_category = 'Lady Delilah pours'
       and (mi.id is null or not mi.is_active)) then
    raise exception '0106: a Lady Delilah pour does not reach an active bottle';
  end if;
end $$;

commit;
