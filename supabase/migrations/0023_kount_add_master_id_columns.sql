-- =============================================================================
--  0023_kount_add_master_id_columns
--
--  Adds master_item_id columns to the three count-side tables that
--  currently reference purchase_items.id:
--    - kount_carried_items     (org-wide curated catalog)
--    - upc_mappings            (phone UPC submissions awaiting / approved)
--    - kount_pending_items     (new-item submissions awaiting / approved)
--
--  Backfills each new column from purchase_items.master_item_id so existing
--  rows immediately have a master_item_id wherever the linked purchase_item
--  resolves to one.
--
--  This migration is ADDITIVE only — no existing columns are dropped, no
--  constraints tightened. Old code paths that read purchase_item_id keep
--  working. Subsequent migrations (0024 cleanup, 0026 RPCs) and the
--  client-side rewrite will shift reads/writes to master_item_id.
--
--  Why ON DELETE SET NULL on the FK to master_items:
--    If a master is ever soft-deleted or hard-deleted, we don't want it to
--    cascade-delete every carried/mapped/pending row that referenced it.
--    Better to leave the rows with master_item_id=NULL so the admin can
--    re-link them (or clean them up explicitly).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- kount_carried_items
-- -----------------------------------------------------------------------------
alter table public.kount_carried_items
  add column if not exists master_item_id uuid references public.master_items(id) on delete set null;

create index if not exists kount_carried_items_master_id_idx
  on public.kount_carried_items(master_item_id) where master_item_id is not null;

-- Backfill from purchase_items.master_item_id. Rows whose purchase_item_id
-- doesn't resolve to a master (deleted/inactive purchase_item) end up
-- master_item_id = NULL and will be cleaned up in 0024.
update public.kount_carried_items kci
   set master_item_id = pi.master_item_id
  from public.purchase_items pi
 where pi.id = kci.purchase_item_id
   and kci.master_item_id is null
   and pi.master_item_id is not null;

-- -----------------------------------------------------------------------------
-- upc_mappings
-- -----------------------------------------------------------------------------
alter table public.upc_mappings
  add column if not exists master_item_id uuid references public.master_items(id) on delete set null;

create index if not exists upc_mappings_master_id_idx
  on public.upc_mappings(master_item_id) where master_item_id is not null;

-- Backfill for mappings that already have a linked purchase_item (typically
-- the approved ones; pending mappings often have purchase_item_id=NULL
-- until an admin picks the target).
update public.upc_mappings um
   set master_item_id = pi.master_item_id
  from public.purchase_items pi
 where pi.id = um.purchase_item_id
   and um.master_item_id is null
   and pi.master_item_id is not null;

-- -----------------------------------------------------------------------------
-- kount_pending_items
-- -----------------------------------------------------------------------------
alter table public.kount_pending_items
  add column if not exists master_item_id uuid references public.master_items(id) on delete set null;

create index if not exists kount_pending_items_master_id_idx
  on public.kount_pending_items(master_item_id) where master_item_id is not null;

-- Backfill for already-approved pending items (status='approved' typically
-- has purchase_item_id set; pending/rejected typically don't).
update public.kount_pending_items kpi
   set master_item_id = pi.master_item_id
  from public.purchase_items pi
 where pi.id = kpi.purchase_item_id
   and kpi.master_item_id is null
   and pi.master_item_id is not null;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
-- 1. Backfill coverage per table — what % of rows now have master_item_id:
--      select
--        'kount_carried_items'  as t,
--        count(*) as total,
--        count(master_item_id) as with_master,
--        count(*) filter (where purchase_item_id is null) as no_purchase_id_either,
--        count(*) filter (where purchase_item_id is not null and master_item_id is null) as orphaned
--        from public.kount_carried_items
--      union all
--      select 'upc_mappings', count(*), count(master_item_id),
--        count(*) filter (where purchase_item_id is null),
--        count(*) filter (where purchase_item_id is not null and master_item_id is null)
--        from public.upc_mappings
--      union all
--      select 'kount_pending_items', count(*), count(master_item_id),
--        count(*) filter (where purchase_item_id is null),
--        count(*) filter (where purchase_item_id is not null and master_item_id is null)
--        from public.kount_pending_items;
--    Expected:
--      kount_carried_items: ~8,723 total, ~6,947 with_master (= total minus the 1,776 broken refs)
--      upc_mappings: low row count, most should backfill if approved
--      kount_pending_items: most rows pending so master_item_id null is normal
--
-- 2. Sanity-check the FK is in place:
--      select conname, conrelid::regclass, confrelid::regclass
--        from pg_constraint
--       where conrelid = 'public.kount_carried_items'::regclass and contype = 'f';
