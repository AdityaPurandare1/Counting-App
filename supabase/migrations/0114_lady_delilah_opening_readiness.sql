-- =============================================================================
--  0114_lady_delilah_opening_readiness   (DATA)
--
--  Lady Delilah (counting v14, KevaOS a681b43a, Oracle Simphony) opens
--  10/31. Before this, 15 of its POS items reached a bottle (0106) and its item
--  list was the 76 bottles on the SGWS NY opening invoices. This links the rest
--  of the beverage menu that has a clear catalog bottle, so opening-night sales
--  deplete stock, and puts those bottles on Lady Delilah's list so counters
--  find them first.
--
--  1. 161 POS links (counting-side new_recipes + new_recipe_pos_skus scoped to
--     LD, like 0106; KevaOS menu_item_recipe_map untouched):
--       * spirit pours at 1.5 fl.oz -- the Delilah house pour (Delilah LA +
--         Miami: 112 spirit recipes, all 1.5 fl.oz);
--       * "Btl ..." bottle service = 1 whole bottle of the same bottle;
--       * glass wine 5 fl.oz (Delilah Miami's GL spec), bottle wine = 1 bottle;
--       * beers / N/A bottles / Red Bull upcharges = 1 each; Louis XIII by the
--         ounce in its name; "$ add stt. germain" 1 fl.oz like 0106's Baileys.
--     Bottle sizes: what LD bought from SGWS NY where it did; otherwise the
--     size the sister Delilahs stock (first count confirms).
--     The two Chablis items go to the Chablis LD actually bought (La
--     Chablisienne, SGWS NY) -- the menu says Laroche.
--  2. 0106's six 2 fl.oz pours (Poppy's rule) move to the same 1.5 fl.oz, so
--     every Lady Delilah pour uses one spec.
--  3. Item list: every newly linked bottle LD has no price for gets a proxy
--     price in kount_venue_cost_overrides -- catalog cost (company-wide
--     purchase_items.avg_cost, newest), or the median of other venues'
--     prices when the catalog has none or is >2x off it (Komos Extra Anejo). is_manual = false and price_date = 2026-08-01, so the first real
--     LD invoice replaces it via kount_refresh_venue_invoice_costs (0113 now
--     routes LD's R365 invoices). Bottles with no price anywhere are linked
--     but not priced (listed by the final select).
--  4. venue_item_settings for the newly linked bottles (as 0106 did).
--
--  NOT linked (no clear catalog bottle, or LD's spec needed): cocktails (Black
--  Swan, Luck be a Lady, Red Tuxedo, Green Velvet, Famous Last Words, Not for
--  Nothing, Migonette Martini, 1000 Miles Away, Cafe Nocturne, Know A Guy,
--  Concrete Jungle, Night Market, Panty Droppa, Just One Drink x2) and the
--  "$ <classic>" upcharges; wines Faiveley Gevrey '23, Fonterutoli '16,
--  d'Issan '16, Matthiasson Chard '23, Chave St Joseph '23, Arzuaga '22, Tyler
--  Pinot '23, Cliff Lede SB '23; Estrella Jalisco; Reserva de la Familia
--  Anejo (catalog only has the Cristalino); Louis XIII Black Pearl; free
--  mixer modifiers (club soda, cola, tonic ... -- gun or bottle unknown);
--  juices, coffee, tea.
--  ROLLBACK: 0114_ROLLBACK_lady_delilah_opening_readiness.sql
-- =============================================================================
begin;

create temp table _m (pos text, mname text, qty numeric, unit text, note text) on commit drop;
insert into _m (pos, mname, qty, unit, note) values
  ('400 Conejos Mezcal', '400 Conejos Joven Mezcal 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('818 Añejo', '818 Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl 818 Añejo', '818 Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('818 Blanco', '818 Blanco 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl 818 Blanco', '818 Blanco 1L', 1, 'each', 'bottle service: whole bottle'),
  ('818 Reposado', '818 Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl 818 Reposado', '818 Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('818 Reserve', 'Eight Reserve (818) 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Eight Reserve By 818', 'Eight Reserve (818) 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Ardbeg 10 Yr', 'Ardbeg 10 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Ardbeg 10Yr', 'Ardbeg 10 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Basil Hayden', 'Basil Haydens 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Basil Hayden', 'Basil Haydens 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Belvedere', 'Belvedere 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Belvedere', 'Belvedere 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Belvedere 10', 'Belvedere 10 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Belvedere 10', 'Belvedere 10 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Blade & Bow', 'Blade and Bow Bourbon 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Blade And Bow Bourbon', 'Blade and Bow Bourbon 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Bulleit Bourbon', 'Bulleit Bourbon 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Bulleit Bourbon', 'Bulleit Bourbon 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Bushmills 10 Yr', 'Bushmills 10yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Bushmill’s Irish', 'Bushmills 10yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Casamigos Añejo', 'Casamigos Anejo 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Casamigos Añejo', 'Casamigos Anejo 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Casamigos Blanco', 'Casamigos Blanco 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Casamigos Blanco', 'Casamigos Blanco 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Casamigos Reposado', 'Casamigos Reposado 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Casamigos Reposado', 'Casamigos Reposado 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Cincoro Añejo', 'Cincoro Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Cincoro Añejo', 'Cincoro Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Cincoro Blanco', 'Cincoro Blanco 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Cincoro Blanco', 'Cincoro Blanco 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Cincoro Reposado', 'Cincoro Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Cincoro Reposado', 'Cincoro Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Clase Azul Reposado', 'Clase Azul Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Clase Azul Reposado', 'Clase Azul Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Clase Azul Ultra Añejo', 'Clase Azul Ultra Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Clase Azul Ultra', 'Clase Azul Ultra Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Don Julio 1942', 'Don Julio 1942 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Don Julio 1942', 'Don Julio 1942 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Don Julio Añejo', 'Don Julio Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Don Julio Añejo', 'Don Julio Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Don Julio Blanco', 'Don Julio Blanco 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Don Julio Reposado', 'Don Julio Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Don Julio Reposado', 'Don Julio Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Don Londres Blanco', 'Don Londres Blanco 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Don Londres Blanco', 'Don Londres Blanco 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Don Londres Reposado', 'Don Londres Reposado 750mL', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Don Londres Reposado', 'Don Londres Reposado 750mL', 1, 'each', 'bottle service: whole bottle'),
  ('El Tesoro Añejo', 'El Tesoro Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl El Tesoro Añejo', 'El Tesoro Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('El Tesoro Blanco', 'El Tesoro Blanco 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl El Tesoro Blanco', 'El Tesoro Blanco 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('El Tesoro Reposado', 'El Tesoro Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl El Tesoro Reposado', 'El Tesoro Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Glenmorangie 12 Yr', 'Glenmorangie 12yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Glenmorangie 12Yr', 'Glenmorangie 12yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Glenmorangie 18 Yr', 'Glenmorangie 18yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Glenmorangie 18Yr', 'Glenmorangie 18yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Gran Coramino Añejo', 'Gran Coramino, Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Gran Coramino Añejo', 'Gran Coramino, Anejo 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Gran Coramino Reposado', 'Gran Coramino Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Gran Coramino Reposado', 'Gran Coramino Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Grey Goose', 'Grey Goose 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Grey Goose', 'Grey Goose 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Hakushu 12 Yr', 'Hakushu 12yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Hennessy VS', 'Hennessy VS 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Hennessy Vs', 'Hennessy VS 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Hennessy VSOP', 'Hennessy VSOP 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Hennessy XO', 'Hennessy XO 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Hennessy Xo', 'Hennessy XO 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Hibiki 21', 'Hibiki 21yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Hibiki Harmony', 'Hibiki Harmony 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Hibiki Harmony', 'Hibiki Harmony 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Jim Beam', 'Jim Beam Bourbon 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Jim Beam Bourbon', 'Jim Beam Bourbon 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Johnnie Walker Black', 'Johnnie Walker Black 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Johnny Walker Blue Label', 'Johnnie Walker Blue 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Johnnie Walker Blue Label', 'Johnnie Walker Blue 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Ketel One', 'Ketel One 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Knob Creek Bourbon', 'Knob Creek 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Knob Creek Rye', 'Knob Creek Rye 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Komos Extra Añejo', 'Komos Extra Anejo 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Komos Rosa Reposado', 'Komos Reposado Rosa', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Lagavulin 16 Yr', 'Lagavulin 16yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Lagavulin 16Yr', 'Lagavulin 16yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Laphroaig 10 Yr', 'Laphroaig 10yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Laphroaig 10Yr', 'Laphroaig 10yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Lobos Joven', 'Lobos Joven 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Lobos 1707 Joven', 'Lobos Joven 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Lobos Reposado', 'Lobos Reposado 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Lobos 1707 Reposado', 'Lobos Reposado 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Maker’s Mark', 'Makers Mark 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Mount Gay Eclipse', 'Mount Gay Ecliplse 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Mount Gay Eclipse', 'Mount Gay Ecliplse 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Mount Gay Silver', 'Mount Gay Silver 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Remy Martin VSOP', 'Remy Martin VSOP 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Remy Martin Vsop', 'Remy Martin VSOP 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Remy Martin XO', 'Remy Martin XO 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Remy Martin Xo', 'Remy Martin XO 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Ron Zacapa', 'Ron Zacapa 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Ron Zacapa No 23', 'Ron Zacapa 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Still Gin', 'STILL GIN 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Still G.I.N', 'STILL GIN 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Suntory Haku', 'Haku 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Suntory Haku', 'Haku 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Suntory Roku', 'Roku 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Suntory Roku', 'Roku 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Suntory Toki', 'Suntory Toki 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Suntory Toki', 'Suntory Toki 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Btl Tanqueray', 'Tanqueray 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('The Botanist', 'The Botanist 1L', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl The Botanist Gin', 'The Botanist 1L', 1, 'each', 'bottle service: whole bottle'),
  ('Volcan De Mi Tierra Blanco', 'Volcan De Mi Tierra Blanco 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Volcan X.A', 'Volcan De Mi Tierra X.A Reposado 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Volcan X.A', 'Volcan De Mi Tierra X.A Reposado 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Yamazaki 12 Yr', 'Yamazaki 12yr 750ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Btl Yamazaki 12', 'Yamazaki 12yr 750ml', 1, 'each', 'bottle service: whole bottle'),
  ('Yamazaki 18 Yr Mizunara', 'Yamazaki Mizunara 18yr 700ml', 1.5, 'fl.oz', 'house pour 1.5 fl.oz'),
  ('Remy Martin Louis XIII (1 oz)', 'Remy Martin Louis XIII Rare 700ml', 1, 'fl.oz', 'pour size in the item name'),
  ('Remy Martin Louis XIII (2 oz)', 'Remy Martin Louis XIII Rare 700ml', 2, 'fl.oz', 'pour size in the item name'),
  ('$ add stt. germain', 'St. Germain 750ml', 1, 'fl.oz', 'add-on pour (same as $ add bailey''s)'),
  ('$ redbull', 'Red Bull 8.4fl.oz', 1, 'each', 'mixer upcharge: whole can'),
  ('$ sf redbull', 'Red Bull Sugar Free 1each', 1, 'each', 'mixer upcharge: whole can'),
  ('$ peach redbull', 'Red Bull Peach 8.4fl.oz', 1, 'each', 'mixer upcharge: whole can'),
  ('$ watermelon redbull', 'Red Bull Watermelon 8.4fl.oz', 1, 'each', 'mixer upcharge: whole can'),
  ('$ ginger beer', 'Fever Tree Gingerbeer 200ml', 1, 'each', 'mixer upcharge: whole bottle'),
  ('Budlight', 'Bud Light 12fl.oz', 1, 'each', 'beer: whole bottle'),
  ('Budweiser', 'Budweiser 12fl.oz', 1, 'each', 'beer: whole bottle'),
  ('Crazy Mountain', 'Crazy Mountain Original Lager', 1, 'each', 'N/A beer: whole can'),
  ('Crazy Mountain Lime', 'Crazy Mountain LIme', 1, 'each', 'N/A beer: whole can'),
  ('Goose IPA', 'Goose Island IPA 12fl.oz', 1, 'each', 'beer: whole bottle'),
  ('Michelob Ultra', 'Michelob Ultra 12fl.oz', 1, 'each', 'beer: whole bottle'),
  ('Stella', 'Stella Artois 11.2fl.oz', 1, 'each', 'beer: whole bottle'),
  ('Diet Coke', 'Diet Coke - Bev 8fl.oz', 1, 'each', 'whole bottle; 8oz glass like Coke (0106)'),
  ('Sprite', 'Sprite 8fl.oz', 1, 'each', 'whole bottle; 8oz glass like Coke (0106)'),
  ('Ginger Ale', 'Fever Tree Ginger Ale 200ml', 1, 'each', 'whole bottle; Fever-Tree 200ml (Delilah standard)'),
  ('Ginger Beer', 'Fever Tree Gingerbeer 200ml', 1, 'each', 'whole bottle; Fever-Tree 200ml (Delilah standard)'),
  ('Club Soda', 'Fever Tree Club Soda 200ml', 1, 'each', 'whole bottle; Fever-Tree 200ml (Delilah standard)'),
  ('Tonic', 'Fever Tree Tonic Water 200ml', 1, 'each', 'whole bottle; Fever-Tree 200ml (Delilah standard)'),
  ('SF Red Bull', 'Red Bull Sugar Free 1each', 1, 'each', 'whole can'),
  ('Seedlip Garden', 'Seedlip Garden #108 Distil 700ML', 1.5, 'fl.oz', 'N/A spirit, house pour 1.5 fl.oz'),
  ('Seedlip Grove', 'Seedlip Grove', 1.5, 'fl.oz', 'N/A spirit, house pour 1.5 fl.oz'),
  ('Lyres Italian', 'Lyres Italian Spritz 700ml', 1.5, 'fl.oz', 'N/A aperitif, house pour 1.5 fl.oz'),
  ('Jolene Black', 'Jolene Black', 1, 'each', 'whole can'),
  ('1.5L Champagne Veuve Clicquot Grande Dame Magnum', 'Veuve Clicquot, ''La Grande Dame'', Champagne', 1, 'each', 'whole magnum'),
  ('Champagne Veuve Clicquot Grande Dame', 'Veuve Clicquot, ''La Grande Dame'', Brut Champagne 750ml', 1, 'each', 'whole bottle'),
  ('Brunello Il Poggione ''20', 'Il Poggione, Brunello di Montalcino', 1, 'each', 'whole bottle'),
  ('Btl Champagne Telmont', 'Telmont, Brut Champagne 750ml', 1, 'each', 'whole bottle'),
  ('GL Champagne Telmont', 'Telmont, Brut Champagne 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('BTL SANCERRE Garrault ''25', 'Isabelle Garrault, ''Les Grands Monts'', Sancerre', 1, 'each', 'whole bottle'),
  ('CAB SAUV Phelps ''22', 'Joseph Phelps, Cabernet Sauvignon', 1, 'each', 'whole bottle'),
  ('Chablis Laroche', 'La Chablisienne Chablis La Pierrelee ''23 2023 750ml', 1, 'each', 'whole bottle; the Chablis LD bought (SGWS NY) -- menu says Laroche'),
  ('GL Chablis Laroche', 'La Chablisienne Chablis La Pierrelee ''23 2023 750ml', 5, 'fl.oz', 'glass 5 fl.oz; the Chablis LD bought (SGWS NY) -- menu says Laroche'),
  ('GL CAB SAUV Chappellet 24''', 'Chappellet, Cabernet Sauvignon', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('GL PINOT GRIGIO Elena Walch ''25', 'Elena Walch Pinot Grigio', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('Gl Champagne Moet Rose', 'Moet, ''Imperial'', Rose Champagne 750ml', 5, 'fl.oz', 'glass 5 fl.oz (Delilah Miami spec)'),
  ('Gl Prosecco Giuliana', 'Giuliana Prosecco 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('Gl Rose Minuty', 'Minuty, ''Prestige'', Rose 2025 750ml', 5, 'fl.oz', 'glass 5 fl.oz'),
  ('Gl Rose Minuty 281', 'Minuty, ''281'', Rose 2024 750ml', 5, 'fl.oz', 'glass 5 fl.oz');

-- every POS name is a real Lady Delilah menu item and not linked yet; every
-- bottle name is exactly one active, unmerged catalog item
do $$ begin
  if exists (select 1 from _m where not exists (
       select 1 from public.simphony_menu_item_dimensions d
        where d.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and lower(trim(d.name)) = lower(trim(_m.pos)))) then
    raise exception '0114: % is not on the Lady Delilah menu',
      (select string_agg(pos, ', ') from _m where not exists (select 1 from public.simphony_menu_item_dimensions d
        where d.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and lower(trim(d.name)) = lower(trim(_m.pos))));
  end if;
  if exists (select 1 from _m where (select count(*) from public.master_items mi
              where mi.name = _m.mname and mi.is_active and mi.merged_into_id is null) <> 1) then
    raise exception '0114: bottle not uniquely resolvable: %',
      (select string_agg(mname, ', ') from _m where (select count(*) from public.master_items mi
        where mi.name = _m.mname and mi.is_active and mi.merged_into_id is null) <> 1);
  end if;
  if exists (select 1 from public.new_recipe_pos_skus s join _m on lower(trim(s.pos_sku)) = lower(trim(_m.pos))
              where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') then
    raise exception '0114: a POS item is already linked at Lady Delilah -- review before re-running';
  end if;
end $$;

create temp table _x on commit drop as
select _m.*, mi.id as mid, gen_random_uuid() as rid
  from _m join public.master_items mi on mi.name = _m.mname and mi.is_active and mi.merged_into_id is null;

-- ingredient name per bottle: reuse the name already mapped to it (the
-- '<name> Base Item' one first), else create '<name> Base Item'
create temp table _ing on commit drop as
select distinct on (x.mid) x.mid, coalesce(nm.ingredient_name, x.mname || ' Base Item') as ing
  from _x x
  left join public.new_recipe_ingredient_master_map nm on nm.master_item_id = x.mid
 order by x.mid, (nm.ingredient_name = x.mname || ' Base Item') desc nulls last, nm.ingredient_name;

insert into public.new_recipe_ingredient_master_map (ingredient_name, master_item_id)
select ing, mid from _ing
on conflict (ingredient_name) do nothing;

do $$ begin
  if exists (select 1 from _ing i join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = i.ing
              where nm.master_item_id <> i.mid) then
    raise exception '0114: an ingredient name already maps to a different bottle';
  end if;
end $$;

insert into public.new_recipes (id, name, recipe_type, category, item_category, venue_id, yield_qty, yield_uom, is_active, notes)
select rid, pos || ' · Lady Delilah', 'beverage', 'Beverage', 'Lady Delilah pours', null, 1, 'each', true,
       'Lady Delilah POS link (0114, 2026-10-27): ' || note || '.'
  from _x;
insert into public.new_recipe_ingredients (recipe_id, ingredient_name, quantity, unit, sort_order, source, is_sub_recipe)
select x.rid, i.ing, x.qty, x.unit, 1, 'Lady Delilah default -- ' || x.note, false
  from _x x join _ing i on i.mid = x.mid;
insert into public.new_recipe_pos_skus (recipe_id, pos_sku, venue_id)
select rid, pos, 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'::uuid from _x;

-- 0106's 2 fl.oz pours -> the 1.5 fl.oz Delilah house pour
update public.new_recipe_ingredients ri
   set quantity = 1.5, source = 'Lady Delilah default -- Delilah house pour 1.5 fl.oz (0114; was 2 fl.oz, Poppy rule)'
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.recipe_id = ri.recipe_id
   and s.pos_sku in ('Don Julio Blanco', 'Ketel One', 'Tanqueray', 'Mount Gay Silver', 'Fernet Branca', 'Johnny Walker Black Label')
   and ri.quantity = 2 and ri.unit = 'fl.oz';
update public.new_recipes r
   set name = replace(r.name, ' 2oz ', ' 1.5oz ')
  from public.new_recipe_pos_skus s
 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.recipe_id = r.id and s.pos_sku in ('Don Julio Blanco', 'Ketel One', 'Tanqueray', 'Mount Gay Silver', 'Fernet Branca', 'Johnny Walker Black Label');

-- item list: proxy prices for linked bottles LD has no price for
insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v14', p.mid, round(p.cost::numeric, 4), p.src, 'ld-proxy-costing-2026-10-27', false, date '2026-08-01', now()
  from (
    select b.mid,
           case when b.use_cat then b.cat_cost else b.ven_cost end as cost,
           case when b.use_cat
                then 'PROXY catalog cost (company-wide purchase_items.avg_cost) as of 2026-10-27; replaced by the first Lady Delilah invoice'
                else 'PROXY median of other venues'' prices as of 2026-10-27; replaced by the first Lady Delilah invoice' end as src
      from (
        select c.*,
               -- catalog cost unless it is missing or >2x off the other venues' median (Komos XA: catalog $58 vs $351)
               c.cat_cost is not null and (c.ven_cost is null or c.cat_cost between c.ven_cost / 2 and c.ven_cost * 2) as use_cat
          from (
        select d.mid,
               (select p.avg_cost from public.purchase_items p where p.master_item_id = d.mid and p.avg_cost > 0
                 order by p.updated_at desc nulls last, p.id desc limit 1) as cat_cost,
               (select percentile_cont(0.5) within group (order by o.cost_per_unit)
                  from public.kount_venue_cost_overrides o where o.master_item_id = d.mid and o.venue_id <> 'v14'
                   and o.cost_per_unit > 0) as ven_cost
          from (select distinct mid from _x) d
         where not exists (select 1 from public.kount_venue_cost_overrides o where o.venue_id = 'v14' and o.master_item_id = d.mid)
          ) c
      ) b
  ) p
 where p.cost is not null;

insert into public.venue_item_settings (venue_id, master_item_id, notes)
select distinct 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'::uuid, mid, 'Lady Delilah: linked to a POS item (0114, 2026-10-27)' from _x
on conflict (venue_id, master_item_id) do nothing;

-- every Lady Delilah link ends on an active bottle, and 0106's pours are 1.5
do $$ begin
  if (select count(*) from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0') <> 15 + 161 then
    raise exception '0114: expected % POS links', 15 + 161;
  end if;
  if exists (
    select 1 from public.new_recipe_pos_skus s
      join public.new_recipes r on r.id = s.recipe_id
      join public.new_recipe_ingredients ri on ri.recipe_id = r.id and coalesce(ri.is_sub_recipe, false) = false
      left join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = ri.ingredient_name
      left join public.master_items mi on mi.id = nm.master_item_id
     where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and r.item_category = 'Lady Delilah pours'
       and (mi.id is null or not mi.is_active)) then
    raise exception '0114: a Lady Delilah pour does not reach an active bottle';
  end if;
  if exists (select 1 from public.new_recipe_pos_skus s join public.new_recipe_ingredients ri on ri.recipe_id = s.recipe_id
              where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and s.pos_sku in ('Don Julio Blanco', 'Ketel One', 'Tanqueray', 'Mount Gay Silver', 'Fernet Branca', 'Johnny Walker Black Label') and ri.quantity <> 1.5) then
    raise exception '0114: a 0106 pour was not resized';
  end if;
end $$;

select 'links' k, count(*)::text v from public.new_recipe_pos_skus where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
union all select 'priced items (v14)', count(*)::text from public.kount_venue_cost_overrides where venue_id = 'v14'
union all select 'proxy priced now', count(*)::text from public.kount_venue_cost_overrides
           where venue_id = 'v14' and set_by = 'ld-proxy-costing-2026-10-27'
union all select 'linked, no price anywhere', coalesce(string_agg(distinct x.mname, '; '), '-')
  from _x x where not exists (select 1 from public.kount_venue_cost_overrides o where o.venue_id = 'v14' and o.master_item_id = x.mid);
commit;
