-- =============================================================================
--  0095_ll_fever_tree_club_soda_cost   (DATA, applied 2026-10-20)
--  0093 inferred a 12-pack for Little Luck's "2 FEVER TREE PRM CLB SD 200" line
--  ($22.70) against another venue's $1.51, giving $1.89/bottle. The Ginger Ale
--  and Ginger Beer 200ml lines on the same Beauchamp invoices are the same
--  $22.70 for 24 = $0.9458. Set by hand, is_manual, price_date today, so the
--  nightly job keeps it until a NEWER invoice line arrives.
--  ROLLBACK: 0095_ROLLBACK_ll_fever_tree_club_soda_cost.sql
-- =============================================================================
begin;
update public.kount_venue_cost_overrides o
   set cost_per_unit = 0.9458, is_manual = true, price_date = current_date, updated_at = now(), set_by = 'claude 2026-10-20',
       source = 'Fever-Tree 200ml 24-pack at $22.70 = $0.9458 (same price/pack as the Ginger Ale and Ginger Beer 200ml lines on the same Beauchamp invoices); the auto-inferred 12-pack ($1.89) was wrong'
  from public.master_items m
 where o.master_item_id = m.id and o.venue_id = 'v11' and m.name = 'Fever Tree Club Soda 200ml';
select m.name, o.cost_per_unit::text from public.kount_venue_cost_overrides o join public.master_items m on m.id=o.master_item_id where o.venue_id='v11' and m.name ilike 'Fever Tree%';
commit;
