-- =============================================================================
--  0024_kount_carried_cleanup
--
--  Two cleanups against kount_carried_items now that master_item_id is
--  backfilled:
--
--  1. Scope filter — delete carried rows whose master is in an out-of-scope
--     category (food/produce/dairy/etc.). The Counting-App is bar-only;
--     keeping food rows means the catalog browser and the phone's catalog
--     dropdown have to filter them out everywhere. Easier to drop them at
--     the source.
--
--  2. Dedupe by master — kount_carried_items was built around purchase_item_id
--     so a master with two purchase_item variants (e.g. 750ml-via-vendor-A
--     and 750ml-via-vendor-B as separate procurement SKUs) ended up as TWO
--     carried rows. After master consolidation those collapse to one row.
--     Keep the earliest row by added_at, drop the rest.
--
--  Both operations are recoverable from purchase_items + master_items, so
--  no archive table needed — the source of truth lives in the catalog
--  tables themselves.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Drop out-of-scope carried items
-- -----------------------------------------------------------------------------
-- IN-SCOPE = bar/bev/liquor/wine/beer + their case-variant labels.
-- Anything else (food, produce, supplies, services) gets dropped here.

delete from public.kount_carried_items kci
 using public.master_items mi
 where mi.id = kci.master_item_id
   and mi.category not in (
     'Wine Cost', 'wine', 'Wine',
     'Liquor Cost', 'liquor', 'Liquor',
     'Beer Cost', 'beer',
     'N/A Beverage Cost', 'non_alcoholic_beverage',
     'Bar Consumables', 'bar_consumable',
     'Bar Supplies'
   );

-- -----------------------------------------------------------------------------
-- 2. Dedupe carried rows by master_item_id
-- -----------------------------------------------------------------------------
-- For each master that appears in 2+ rows, keep the earliest by added_at and
-- drop the rest. Composite ordering on (added_at, ctid) makes the keep choice
-- deterministic when timestamps are equal.

with ranked as (
  select ctid,
         master_item_id,
         row_number() over (
           partition by master_item_id
           order by added_at asc, ctid asc
         ) as rn
    from public.kount_carried_items
   where master_item_id is not null
)
delete from public.kount_carried_items kci
 using ranked
 where kci.ctid = ranked.ctid
   and ranked.rn > 1;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
--   select count(*) as total,
--          count(distinct master_item_id) as distinct_masters,
--          count(*) filter (where master_item_id is null) as null_master
--     from public.kount_carried_items;
--
--   Expected after migration:
--     total ~= distinct_masters (no duplicates)
--     null_master = 0 (1,776 inactive-master rows preserved with their FK)
--
--   By-category breakdown (should be only the 6 in-scope category groups):
--     select mi.category, count(*) as carried_rows
--       from public.kount_carried_items kci
--       join public.master_items mi on mi.id = kci.master_item_id
--      group by mi.category
--      order by carried_rows desc;
