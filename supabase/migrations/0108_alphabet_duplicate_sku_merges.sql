-- =============================================================================
--  0108_alphabet_duplicate_sku_merges   (DATA)
--
--  Alphabet's A-595 count (Robert Lacey, 10/26) showed Krug and Stony Hill as
--  never counted although they were: the bottles went onto TWIN catalog rows,
--  so variance read the priced row as 0 counted (-$1,296 Krug, -$1,425 Stony
--  Hill) and the twin as counted with no cost. About 32 items in A-595 split
--  this way (~ -$11,000 of false shortage).
--
--  Causes: duplicate active rows for one product, and Alphabet's own priced
--  rows switched off -- Krug 750ml and Komos Rosa Reposado were set
--  merged_into another row (Komos Rosa into plain Komos Reposado, a different
--  product) on 10/17 without their counts or prices moving; Vajra Albe 2021,
--  Il Poggione 2019 (and Tyler 2020, Pimento olives, a Jojo batch) were
--  deactivated together on 10/18 17:38. Neither is in kount_admin_audit_log,
--  procurement_master_item_merge_log or a counting migration.
--
--  Fix, for the 11 pairs that are unambiguously one product: keep the ACTIVE
--  row (the priced one where both are active), fold the other into it with
--  merge_master_items (entries, recounts, carried, UPCs, pending, redirects --
--  purchases follow via v_effective_receipts' merged_into_id), after first
--  carrying each venue's price, invoice item map and line map across where the
--  survivor has none. NOT merged (left for a decision): vintage changes (Dom
--  Perignon Rose 2009/2010, Tyler 2020/2022, Minuty 281 2023/2024), 750ml vs 1L
--  pairs, 'Krug Brut', house-made batches vs bought juice.
--  ROLLBACK: not automatic -- merges are logged in master_item_merge_repoints /
--  merged_into_id; reverse by hand per pair if needed.
-- =============================================================================
begin;

-- merge_master_items is corporate-only and reads the caller from the JWT.
select set_config('request.jwt.claims', json_build_object('email', 'apurandare@hwoodgroup.com', 'role', 'authenticated')::text, true);

create temp table _plan (winner uuid, losers uuid[], label text) on commit drop;
insert into _plan values
  ('f7793114-2ad4-4de9-bb92-dad0951cfb5d'::uuid, array['1b23cec8-6bf5-4120-82b3-7a019d5489e2']::uuid[], 'Krug, Grande Cuvee, Brut Champagne <- Krug, ''Grande Cuvee'', Brut Champagne 750ml'),
  ('78ace861-7f54-4a57-b5e2-862b7eb9d019'::uuid, array['45dd4f55-a218-4e8f-b806-e5d9335927ba']::uuid[], 'Komos Reposado Rosa <- Komos Rosa Reposado 750ml'),
  ('4441691f-62bf-41c7-9afc-3e5f83fa4da2'::uuid, array['90073510-4e6c-4e53-9412-1de3a23b34e1']::uuid[], 'G.D. Vajra, ''Albe'' Barolo <- G.D. Vajra, ''Albe'', Barolo 2021 750ml'),
  ('e2a6d558-83ee-469f-8a82-c9f9f1ca4a01'::uuid, array['b6facbec-45c0-4c53-8202-3bf8c5993602']::uuid[], 'Il Poggione, Brunello di Montalcino <- Il Poggione, Brunello di Montalcino 2019 750ml'),
  ('40535cc3-2492-433e-b2a4-f1b016c1daff'::uuid, array['2590cb3c-e9b8-4a53-b7a6-556ade83006d']::uuid[], 'La Scolca, ''Black Label'', Gavi dei Gavi <- La Scolca, ''Black Label'', Gavi dei Gavi 2023 750ml'),
  ('0966d1a8-a370-400e-b2f3-4c4d5fa1c1c6'::uuid, array['1077f0b6-7c77-4d14-a053-05a016f6ae86']::uuid[], 'Livio Felluga, Pinot Grigio <- Livio Felluga, Pinot Grigio 2023 750ml'),
  ('66d0a8f0-3cea-466e-ba84-f50d08a7885e'::uuid, array['0117d253-8feb-42c4-ad81-ce0d0d560a61']::uuid[], 'Chappellet, ''Mountain Cuvee'', Red Blend 2023 750ml <- Chappellet, ''Mountain Cuvee'', Red Blend'),
  ('6533229c-9a50-4893-9fed-9cc6fdc37dc0'::uuid, array['f2761447-4c5d-4e3f-a64c-8de7f35020c8']::uuid[], 'Stony Hill, Chardonnay <- Stony Hill, Napa Valley Chardonnay'),
  ('f404645f-7754-4b15-9bcb-3e3c3ee94005'::uuid, array['88f9cd02-65ff-4f20-b0cc-a01ed930b85c']::uuid[], 'St. Germain 750ml <- ST. GERMAIN ELDERFLOWER LIQUEUR 750ML'),
  ('e5c5d09f-949e-47c8-b4e8-a7c4a4e86cb4'::uuid, array['1cf44429-c16d-4b10-a97f-2c3baa53432f']::uuid[], 'Mr. Black Coffee Liqueur 750ml <- Mr Black Cold Brew Liqueur 750ml'),
  ('d39f6dc1-3fc2-4f63-afae-110dde67da39'::uuid, array['3614f7c5-75e9-482c-a759-d4702984242d']::uuid[], 'Pineapple Juice 3L <- MEP 3L PINEAPPLE FRESH JUICE 3 LT');

-- 1. Carry each venue's price, vendor-item map and line map to the survivor where it has none.
insert into public.kount_venue_cost_overrides (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select distinct on (o.venue_id, p.winner)
       o.venue_id, p.winner, o.cost_per_unit,
       coalesce(o.source, '') || ' | moved from duplicate on merge 2026-10-26', o.set_by, o.is_manual, o.price_date, now()
  from _plan p
  join public.kount_venue_cost_overrides o on o.master_item_id = any (p.losers)
 where o.cost_per_unit > 0
   and not exists (select 1 from public.kount_venue_cost_overrides w where w.venue_id = o.venue_id and w.master_item_id = p.winner)
 order by o.venue_id, p.winner, o.price_date desc nulls last, o.updated_at desc
on conflict do nothing;

update public.kount_invoice_item_map x set master_item_id = p.winner, updated_at = now()
  from _plan p
 where x.master_item_id = any (p.losers)
   and not exists (select 1 from public.kount_invoice_item_map y
                    where y.venue_id = x.venue_id and y.purchase_item_id = x.purchase_item_id and y.master_item_id = p.winner);

update public.kount_invoice_line_map x set master_item_id = p.winner, updated_at = now()
  from _plan p
 where x.master_item_id = any (p.losers)
   and not exists (select 1 from public.kount_invoice_line_map y
                    where y.venue_id = x.venue_id and y.invoice_line_id = x.invoice_line_id and y.master_item_id = p.winner);

-- 2. The merges.
select p.label, public.merge_master_items(p.winner, p.losers, false)::text as result from _plan p;
commit;
