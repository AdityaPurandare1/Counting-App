-- =============================================================================
--  0033_carried_items_master_key
--
--  Re-keys kount_carried_items for Path B (master_items as the canonical
--  catalog). This is the missing migration that admin client commit f6d625a
--  assumed already existed:
--
--    - The admin Catalog toggle inserts {master_item_id, added_by_email,
--      added_by_name} WITHOUT purchase_item_id → fails 23502 (not-null
--      violation) because purchase_item_id has been the NOT NULL PRIMARY KEY
--      since 0007.
--    - The admin Bevager import upserts with onConflict: 'master_item_id'
--      → fails 42P10 (no unique constraint matches the ON CONFLICT
--      specification) because 0023 only added a partial NON-unique index.
--
--  Changes:
--    1. Add a surrogate `id uuid` and make IT the primary key.
--    2. Make purchase_item_id nullable, but keep a PLAIN unique index on it.
--       Plain (non-partial) unique allows multiple NULLs while still serving
--       as the arbiter for any legacy `on conflict (purchase_item_id)`.
--    3. Defensively re-dedupe by master_item_id (0024 already deduped, but
--       prod may have drifted since), keeping the NEWEST row per master.
--    4. Add a PLAIN unique index on master_item_id so PostgREST
--       `onConflict: 'master_item_id'` resolves. Multiple NULLs remain fine
--       for legacy purchase-only rows.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
--
--  Idempotent: re-running skips the PK swap (already on id), the column adds,
--  and the index creates; the dedupe delete finds nothing to delete.
-- =============================================================================

begin;

-- 1) Surrogate key column. Default backfills every existing row.
alter table public.kount_carried_items
  add column if not exists id uuid not null default gen_random_uuid();

-- 2) Swap the primary key: purchase_item_id → id.
--    Dynamic lookup of the PK name (don't assume kount_carried_items_pkey);
--    only drop it if it is still the single-column PK on purchase_item_id,
--    so a re-run (PK already on id) is a no-op.
do $$
declare
  v_pk_name text;
  v_pk_cols text[];
begin
  select c.conname,
         array_agg(a.attname order by k.ord)
    into v_pk_name, v_pk_cols
    from pg_constraint c
    cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum   = k.attnum
   where c.conrelid = 'public.kount_carried_items'::regclass
     and c.contype  = 'p'
   group by c.conname;

  if v_pk_name is not null and v_pk_cols = array['purchase_item_id'] then
    -- %I = constraint name (the only positional arg here).
    execute format('alter table public.kount_carried_items drop constraint %I', v_pk_name);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.kount_carried_items'::regclass
       and contype  = 'p'
  ) then
    execute 'alter table public.kount_carried_items add constraint kount_carried_items_pkey primary key (id)';
  end if;
end $$;

-- 3) purchase_item_id becomes optional (master-curated rows won't have one).
--    DROP NOT NULL is a no-op if the column is already nullable.
--    The FK to purchase_items (on delete cascade, from 0007) is unchanged.
alter table public.kount_carried_items
  alter column purchase_item_id drop not null;

-- Plain unique index replaces the uniqueness the old PK provided. Plain
-- (not partial) unique indexes allow any number of NULLs, and remain a
-- valid arbiter for `on conflict (purchase_item_id)` (0015/0017 import RPC).
create unique index if not exists kount_carried_items_purchase_item_uniq
  on public.kount_carried_items (purchase_item_id);

-- 4) Defensive pre-dedupe by master before the unique index: 0024 already
--    collapsed duplicates, but if prod drifted since, the CREATE UNIQUE
--    INDEX below would abort the whole transaction. Keep the NEWEST row
--    per master (most recent admin action wins); ctid breaks timestamp ties
--    deterministically.
with ranked as (
  select ctid,
         row_number() over (
           partition by master_item_id
           order by added_at desc, ctid desc
         ) as rn
    from public.kount_carried_items
   where master_item_id is not null
)
delete from public.kount_carried_items kci
 using ranked
 where kci.ctid = ranked.ctid
   and ranked.rn > 1;

-- Unique master key — the arbiter for PostgREST `onConflict: 'master_item_id'`.
-- Must be plain (non-partial): PostgREST/PostgreSQL won't pick a partial
-- index as an ON CONFLICT arbiter without an explicit WHERE clause the
-- client doesn't send. Multiple NULLs (legacy purchase-only rows) are fine.
create unique index if not exists kount_carried_items_master_item_uniq
  on public.kount_carried_items (master_item_id);

-- The 0023 partial non-unique index is now redundant (the unique index
-- above covers the same lookups).
drop index if exists public.kount_carried_items_master_id_idx;

commit;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
-- 1. PK is now on id:
--      select conname, pg_get_constraintdef(oid)
--        from pg_constraint
--       where conrelid = 'public.kount_carried_items'::regclass and contype = 'p';
--    Expect: kount_carried_items_pkey PRIMARY KEY (id)
--
-- 2. Both unique indexes exist:
--      select indexname, indexdef from pg_indexes
--       where tablename = 'kount_carried_items';
--
-- 3. Admin Catalog toggle smoke test (as corporate user):
--      insert a row with only master_item_id + added_by_* → succeeds;
--      repeat with onConflict master_item_id → upserts, no 42P10.
