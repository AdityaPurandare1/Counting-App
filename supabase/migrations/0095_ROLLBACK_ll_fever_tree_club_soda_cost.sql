-- 0095_ROLLBACK: hands the Club Soda 200ml cost back to the nightly job (which will re-infer $1.89).
begin;
update public.kount_venue_cost_overrides o set is_manual = false, price_date = date '2026-10-01'
  from public.master_items m where o.master_item_id = m.id and o.venue_id = 'v11' and m.name = 'Fever Tree Club Soda 200ml';
commit;
