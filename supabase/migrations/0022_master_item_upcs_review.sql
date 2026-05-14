-- =============================================================================
--  0022_master_item_upcs_review
--
--  A holding table for UPCs that came in via the purchase_items.upc backfill
--  but couldn't be unambiguously attached to one master. Each row captures
--  the UPC, all candidate masters it was tagged onto in purchase_items, and
--  any external-lookup metadata we managed to fetch (UPCitemDB / Open Food
--  Facts product info).
--
--  Flow:
--    1. 0020 backfilled all UPC values into master_item_upcs, picking the
--       earliest-by-created_at master for any UPC with collisions.
--    2. 0022 (this) + the accompanying resolution script will move the
--       collision cases OUT of master_item_upcs and INTO this review table.
--    3. master_item_upcs ends up containing only unambiguous UPC mappings.
--    4. Admin UI surfaces the review table so a human can manually link the
--       leftover UPCs to the correct size variant (or mark them as "this UPC
--       doesn't belong to any local master").
-- =============================================================================

create extension if not exists pgcrypto;

create table if not exists public.master_item_upcs_review (
  id                uuid primary key default gen_random_uuid(),

  upc_raw           text not null,
  upc_normalized    text not null,

  -- All masters this UPC was tagged onto in purchase_items at backfill time.
  -- Stored as JSON so we can include each candidate's name/base_size/base_unit
  -- without needing a separate child table.
  candidate_masters jsonb not null,

  -- External-lookup data, if any. null when neither API knew the UPC.
  lookup_title      text,
  lookup_brand      text,
  lookup_size_text  text,
  lookup_size_ml    numeric,
  lookup_source     text,                -- 'upcitemdb' | 'openfoodfacts' | etc.

  -- Why this UPC ended up in review (vs. resolved):
  --   'not_found'           — neither API knew it
  --   'no_size'             — API found it but didn't return a parseable size
  --   'size_no_match'       — API size doesn't match any candidate's base_size
  --   'multiple_size_match' — API size matched 2+ candidates (e.g. duplicate masters at same size)
  --   'no_candidates'       — pathological: backfill row has no candidates
  reason            text not null,

  -- Admin disposition. Default null = needs review.
  resolved_master_id uuid references public.master_items(id) on delete set null,
  resolved_at        timestamptz,
  resolved_by_email  text,
  resolved_notes     text,

  added_at          timestamptz not null default now()
);

create unique index if not exists master_item_upcs_review_normalized_uniq
  on public.master_item_upcs_review(upc_normalized);
create index if not exists master_item_upcs_review_unresolved_idx
  on public.master_item_upcs_review(resolved_master_id) where resolved_master_id is null;

-- Permissive-dev RLS (matches every other kount_* / catalog table)
alter table public.master_item_upcs_review enable row level security;

drop policy if exists "dev_master_item_upcs_review_select" on public.master_item_upcs_review;
create policy "dev_master_item_upcs_review_select"
  on public.master_item_upcs_review for select to anon using (true);

drop policy if exists "dev_master_item_upcs_review_insert" on public.master_item_upcs_review;
create policy "dev_master_item_upcs_review_insert"
  on public.master_item_upcs_review for insert to anon with check (true);

drop policy if exists "dev_master_item_upcs_review_update" on public.master_item_upcs_review;
create policy "dev_master_item_upcs_review_update"
  on public.master_item_upcs_review for update to anon using (true) with check (true);

drop policy if exists "dev_master_item_upcs_review_delete" on public.master_item_upcs_review;
create policy "dev_master_item_upcs_review_delete"
  on public.master_item_upcs_review for delete to anon using (true);

comment on table public.master_item_upcs_review is 'UPCs from purchase_items.upc backfill that couldnt be unambiguously attached to one master. Admin reconciles via the Approvals screen.';
