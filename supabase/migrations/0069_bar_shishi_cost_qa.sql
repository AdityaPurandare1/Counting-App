-- =============================================================================
--  0069_bar_shishi_cost_qa  (DATA)
--  Case-vs-bottle QA of all v13 costs against catalog / other-venue costs /
--  invoice medians (Aditya asked 2026-10-07). Findings fixed here:
--   · The BEER tab of "Bar Shi Shi Beverage Order Guide 2026.xlsx" carries
--     Delilah Miami template numbers (Hitachino $29.76 = Hoegaarden's, Agara
--     $29.40 = Stella Liberte's, Crazy Mountain $40.60 = Goose Island's) — not
--     Shishi prices. Beer reverted to real invoices; Agara back to unpriced.
--   · Belvedere 750ml catalog $38.04 > the 1L price; pro-rated from Azul 1L.
--   · Cherry Tomato source marked low confidence (unit unknown).
-- =============================================================================
begin;
insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v13', v.mid, v.cost, v.source, 'shishi-cost-qa-2026-10-07', false, date '2026-08-01', now()
from (values
  ('a8804849-a61b-48b1-90df-17123dfdd18e'::uuid, 4.3500, 'PROXY Bird Streets: HITACHINO NEST WHITE $104.40 / 24 = $4.35 (Shishi guide $1.24 was a Delilah template carry-over)'),
  ('52942b50-37fc-4a22-b90f-9a0cc1879783'::uuid, 1.5700, 'PROXY Delilah Miami: CRAZY MTN C24 $37.60 / 24 = $1.57 (Shishi guide $1.69 was a template carry-over)'),
  ('4a80dae2-6f67-4dd5-9e7a-d06ef15a90f5'::uuid, 1.0300, 'PROXY Delilah Miami Eagle Brands Sales inv #2814018 2026-09-10: $24.75, line / pack 24.0000 = $1.03 (Shishi guide figure was a template carry-over)'),
  ('7a71d089-5ddf-4e15-84d0-6aa72c290e48'::uuid, 1.3900, 'PROXY Delilah Miami Eagle Brands Sales inv #2825093 2026-09-25: $33.30, line / pack 24.0000 = $1.39 (Shishi guide figure was a template carry-over)'),
  ('048776ac-423b-419b-b035-4c146aee8d25'::uuid, 25.3100, 'SHISHI costed order guide: Azul receipt Belvedere 1L $33.75 pro-rated to 750ml (catalog $38.04 was above the 1L price; low confidence)')
) v(mid, cost, source)
on conflict (venue_id, master_item_id) do update
  set cost_per_unit = excluded.cost_per_unit, source = excluded.source, set_by = excluded.set_by,
      is_manual = false, price_date = excluded.price_date, updated_at = now();
delete from public.kount_venue_cost_overrides where venue_id = 'v13' and master_item_id = 'fc5a1670-02ad-4c98-b311-6e912d1f99ee';
update public.kount_venue_cost_overrides set source = source || ' (low confidence: unit)'
 where venue_id = 'v13' and master_item_id = 'd922615e-9bb0-475c-93b2-06f398a52f00' and source not like '%low confidence%';
commit;
