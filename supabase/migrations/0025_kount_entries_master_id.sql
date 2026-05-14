-- =============================================================================
--  0025_kount_entries_master_id
--
--  Adds master_item_id to kount_entries and backfills it from the existing
--  item_id (currently a purchase_items.id reference). This is the entries
--  half of the master_items consolidation:
--
--    kount_entries.item_id          → unchanged (back-compat read path)
--    kount_entries.master_item_id   → new (forward read path)
--
--  Going forward, phone + admin code write BOTH columns on new entries so
--  any legacy reader keeps working. When the rewrite is fully deployed
--  and stable, a future migration drops item_id.
--
--  All 62 existing entries with item_id translate cleanly to master_item_id
--  via purchase_items.master_item_id (verified pre-migration: 0 collisions
--  on the unique constraint (audit_id, zone, lower(item_name), is_recount)).
-- =============================================================================

alter table public.kount_entries
  add column if not exists master_item_id uuid references public.master_items(id) on delete set null;

create index if not exists kount_entries_master_id_idx
  on public.kount_entries(master_item_id) where master_item_id is not null;

-- Backfill from purchase_items.master_item_id. kount_entries.item_id is the
-- existing reference (currently a purchase_items.id stored as text or uuid);
-- we cast as needed and join through purchase_items to land the master id.
update public.kount_entries ke
   set master_item_id = pi.master_item_id
  from public.purchase_items pi
 where pi.id::text = ke.item_id::text
   and ke.master_item_id is null
   and pi.master_item_id is not null;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
--
--   select count(*) as total,
--          count(item_id) as with_legacy_item_id,
--          count(master_item_id) as with_master_id,
--          count(*) filter (where item_id is not null and master_item_id is null) as orphaned
--     from public.kount_entries;
--
--   Expected: with_master_id = with_legacy_item_id (no orphans)
