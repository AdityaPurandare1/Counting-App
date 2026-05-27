-- =============================================================================
--  0029_kount_recounts_master_id
--
--  Adds master_item_id to kount_recounts and backfills it from the existing
--  item_id (a nullable purchase_items.id reference). This is the recounts
--  half of the master_items consolidation, mirroring 0025 for kount_entries:
--
--    kount_recounts.item_id          → unchanged (back-compat read path)
--    kount_recounts.master_item_id   → new (forward read path)
--
--  Going forward, phone + admin code write master_item_id on new recount rows
--  wherever a known master id is available on the source data, while item_id
--  stays for back-compat. When the rewrite is fully deployed and stable, a
--  future migration drops item_id.
--
--  NOTE: unlike kount_entries, many recount rows are AVT/name-derived (built
--  from variance analysis or matched only by item_name, with no purchase_item
--  link). Those rows legitimately have NO master_item_id and will remain
--  master_item_id = NULL after this backfill — that is expected, not an orphan.
--  Only recount rows derived from counted entries (which carry a master id)
--  are expected to populate.
-- =============================================================================

alter table public.kount_recounts
  add column if not exists master_item_id uuid references public.master_items(id) on delete set null;

create index if not exists kount_recounts_master_id_idx
  on public.kount_recounts(master_item_id) where master_item_id is not null;

-- Backfill from purchase_items.master_item_id. kount_recounts.item_id is the
-- existing reference (a purchase_items.id stored as uuid); we cast as text on
-- both sides and join through purchase_items to land the master id. Rows with
-- item_id = NULL (AVT/name-derived recounts) are skipped and stay NULL.
update public.kount_recounts kr
   set master_item_id = pi.master_item_id
  from public.purchase_items pi
 where pi.id::text = kr.item_id::text
   and kr.master_item_id is null
   and pi.master_item_id is not null;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
--
--   select count(*) as total,
--          count(item_id) as with_legacy_item_id,
--          count(master_item_id) as with_master_id,
--          count(*) filter (where item_id is not null and master_item_id is null) as orphaned,
--          count(*) filter (where item_id is null) as avt_or_name_derived
--     from public.kount_recounts;
--
--   Expected: orphaned ~ 0 (every item_id that resolves to a purchase_item with
--   a master backfills); avt_or_name_derived rows keep master_item_id = NULL.
