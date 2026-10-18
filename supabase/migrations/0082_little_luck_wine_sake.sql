-- =============================================================================
--  0082_little_luck_wine_sake  (DATA, not schema)
--
--  Loads Little Luck's wine + sake list from
--  "PRE_OPENING_INVENTORY SHEET_Little Luck_101826.xlsx" so counters can count
--  it immediately: 143 items (94 WINE, 49 SAKE), 125 with a bottle price.
--
--  WHY NEW MASTERS RATHER THAN FUZZY-LINKING TO THE EXISTING CATALOG
--  Only 6 of 143 match an existing master by exact name. Trigram scoring finds
--  a plausible match for most of the rest, but inspection showed the best
--  match is repeatedly the WRONG SIZE -- "Veuve Clicquot, Yellow Label" best-
--  matches the 6L, "Ace of Spades, Rose" the 9L, "Dom Perignon, Rose" the 3L,
--  "Perrier Jouet, Belle Epoque" the 3L. The venue sheet carries no size, so
--  these are standard 750ml bottles. Auto-linking would attach a 750ml count
--  to a large-format master and corrupt both cost and variance -- precisely how
--  Alphabet's baseline went wrong (818 Blanco -> Don Julio Blanco, Yamazaki
--  12yr -> 10yr). So each line is created under the venue's own name, which is
--  also what the counter reads off the shelf.
--
--  CONSEQUENCE, STATED PLAINLY: this will create near-duplicates of catalog
--  rows that differ only by format. ~54 scored >= 0.6 similarity. That is a
--  deliberate, reversible trade (0047 merge_master_items exists for exactly
--  this) taken because counters were mid-count and a wrong size link is worse
--  than a duplicate.
--
--  Sake is filed under 'Wine Cost' because that is where this catalog already
--  keeps it (45 of 60 existing sake/junmai/ginjo rows).
--
--  Costs: is_manual = false, so kount_refresh_venue_invoice_costs overwrites
--  them once real itemised invoices arrive.
--
--  ROLLBACK: 0082_ROLLBACK_little_luck_wine_sake.sql
-- =============================================================================

begin;

