-- =============================================================================
--  0084_little_luck_count_gaps   (DATA, not schema)
--
--  Closes the catalog gaps the 2026-10-18 Little Luck count (join LL-038, 210
--  entries) exposed. Five entries were recorded with NO master_item_id, i.e.
--  counted but unattributable -- they would never appear in variance, costing
--  or item history.
--
--  WHAT WAS COUNTED BUT MISSING
--    "Daiyame - Syuzou Japanese Shochu"          barcode  0.80   upc 4951693340408
--    "Mio Sparkling Sake"                        manual   3.00   sku 086395521009
--    "Von Winning - Forster Ungeheuer Riesling 2024 750ml"
--                                                barcode  2.00   upc 0747736547927
--    "Weingut Jager Gruner Veltliner Federspiel Wachau 2024"
--                                                manual   2.00
--    "One summer day"                            manual   7.80   (a cocktail BATCH)
--
--  THE VINTAGE CASE IS THE HEADLINE. The catalog held the Von Winning 2023
--  (loaded in 0082 from the venue's own sheet); the bottle on the shelf was the
--  2024. Because vintage is part of the item NAME, nothing matched and a
--  scanned bottle became an orphan. The 2024 is created here as its own item --
--  a different vintage genuinely is a different product with its own cost --
--  and v2.17 makes SEARCH vintage-tolerant so the counter finds the 2023 row
--  and can see the year, instead of getting an empty result.
--
--  BARCODES. Three of the five carried a code the counter had already scanned
--  or typed. Attaching them to master_item_upcs is the cheapest possible win
--  on "use barcode for maximum speed": next count these scan straight through.
--  Normalised digits-only, leading zeros stripped -- the same rule
--  approve_upc_mapping applies.
--
--  "One summer day" is a pre-batched cocktail counted as 7.8 units, so it is
--  created as a prep item under the existing "(Prep) ... BATCH" convention
--  other venues already use, in Bar Consumables.
--
--  The five existing entries are then RE-LINKED to these masters, so the
--  submitted count stops carrying orphans.
--
--  ROLLBACK: 0084_ROLLBACK_little_luck_count_gaps.sql
-- =============================================================================

begin;

create temp table _gap (entry_name text, master_name text, category text, upc text) on commit drop;
insert into _gap values
  ('Daiyame — Syuzou Japanese Shochu',
   'Daiyame Shochu 750ml',                                   'Liquor Cost', '4951693340408'),
  ('Mio Sparkling Sake',
   'Mio Sparkling Sake 300ml',                               'Wine Cost',   '086395521009'),
  ('Von Winning — Forster Ungeheuer Riesling 2024 750ml',
   'Riesling, Von Winning, Forster Ungeheuer, Pfalz, DE 2024','Wine Cost',   '0747736547927'),
  ('Weingut Jager Gruner Veltliner Federspiel Wachau 2024',
   'Gruner Veltliner, Weingut Jager, Federspiel, Wachau, AT 2024', 'Wine Cost', null),
  ('One summer day',
   '(Prep) One Summers Day BATCH',                           'Bar Consumables', null);

-- 1. Masters. Reuse/reactivate on the name+category unique key rather than
--    duplicating (the 0081 lesson: several "missing" items were really
--    inactive rows).
create temp table _gap_m on commit drop as
with ins as (
  insert into public.master_items (name, category, organization_id, is_active)
  select g.master_name, g.category, '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true
    from _gap g
  on conflict (organization_id, name, category) do update set is_active = true
  returning id, name
)
select i.id as master_item_id, g.*
  from ins i join _gap g on g.master_name = i.name;

-- 2. Barcodes, so these scan next time. upc_normalized is the unique key, so a
--    code already attached elsewhere is left alone rather than stolen.
insert into public.master_item_upcs
  (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
select m.master_item_id, m.upc,
       regexp_replace(regexp_replace(m.upc, '[^0-9]', '', 'g'), '^0+', ''),
       'scan_approved',
       'Captured on the Little Luck 2026-10-18 count (entry had the code but no master)',
       'apurandare@hwoodgroup.com'
  from _gap_m m
 where m.upc is not null
on conflict (upc_normalized) do nothing;

-- 3. Carried, so they surface in search for everyone.
insert into public.kount_carried_items (master_item_id, added_by_email, added_by_name, notes)
select m.master_item_id, 'apurandare@hwoodgroup.com', 'Aditya Purandare',
       'Little Luck 2026-10-18 count gap'
  from _gap_m m
 where not exists (select 1 from public.kount_carried_items c where c.master_item_id = m.master_item_id);

-- 4. Re-link the orphan entries so the submitted count is whole again.
update public.kount_entries e
   set master_item_id = m.master_item_id
  from _gap_m m, public.kount_audits a
 where a.id = e.audit_id
   and a.venue_id = 'v11'
   and e.master_item_id is null
   and e.item_name = m.entry_name;

-- Verification: no orphans left at Little Luck, and the barcodes are attached.
select (select count(*) from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
         where a.venue_id = 'v11' and e.master_item_id is null and e.item_name is not null) orphans_left,
       (select count(*) from _gap_m) masters_ready,
       (select count(*) from _gap_m m join public.master_item_upcs u on u.master_item_id = m.master_item_id) barcodes_attached;

commit;
