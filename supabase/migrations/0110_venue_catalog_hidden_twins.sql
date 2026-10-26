-- =============================================================================
--  0110_venue_catalog_hidden_twins   (COLUMN + DATA)
--
--  0109's invoice source pulls in whatever product an invoice line is linked
--  to, and some Alphabet lines are linked to raw R365 item names or
--  placeholders -- the same twins the catalog exists to keep away from
--  counters ("STONY HILL CHARDONNAY NAPA 23 750ML" next to "Stony Hill,
--  Chardonnay").
--
--  kount_venue_catalog.hidden: a hidden row stays in the table (so the
--  insert-only nightly refresh, which does ON CONFLICT DO NOTHING, can never
--  bring it back) but the phone does not offer it.
--  Hidden for Alphabet: the five R365 placeholders, raw invoice-name twins of
--  a clean catalog product, kitchen items, and the 3L orange / grapefruit
--  pouches (the juices are counted and purchased in litres on the 1L items).
--  ROLLBACK: update kount_venue_catalog set hidden = false, hidden_reason = null where venue_id = 'v12';
--            alter table kount_venue_catalog drop column hidden, drop column hidden_reason;
-- =============================================================================
begin;

alter table public.kount_venue_catalog add column if not exists hidden boolean not null default false;
alter table public.kount_venue_catalog add column if not exists hidden_reason text;

update public.kount_venue_catalog c
   set hidden = true, hidden_reason = h.reason
  from public.master_items m,
       (values
         ('Missing Vendor Item -%',                       'R365 placeholder, names no product'),
         ('DIET COKE 8 OZ GLASS BOTTLE%',                 'raw invoice name; counted as Diet Coke - Bev 8fl.oz'),
         ('SODA-COCA COLA DIET',                          'raw invoice name; counted as Diet Coke - Bev 8fl.oz'),
         ('FEVER TREE PRM CLB SD 500',                    'raw invoice name; counted as Fever Tree Club Soda 500ml'),
         ('Gran Coramino Tequila Repo 750ML',             'raw invoice name; counted as Gran Coramino Reposado 750ml'),
         ('KETEL ONE VODKA 80 (BPC: 12, SIZE: 1L)',       'raw invoice name; counted as Ketel One 1L'),
         ('LYRE_S ITALIAN SPRITZ NON-ALCOHOLIC 700 ML',   'raw invoice name; counted as Lyres Italian Spritz 700ml'),
         ('MOET IMPERIAL BRUT ROSE CRV 187 ML',           'raw invoice name; counted as Moet Imperial Rose Splits 187ml'),
         ('PANNA NAT SPRING GLS (BPC: 12, SIZE: 1L)',     'raw invoice name; counted as Acqua Panna 1L'),
         ('RED BULL WHITE PEACH PCH ED CAN24P 8 oz',      'raw invoice name; counted as Red Bull Peach 8.4fl.oz'),
         ('STONY HILL CHARDONNAY NAP_ 23 750ML',          'raw invoice name; counted as Stony Hill, Chardonnay'),
         ('Chappellet Mountain Cuvee',                    'raw invoice name; counted as Chappellet Mountain Cuvee 2023 750ml'),
         ('3 Gal Cold Brew Conc BiB',                     'raw invoice name; counted as La Colombe Cold Brew Concentrate'),
         ('PUR_E-MANGO BOIRON',                           'raw invoice name; counted as Mango Puree 30fl.oz'),
         ('ANCHOVY IN OIL 28oz',                          'kitchen item'),
         ('CHILE POBLANO/PASILLA 5LB',                    'kitchen item'),
         ('PICKLE-DILL SLICED CRINKLE CH',                'kitchen item'),
         ('FRANZIA CSP WHT B 5L',                         'kitchen cooking wine'),
         ('orange juice 3L 3L',                           '3L pouch twin; juices are counted in litres on Orange Juice 1L'),
         ('MEP Grapefruit juice 3L 3L',                   '3L pouch twin; juices are counted in litres on Grapefruit Juice 1L')
       ) as h(pattern, reason)
 where c.venue_id = 'v12'
   and c.master_item_id = m.id
   and m.name like h.pattern
   and not c.hidden;

select count(*) filter (where not hidden) visible, count(*) filter (where hidden) hidden
  from public.kount_venue_catalog where venue_id = 'v12';
commit;