create temp table _llw (item text, sheet text, section text, price numeric) on commit drop;
insert into _llw values
  ('Prosecco, Giuliana','WINE','Sparkling by the Glass',1.08),
  ('Champagne, Telmont','WINE','Sparkling by the Glass',38.0),
  ('Champagne Rose, Moet & Chandon 187ml','WINE','Sparkling by the Glass',12.17),
  ('Lambrusco, Lucci, Emilia Romagna, Italy','WINE','Sparkling by the Glass',12.5),
  ('Sparkling by the Bottle','WINE','Sparkling by the Glass',null),
  ('Ace of Spades, Brut Champagne','WINE','Sparkling by the Glass',225.0),
  ('Ace of Spades, Rose Champagne','WINE','Sparkling by the Glass',337.5),
  ('Billecart-Salmon, Le Rose, Rose Champagne','WINE','Sparkling by the Glass',87.5),
  ('Delamotte, Blanc de Blancs Champagne, Les Mesnil','WINE','Sparkling by the Glass',58.67),
  ('Dom Perignon, Brut Champagne','WINE','Sparkling by the Glass',225.0),
  ('Dom Perignon, Luminous White, Brut Champagne','WINE','Sparkling by the Glass',301.5),
  ('Dom Perignon, Rose Champagne','WINE','Sparkling by the Glass',410.25),
  ('Krug, Grande Cuvee, Brut Champagne','WINE','Sparkling by the Glass',216.0),
  ('Perrier Jouet, Belle Epoque, Brut Champagne','WINE','Sparkling by the Glass',198.33),
  ('Perrier Jouet, Belle Epoque, Rose Champagne','WINE','Sparkling by the Glass',175.0),
  ('Perrier Jouet, Grand Brut, Brut Champagne','WINE','Sparkling by the Glass',44.0),
  ('Pierre Peters','WINE','Sparkling by the Glass',60.0),
  ('Ruinart, Blanc de Blancs Champagne 375ml','WINE','Sparkling by the Glass',37.75),
  ('Ruinart, Blanc de Blancs Champagne 750ml','WINE','Sparkling by the Glass',66.0),
  ('Veuve Clicquot, Rose Champagne','WINE','Sparkling by the Glass',56.5),
  ('Veuve Clicquot, Yellow Label, Brut Champagne','WINE','Sparkling by the Glass',56.5),
  ('Veuve Clicquot, Le Grand Dame, Brut Champagne','WINE','Sparkling by the Glass',165.0),
  ('White By the Glass - 5oz Pour','WINE','Sparkling by the Glass',null),
  ('White Blend (Pinot Blanc/Muskateller/Chardonnay), Heidi Shrock, More is More, Burgenland, Austria','WINE','Sparkling by the Glass',20.0),
  ('Riesling, Dönnhoff, Estate, Nahe, DE 2024','WINE','Sparkling by the Glass',16.67),
  ('Macon Villages, Verget, Grand Elevage, Burgundy, FR 2024','WINE','Sparkling by the Glass',20.0),
  ('Sancerre, Fermin Dezat, Loire Valley, FR 2025','WINE','Sparkling by the Glass',24.0),
  ('Rose by the Glass - 5oz Pour','WINE','Sparkling by the Glass',null),
  ('Rose, Minuty, Prestige, Cotes de Provence 2025','WINE','Sparkling by the Glass',16.0),
  ('Rose, Minuty, 281, Cotes de Provence 2025','WINE','Sparkling by the Glass',52.0),
  ('Red by the Glass - 5oz Pour','WINE','Sparkling by the Glass',0.0),
  ('Chilled Red, Vinos Finos de California, Sabroso!, California','WINE','Sparkling by the Glass',14.7),
  ('Grenache/Mourvedre/Syrah, Chateau de Montmirail, Vacqueyras, Rhone Valley, FR 2022','WINE','Sparkling by the Glass',16.33),
  ('Bourgogne Rouge, Domaine Camus-Bruchon, Burgundy, FR 2023','WINE','Sparkling by the Glass',22.0),
  ('Bordeaux Blend, Chevalier de Lascombes, Margaux, FR 2023','WINE','Sparkling by the Glass',25.0),
  ('Sweet By The Glass - 2.5oz pour','WINE','Sparkling by the Glass',null),
  ('Chenin Blanc Moelleux, Francois Chidaine, Vin de France 2016','WINE','Sparkling by the Glass',31.33),
  ('Moscato d''Asti, G.D. Vajra, Piedmont 2025','WINE','Sparkling by the Glass',14.1),
  ('White By the Bottle','WINE','Sparkling by the Glass',null),
  ('Bourgogne Blanc, Domaine DeMontille, Clos du Chateau 2023','WINE','Sparkling by the Glass',31.0),
  ('Chablis, Moreau Naudet, Burgundy France 2024','WINE','Sparkling by the Glass',40.0),
  ('Chardonnay (Skin Fermented), Scribe Winery, Sonoma Valley, CA 500ml','WINE','Sparkling by the Glass',29.0),
  ('Chardonnay, Bodega Chacra, Mainque, Patagonia, ARG 2024','WINE','Sparkling by the Glass',55.5),
  ('Chenin Blanc, Francois Chidaine, Montlouis, ''Les Choisilles'' 2023','WINE','Sparkling by the Glass',32.33),
  ('Gruner Veltliner, Jager, Federspiel, Reid Klaus, Wachau, AS 2024','WINE','Sparkling by the Glass',24.0),
  ('Heritiers du Comtes Lafon, Macon Milly Lamartine, Burgundy, FR 2024','WINE','Sparkling by the Glass',25.67),
  ('Puligny Montrachet, Paul Pernot, Burgundy, FR 2024','WINE','Sparkling by the Glass',72.33),
  ('Riesling, H. Ludes, Kabinett Ritsch Terrassen, Mosel - Germany, DE 2022','WINE','Sparkling by the Glass',23.33),
  ('Riesling, Von Winning, Ungeheuer - Grosses Gewachs, Pfalz, DE 2023','WINE','Sparkling by the Glass',56.67),
  ('Vermentino, Domaine u Stiliccionu, Ajaccio Emy-Lidia 2021','WINE','Sparkling by the Glass',25.0),
  ('Cider by the Bottle','WINE','Sparkling by the Glass',null),
  ('Cider, Eric Bordelet, Sidre Brut Tendre, Normandy, FR','WINE','Sparkling by the Glass',124.0),
  ('Cider, Eric Bordelet, Sparkling Perlant Apple Juice,, Normandy, FR 330ml','WINE','Sparkling by the Glass',62.0),
  ('Rose & Chilled Red by the Bottle','WINE','Sparkling by the Glass',null),
  ('Minuty','WINE','Sparkling by the Glass',16.0),
  ('Minuty ''281''','WINE','Sparkling by the Glass',52.5),
  ('Chilled Red, Vinos Finos de California, Sabroso!, California 2024','WINE','Sparkling by the Glass',16.5),
  ('Red by the Bottle','WINE','Lucci Lambrusco',0.0),
  ('Beaune, Paul Pernot, Clos des Dessus de Marconnets, Burgundy, FR 2024','WINE','Lucci Lambrusco',259.98),
  ('Castillon Côtes de Bordeaux, Chateau Montlandrie, Bordeaux, FR 2014','WINE','Lucci Lambrusco',222.0),
  ('Chateauneuf du Pape, Domaine Brun-Avril, Rhone Valley, FR 2021','WINE','Lucci Lambrusco',540.0),
  ('Chianti Classico, Felsina, Cru Rancia, Tuscany, IT 2020','WINE','Lucci Lambrusco',51.33),
  ('Coteaux Bourgogne, Anne et Sébastien Bidault 2024','WINE','Lucci Lambrusco',288.0),
  ('Dolcetto d''Alba, Cascina Penna Currado, Bricco Lago 2024','WINE','Lucci Lambrusco',168.0),
  ('Gamay, Theo Dancer, ''Botanica'', Vin de France 2024','WINE','Lucci Lambrusco',552.0),
  ('Langhe Nebbiolo, Stefano Occhetti, Piedmont, IT 2024','WINE','Lucci Lambrusco',300.0),
  ('Tempranillo, Artadi, Vinas de Gain, Rioja, ESP 2023','WINE','Lucci Lambrusco',300.0),
  ('Tempranillo, Emilio Moro, Malleolus, Ribera del Duero, ESP 2022','WINE','Lucci Lambrusco',488.0),
  ('Vintage + Rare by the Bottle','WINE','Lucci Lambrusco',null),
  ('Meursault, Xavier Monnot, Charmes 1er Cru 2022','WINE','CHARDONNAY',140.0),
  ('Chardonnay, Aubert, Lauren','WINE','CHARDONNAY',113.33),
  ('Chardonnay, Peter Michael, Belle Cote 2018','WINE','CHARDONNAY',90.0),
  ('Corton Charlemagne, Bouchard Pere & Fils, Burgundy, FR 2022','WINE','CHARDONNAY',168.0),
  ('Puligny Montrachet, Domain Dujac, Les Folatieres, Burgundy 2023','WINE','CHARDONNAY',200.0),
  ('Puligny Montrachet, Domain Leflaive, Clavoillon, Burgundy 2022','WINE','CHARDONNAY',364.25),
  ('PINOT NOIR','WINE','CHARDONNAY',null),
  ('Beaune, Domaine DeMontille, Greves 1er Cru, Burgundy, FR 2023','WINE','CHARDONNAY',1023.96),
  ('Bonnes Mares, Comte Georges de Vogue, Burgundy, FR 2018','WINE','CHARDONNAY',645.0),
  ('Clos Vougeot, Roche de Bellene, Burgundy, FR 2021','WINE','CHARDONNAY',325.0),
  ('Le Corton, Bouchard Pere & Fils, Burgundy, FR 2019','WINE','CHARDONNAY',168.0),
  ('Pinot Noir, Littorai, The Haven Vineyard, Sonoma Coast, CA 2010','WINE','CHARDONNAY',280.0),
  ('Nuits St Georges, J.-F. Mugnier, Clos de la Marechalle, Burgundy, FR 2021','WINE','CHARDONNAY',230.0),
  ('Pinot Noir, Kosta Browne, Cerise Vineyard, Anderson Valley, CA 2021','WINE','CHARDONNAY',130.0),
  ('CABERNET SAUVIGNON','WINE','CHARDONNAY',null),
  ('Cabernet Sauvignon, BOND, Vecina Napa Valley, CA 2021','WINE','CHARDONNAY',625.0),
  ('Cabernet Sauvignon, Dunn, Howell Mountain, Napa Valley, CA 2019','WINE','CHARDONNAY',144.0),
  ('Cabernet Sauvignon, Harlan Estate, Napa Valley, CA 2019','WINE','CHARDONNAY',1080.0),
  ('Cabernet Sauvignon, Hundred Acre, Morgan''s Way 2022','WINE','CHARDONNAY',530.0),
  ('Cabernet Sauvignon, Joseph Phelps, Insignia Napa Valley, CA 2022','WINE','CHARDONNAY',273.75),
  ('Cabernet Sauvignon, Opus One 2018 1.5L MAGNUM','WINE','CHARDONNAY',706.99),
  ('Cabernet Sauvignon, Opus One, Napa Valley, CA 2017','WINE','CHARDONNAY',318.49),
  ('Napa Valley Red, Joseph Phelps, Insignia, Napa Valley, CA 2022','WINE','CHARDONNAY',237.75),
  ('Sweet By The Bottle','WINE','CHARDONNAY',null),
  ('Coteaux du Layon, Moulin Touchais, Loire Valley, FR 2005','WINE','CHARDONNAY',136.0),
  ('Daiginjo, Akitabare Brewery, Winter Blossom 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',58.2),
  ('Doburoku, Koyama Honke Shuzo Brewery, Mountain Warrior','SAKE','SAKE BY THE GLASS - 6oz / 180ml',21.0),
  ('Ginjo, Dewazakura Brewery, Oka - Cherry Bouquet 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',55.29),
  ('Junmai Daiginjo, Sake Ono 720ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',31.0),
  ('Junmai, Heiwa Shuzo Brewery, Kid 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',44.0),
  ('Nigori, Oka Brewery, Yuki no Tenshi - Snow Angel 180ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',4.5),
  ('Sparkling, Festival of Stars, 330ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',12.13),
  ('Tokubetsu Junmai, Niizawa Brewery, The Connoisseur 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',34.0),
  ('Tokubetsu Junmai, Tamagawa Brewery, Heart of Oak 720ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',24.74),
  ('NIGORI','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Kamoizumi Brewery, Summer Snow 500ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',21.34),
  ('SPARKLING','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Matsuura Shuzo | Junmai Ginjo, Sen| Ishikawa','SAKE','SAKE BY THE GLASS - 6oz / 180ml',23.0),
  ('JUNMAI GINJO','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Matsumidori Brewery, Junmai Ginjo, S. Tokyo, Kanagawa','SAKE','SAKE BY THE GLASS - 6oz / 180ml',33.0),
  ('Azumatsuru, Junmai Ginjo, White, Saga','SAKE','SAKE BY THE GLASS - 6oz / 180ml',34.0),
  ('Azumatsuru, Junmai Ginjo, Black, Saga','SAKE','SAKE BY THE GLASS - 6oz / 180ml',34.0),
  ('Seto Brewery, Ashigarigo Zerogo Mugen FF Kanagawa','SAKE','SAKE BY THE GLASS - 6oz / 180ml',104.0),
  ('JUNMAI','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Heavensake, Konishi 720ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',31.0),
  ('Sharaku Brewery','SAKE','SAKE BY THE GLASS - 6oz / 180ml',35.0),
  ('Shirasugi Brewery, Tokubetsu, Black Swan','SAKE','SAKE BY THE GLASS - 6oz / 180ml',33.0),
  ('Shirasugi Brewery, Tokubetsu, Chimera','SAKE','SAKE BY THE GLASS - 6oz / 180ml',36.0),
  ('Tokubetsu Junmai, Tamagawa Brewery, Heart of Oak','SAKE','SAKE BY THE GLASS - 6oz / 180ml',25.5),
  ('DAIGINJO','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Akitabare Brewery, Suirakuten - Heaven of Tipsy Delight','SAKE','SAKE BY THE GLASS - 6oz / 180ml',60.14),
  ('Otokoyama Brewery, Kita No Inaho Hokkaido','SAKE','SAKE BY THE GLASS - 6oz / 180ml',72.5),
  ('“KOZAEMON” NAKAJIMA BREWERY | GIFU','SAKE','SAKE BY THE GLASS - 6oz / 180ml',31.0),
  ('Daiichi Brewery, Daignijo Tobin Shizuku Sake, Black','SAKE','SAKE BY THE GLASS - 6oz / 180ml',106.67),
  ('JUNMAI DAIGINJO','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Dassai Brewery, 23 - Centerfuge','SAKE','SAKE BY THE GLASS - 6oz / 180ml',75.5),
  ('Heavensake, Junmai Daiginjo, Nizawa','SAKE','SAKE BY THE GLASS - 6oz / 180ml',75.5),
  ('Hiroki Brewery','SAKE','SAKE BY THE GLASS - 6oz / 180ml',98.0),
  ('IWA 5, Assemblage #3 2021','SAKE','SAKE BY THE GLASS - 6oz / 180ml',200.0),
  ('IWA 5, Assemblage #3 2021 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',375.0),
  ('IWA 5, Assemblage #6 2024','SAKE','SAKE BY THE GLASS - 6oz / 180ml',160.0),
  ('Niizawa Brewery, Zankyo Super 7, Miyagi 2024','SAKE','SAKE BY THE GLASS - 6oz / 180ml',410.0),
  ('Niizawa Brewery, Zankyo Super 7, Miyagi 2021','SAKE','SAKE BY THE GLASS - 6oz / 180ml',545.0),
  ('Junmai Daiginjo, Sake Ono, Rare 720ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',0.0),
  ('Uchigasaki Brewery, Hoyo Series, Junmai Daiginjo, Fair Maiden 500ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',23.77),
  ('Zaku, Shimizu Seizaburo Shoten Brewery, Selection N, Mie','SAKE','SAKE BY THE GLASS - 6oz / 180ml',90.0),
  ('LARGE FORMAT','SAKE','SAKE BY THE GLASS - 6oz / 180ml',null),
  ('Yoshia Brewing Company, Chrysanthemum Meadow 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',61.0),
  ('Yoshia Brewing Company, Lady Luck 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',69.0),
  ('Niizawa Brewery, Atagonomatsu - Summer Love 2026 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',125.0),
  ('Chitosetsuru, Junmai, Brown Bear 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',105.0),
  ('Koshinohomare, Junmai Ginjo, Nagi 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',120.0),
  ('Mitsui no Kotobuki, Porcini 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',115.0),
  ('Mitsui no Kotobuki, Coccinella 1800ml','SAKE','SAKE BY THE GLASS - 6oz / 180ml',115.0);

