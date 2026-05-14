-- =============================================================================
--  0020_master_item_upcs
--
--  Introduces master_item_upcs — a many-UPCs-per-master mapping table that
--  replaces the single purchase_items.upc column as the source of truth for
--  barcode -> item resolution in the Counting-App.
--
--  Background:
--  -----------
--  Up to v1.44 the phone scanned a barcode, looked it up in upc_mappings
--  (and via the cached purchase_items.upc), and resolved to a purchase_item.
--  Two problems:
--    1. purchase_items has 26,878 active rows because each procurement
--       variant (vendor SKU, packaging unit, cost-tier) is its own row,
--       even though most map to the same canonical product. Search and
--       fuzzy-match had too many near-duplicate candidates.
--    2. purchase_items.upc is a single text column. A bottle that legitimately
--       carries multiple barcodes (front label EAN-13, back label UPC, outer
--       multipack barcode) could only register one of them per row.
--
--  After:
--  ------
--  Counting resolves at the master_items level (~12k active masters; ~8.2k
--  in-scope for bar/bev/liquor/wine). Multiple UPCs can attach to the same
--  master via master_item_upcs rows. A given UPC value resolves to at most
--  one master (unique constraint).
--
--  This migration only adds the table and backfills it. Subsequent migrations
--  (0021..0024) shift the kount_* tables and RPCs to read master_item_id.
--  Until then, old code paths keep working unchanged because purchase_items
--  and purchase_items.upc are not modified.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Table
-- -----------------------------------------------------------------------------
create table if not exists public.master_item_upcs (
  id              uuid primary key default gen_random_uuid(),
  master_item_id  uuid not null references public.master_items(id) on delete cascade,

  -- upc_raw: as scanned / imported, preserves leading zeros and formatting.
  --   Used for display ("the barcode label said X").
  -- upc_normalized: digits only, leading zeros stripped. Used for lookup.
  --   A scan of '012345678905' resolves to the same master as a scan of
  --   '12345678905' because both normalize to '12345678905'.
  upc_raw         text not null,
  upc_normalized  text not null,

  -- Provenance — useful for admin review and for distinguishing trusted
  -- (manual) from inferred (backfill) entries when investigating bad data.
  source          text not null default 'manual',
  notes           text,

  added_by_email  text,
  added_at        timestamptz not null default now(),

  constraint master_item_upcs_normalized_nonempty check (upc_normalized <> '')
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

-- A given barcode resolves to exactly one master_item. Phone scan -> lookup
-- by upc_normalized -> exactly one result.
create unique index if not exists master_item_upcs_normalized_uniq
  on public.master_item_upcs(upc_normalized);

-- Reverse lookup — "which UPCs does this master have?" — used by the admin
-- screen when reviewing/editing a master's barcodes.
create index if not exists master_item_upcs_master_idx
  on public.master_item_upcs(master_item_id);

-- -----------------------------------------------------------------------------
-- Backfill from purchase_items.upc
-- -----------------------------------------------------------------------------
-- Every existing purchase_items row with a non-empty UPC contributes one
-- master_item_upcs row. If two purchase_items share the same normalized UPC
-- (rare but possible — e.g. two procurement SKUs of the same bottle), we keep
-- the OLDEST one by created_at. ON CONFLICT DO NOTHING makes the migration
-- idempotent: re-running it adds no duplicate rows.
insert into public.master_item_upcs
  (master_item_id, upc_raw, upc_normalized, source, notes, added_at)
select distinct on (
    regexp_replace(regexp_replace(trim(pi.upc), '[^0-9]', '', 'g'), '^0+', '')
  )
  pi.master_item_id,
  trim(pi.upc) as upc_raw,
  regexp_replace(regexp_replace(trim(pi.upc), '[^0-9]', '', 'g'), '^0+', '') as upc_normalized,
  'purchase_items_backfill' as source,
  'Imported from purchase_items.upc during master_item consolidation' as notes,
  coalesce(pi.created_at, now()) as added_at
from public.purchase_items pi
where pi.upc is not null
  and trim(pi.upc) <> ''
  and pi.master_item_id is not null
  -- Skip rows whose UPC has zero digit characters after normalization
  -- (rare — happens when the upc column has letters/symbols only).
  and regexp_replace(regexp_replace(trim(pi.upc), '[^0-9]', '', 'g'), '^0+', '') <> ''
order by
  regexp_replace(regexp_replace(trim(pi.upc), '[^0-9]', '', 'g'), '^0+', ''),
  pi.created_at asc
on conflict (upc_normalized) do nothing;

-- -----------------------------------------------------------------------------
-- RLS — permissive-dev (consistent with every other kount_* / catalog table)
-- -----------------------------------------------------------------------------
-- Phase 5 will tighten this to "authenticated users with appropriate role"
-- via the same flip planned for kount_audits + kount_entries. Until then,
-- anon CRUD keeps existing client code working unchanged.

alter table public.master_item_upcs enable row level security;

drop policy if exists "dev_master_item_upcs_select" on public.master_item_upcs;
create policy "dev_master_item_upcs_select"
  on public.master_item_upcs for select to anon using (true);

drop policy if exists "dev_master_item_upcs_insert" on public.master_item_upcs;
create policy "dev_master_item_upcs_insert"
  on public.master_item_upcs for insert to anon with check (true);

drop policy if exists "dev_master_item_upcs_update" on public.master_item_upcs;
create policy "dev_master_item_upcs_update"
  on public.master_item_upcs for update to anon using (true) with check (true);

drop policy if exists "dev_master_item_upcs_delete" on public.master_item_upcs;
create policy "dev_master_item_upcs_delete"
  on public.master_item_upcs for delete to anon using (true);

-- -----------------------------------------------------------------------------
-- Documentation
-- -----------------------------------------------------------------------------
-- COMMENT ON ... IS expects a single string literal, not an expression —
-- concatenation operators (||) are rejected by the parser there. Long
-- comments stay on one logical line.
comment on table public.master_item_upcs is 'Maps barcodes to canonical master_items. One master can have many UPCs (multiple labels, regional variants, multipack outers). Each UPC resolves to at most one master (unique index on upc_normalized).';

comment on column public.master_item_upcs.upc_raw is 'Barcode as scanned/imported, preserves leading zeros and formatting. Display only — do not key off this for lookups.';
comment on column public.master_item_upcs.upc_normalized is 'Digits only, leading zeros stripped. Use this for scan lookups so that 012345678905 and 12345678905 collapse to the same master.';
comment on column public.master_item_upcs.source is 'Provenance: ''manual'' (admin entered), ''scan'' (phone-approved), ''purchase_items_backfill'' (migration 0020), or other tagged import.';

-- -----------------------------------------------------------------------------
-- Verification (run manually after applying)
-- -----------------------------------------------------------------------------
--
-- 1. Row counts:
--      select count(*) as total_upcs,
--             count(distinct master_item_id) as distinct_masters
--        from public.master_item_upcs;
--    Expected (based on 2026-05-14 snapshot of purchase_items.upc):
--      total_upcs ~ 1,326
--      distinct_masters ~ 776
--    Drift from those numbers means purchase_items.upc has grown/shrunk
--    since the migration was designed — not a problem, just FYI.
--
-- 2. Spot-check a known retail bottle:
--      select mi.name, miu.upc_raw, miu.upc_normalized
--        from public.master_item_upcs miu
--        join public.master_items mi on mi.id = miu.master_item_id
--       where miu.upc_normalized = regexp_replace(regexp_replace('<known UPC>', '[^0-9]', '', 'g'), '^0+', '')
--       limit 5;
--
-- 3. No duplicate normalized UPCs:
--      select upc_normalized, count(*)
--        from public.master_item_upcs
--       group by upc_normalized having count(*) > 1;
--    Should return zero rows (unique index would have prevented it).
