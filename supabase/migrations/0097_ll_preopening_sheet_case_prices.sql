-- =============================================================================
--  0097_ll_preopening_sheet_case_prices   (DATA)
--
--  The Little Luck pre-opening wine sheet (loaded as v11 costs in 0082) heads
--  its price column "BTL ($)", but some rows carry the 12-bottle CASE price.
--  A simulated close of LL-038 (rolled back) valued Theo Dancer Gamay at
--  $552 a bottle x 17 = $9,384, Brun-Avril Chateauneuf at $540 x 12 = $6,480.
--  None of these wines has an invoice line or another venue's price to check
--  against, so each was judged against what the wine sells for: the rows below
--  are a case price / 12 (Bidault's $288 / 12 = $24 matches Little Luck's own
--  invoice for it). Prosecco Giuliana's $1.08 is a typo; Alphabet's invoice
--  for the same 12-pack is $156 = $13.00.
--  Left as entered (plausible per bottle): Harlan, BOND, Opus One, Hundred
--  Acre, Vogue Bonnes-Mares, Krug, Dom Perignon, Ace of Spades, Insignia, etc.
--  Unsure, NOT changed (flagged to Aditya): Clos Vougeot Roche de Bellene
--  $325, Paul Pernot Clos des Dessus des Marconnets $259.98, Leflaive
--  Clavoillon $364.25, Mugnier Clos de la Marechalle $230.
--  ROLLBACK: 0097_ROLLBACK_ll_preopening_sheet_case_prices.sql
-- =============================================================================
begin;

create temp table _fix (name_like text, old numeric, new numeric, why text) on commit drop;
insert into _fix values
  ('Gamay, Theo Dancer, ''Botanica''%',                   552.00, 46.00,   '$552 = 12-bottle case'),
  ('Chateauneuf du Pape, Domaine Brun-Avril%',            540.00, 45.00,   '$540 = 12-bottle case'),
  ('Tempranillo, Emilio Moro, Malleolus%',                488.00, 40.6667, '$488 = 12-bottle case'),
  ('Langhe Nebbiolo, Stefano Occhetti%',                  300.00, 25.00,   '$300 = 12-bottle case'),
  ('Dolcetto d''Alba, Cascina Penna Currado%',            168.00, 14.00,   '$168 = 12-bottle case'),
  ('Castillon C%tes de Bordeaux, Chateau Montlandrie%',   222.00, 18.50,   '$222 = 12-bottle case'),
  ('Tempranillo, Artadi, Vinas de Gain%',                 300.00, 25.00,   '$300 = 12-bottle case'),
  ('Coteaux Bourgogne, Anne et S%bastien Bidault%',       288.00, 24.00,   '$288 = 12-bottle case (LL invoice: $288 / 12)'),
  ('Cider, Eric Bordelet, Sidre Brut Tendre%',            124.00, 10.3333, '$124 = 12-bottle case'),
  ('Cider, Eric Bordelet, Sparkling Perlant%',             62.00,  5.1667, '$62 = 12-bottle case'),
  ('Beaune, Domaine DeMontille, Greves 1er Cru%',        1023.96, 85.33,   '$1,023.96 = 12-bottle case'),
  ('Prosecco, Giuliana',                                    1.08, 13.00,   '$1.08 is a typo; Alphabet invoice for the same 12-pack is $156 = $13.00');

update public.kount_venue_cost_overrides o
   set cost_per_unit = f.new,
       source = o.source || ' | corrected 2026-10-20: ' || f.why || ' -> $' || f.new,
       updated_at = now()
  from _fix f, public.master_items m
 where o.venue_id = 'v11' and o.master_item_id = m.id
   and m.name like f.name_like
   and o.source ilike '%pre-opening%'
   and o.cost_per_unit = f.old;

select m.name, o.cost_per_unit::text as now
  from public.kount_venue_cost_overrides o join public.master_items m on m.id = o.master_item_id
 where o.venue_id = 'v11' and o.source like '%corrected 2026-10-20%'
 order by m.name;
commit;