create temp table _llw_m on commit drop as
with ins as (
  insert into public.master_items (name, category, organization_id, is_active)
  select distinct on (lower(w.item)) w.item, 'Wine Cost',
         '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true
    from _llw w order by lower(w.item)
  on conflict (organization_id, name, category) do update set is_active = true
  returning id, name
)
select i.id as master_item_id, w.item, w.sheet, w.section, w.price
  from ins i join _llw w on lower(w.item) = lower(i.name);

-- 2. carried set (GLOBAL table -- no venue column exists on it)
insert into public.kount_carried_items (master_item_id, added_by_email, added_by_name, notes)
select m.master_item_id, 'apurandare@hwoodgroup.com', 'Aditya Purandare',
       'Little Luck pre-opening ' || m.sheet || ' list 2026-10-18'
  from _llw_m m
 where not exists (select 1 from public.kount_carried_items c where c.master_item_id = m.master_item_id);

-- 3. venue costs (bottle price from the sheet)
insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v11', m.master_item_id, m.price,
       'Little Luck pre-opening sheet 2026-10-18 (' || m.sheet || ' / ' || coalesce(nullif(m.section,''),'n/a') || ')',
       'apurandare@hwoodgroup.com', false, date '2026-10-18', now()
  from _llw_m m
 where m.price is not null and m.price > 0
on conflict (venue_id, master_item_id) do update
   set cost_per_unit = excluded.cost_per_unit,
       source        = excluded.source,
       is_manual     = false,
       price_date    = excluded.price_date,
       updated_at    = now();

select (select count(*) from _llw_m) masters_ready,
       (select count(*) from _llw_m m where m.price is not null and m.price > 0) priced,
       (select count(*) from public.kount_venue_cost_overrides where venue_id='v11') v11_costs_total;

commit;
