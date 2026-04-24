-- =============================================================================
--  kΩunt — kount_carried_items: admin-curated subset of purchase_items (0007)
--  Target: PostgreSQL (Supabase). Idempotent.
-- =============================================================================
--
--  Problem: purchase_items is the full Bevager export (~4,600 rows) and
--  contains multiple variants of the same product. Scanning / searching
--  'Campari' surfaces 10 rows when the group actually stocks 2 (1L and
--  750 ml). Counters end up tapping the wrong row, so UPC writes end up
--  on the wrong catalog entry and variance math gets noisy.
--
--  Fix: a thin table that names exactly which purchase_items rows are
--  actively carried. Corporate admin curates it from the desktop
--  /catalog screen (v0.13). The phone and the desktop search paths
--  prefer this set when it's populated.
--
--  NOT venue-scoped in v0.13 — one global carried list for the group.
--  Per-venue scoping can arrive later by adding a venue_id column.
-- =============================================================================

create table if not exists public.kount_carried_items (
  purchase_item_id uuid         primary key references public.purchase_items(id) on delete cascade,
  added_by_email   text         not null,
  added_by_name    text,
  added_at         timestamptz  not null default now(),
  notes            text
);

create index if not exists kount_carried_items_added_idx on public.kount_carried_items (added_at desc);


-- Realtime so both apps see carried-list edits live.
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then return; end if;
  begin execute 'alter publication supabase_realtime add table public.kount_carried_items'; exception when duplicate_object then null; end;
end $$;


-- Permissive-dev RLS (consistent with every other kount_* table).
alter table public.kount_carried_items enable row level security;

drop policy if exists "dev_kount_carried_items_select" on public.kount_carried_items;
create policy "dev_kount_carried_items_select" on public.kount_carried_items for select to anon using (true);

drop policy if exists "dev_kount_carried_items_insert" on public.kount_carried_items;
create policy "dev_kount_carried_items_insert" on public.kount_carried_items for insert to anon with check (true);

drop policy if exists "dev_kount_carried_items_delete" on public.kount_carried_items;
create policy "dev_kount_carried_items_delete" on public.kount_carried_items for delete to anon using (true);


-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
-- select count(*) as total_catalog,
--        (select count(*) from public.kount_carried_items) as carried
--   from public.purchase_items;

-- Admin starts empty. Phone shows the full catalog when carried is 0, and
-- narrows to the carried subset once admin begins curating.
