-- =============================================================================
--  0081_food_count_import   (SCHEMA + RPC)
--
--  Lets an admin upload a filled food-inventory workbook (the "LITTLE LUCK
--  FOOD INVENTORY" template) and have it land as a real count, with costs.
--
--  WHY THE WRITES LIVE IN AN RPC
--  kount_venue_cost_overrides has a SELECT policy for {authenticated} and NO
--  insert/update policy, so the browser cannot write costs directly. Same
--  reason import_inventory_csv (0034) exists. This function is SECURITY
--  DEFINER and self-authorizes on the caller's JWT, exactly like
--  compute_avt_for_audit and approve_upc_mapping.
--
--  DECISIONS (Aditya, 2026-10-17)
--   * Food is its OWN audit, separate from beverage -> kount_audits.audit_kind.
--     Existing rows and every existing code path default to 'beverage', so
--     bar counting and bar variance are untouched.
--   * The template gains a pack-size ("units per case") column, so a case
--     count can be converted to base units and invoice costs can line up
--     later. 57 of Little Luck's 196 items are counted by the case and
--     NOTHING in the database recorded how many units a case holds.
--
--  UNIT MODEL — the two units are complementary, not competing:
--     sheet "unit"  = how the venue COUNTS it on the shelf (ea / cs / lb)
--     master base_unit/base_size = the PACK SIZE (Maggi Seasoning = 27 oz)
--  So "1 ea" of Maggi is one 27oz bottle. We store the counted quantity in
--  the counting unit the counter actually used, plus that unit and the pack
--  size, rather than silently converting and losing what was counted.
--
--  ROLLBACK: 0081_ROLLBACK_food_count_import.sql
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Audit kind. Default 'beverage' so every existing row and every existing
--    query keeps its current meaning with no backfill.
-- ---------------------------------------------------------------------------
alter table public.kount_audits
  add column if not exists audit_kind text not null default 'beverage';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'kount_audits_audit_kind_chk') then
    alter table public.kount_audits
      add constraint kount_audits_audit_kind_chk check (audit_kind in ('beverage', 'food'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Per-entry counting unit. BOTH NULLABLE -> adding them is instant and the
--    beverage path, which never sets them, is byte-for-byte unaffected.
--    count_unit is captured AT COUNT TIME on purpose: if the venue later
--    changes how it counts an item, historical counts must not be reinterpreted.
-- ---------------------------------------------------------------------------
alter table public.kount_entries
  add column if not exists count_unit text,
  add column if not exists units_per_case numeric;

-- ---------------------------------------------------------------------------
-- 3. The venue's food list: what it carries, how it counts it, pack size.
--    kount_carried_items is GLOBAL (no venue_id), so it cannot answer "what
--    food does THIS venue stock" — hence a venue-scoped table.
-- ---------------------------------------------------------------------------
create table if not exists public.kount_venue_food_items (
  venue_id        text    not null,
  master_item_id  uuid    not null references public.master_items(id) on delete cascade,
  count_unit      text,
  units_per_case  numeric,
  sheet_category  text,
  sort_order      integer,
  updated_at      timestamptz not null default now(),
  primary key (venue_id, master_item_id)
);

alter table public.kount_venue_food_items enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname='public' and tablename='kount_venue_food_items'
       and policyname='kount_venue_food_items_select'
  ) then
    create policy kount_venue_food_items_select
      on public.kount_venue_food_items for select to authenticated
      using (public.kount_can_see_venue(venue_id));
  end if;
end $$;

-- Explicit grant: 0052/0079 lesson — KevaOS migrations have repeatedly revoked
-- implicit privileges on this schema. Writes go through the RPC only.
grant select on public.kount_venue_food_items to authenticated;

commit;

begin;

-- ---------------------------------------------------------------------------
-- 4. kount_import_food_count — preview or commit an uploaded food workbook.
--
--    p_rows: [{ "item","unit","pack","qty","price","sheet","sort" }, ...]
--    p_commit = false (default) -> PREVIEW only, writes nothing.
--
--    Returns a jsonb summary the admin screen renders before committing,
--    mirroring the import_inventory_csv preview-then-commit pattern (0034).
-- ---------------------------------------------------------------------------
create or replace function public.kount_import_food_count(
  p_venue_id        text,
  p_rows            jsonb,
  p_counted_at      timestamptz default now(),
  p_commit          boolean     default false,
  p_create_missing  boolean     default true
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_email        text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_name         text;
  v_venue_name   text;
  v_audit_id     uuid;
  v_created      int := 0;
  v_entries      int := 0;
  v_costs        int := 0;
  v_unmatched    jsonb := '[]'::jsonb;
  v_total_value  numeric := 0;
begin
  -- 0. Authorization. Corporate/admin anywhere; manager only at their venue.
  --    Reads the VERIFIED JWT claim, never a caller-supplied argument.
  select u.name into v_name
    from public.app_users u
   where lower(u.email) = v_email
     and u.is_active = true
     and (
       u.role in ('corporate', 'admin')
       or (u.role = 'manager' and p_venue_id = any(u.venue_ids))
     );
  if not found then
    raise exception 'not authorized to import a food count for %', p_venue_id
      using errcode = '42501';
  end if;

  select kv.name into v_venue_name from public.kount_venues kv where kv.id = p_venue_id;
  if v_venue_name is null then
    raise exception 'unknown kount venue %', p_venue_id using errcode = 'P0002';
  end if;

  -- 1. Clean the sheet rows. Drops blanks and the per-sheet "TOTAL" subtotal
  --    rows (5 of them in the Little Luck workbook) which are not items.
  create temp table _food_rows on commit drop as
  select
    row_number() over ()                                   as rn,
    btrim(r ->> 'item')                                    as item,
    nullif(btrim(lower(coalesce(r ->> 'unit', ''))), '')   as count_unit,
    nullif(r ->> 'pack', '')::numeric                      as units_per_case,
    nullif(r ->> 'qty', '')::numeric                       as qty,
    nullif(r ->> 'price', '')::numeric                     as price,
    nullif(btrim(coalesce(r ->> 'sheet', '')), '')         as sheet,
    nullif(r ->> 'sort', '')::int                          as sort_order
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r
  where btrim(coalesce(r ->> 'item', '')) <> ''
    and upper(btrim(r ->> 'item')) <> 'TOTAL';

  -- 2. Resolve each row to a master by exact (case-insensitive) name.
  --    The catalog holds duplicates (e.g. "Cucumber, Hot House" twice), so the
  --    pick must be deterministic: prefer a row that actually has a base_unit,
  --    then lowest id. NOTE array_agg, not max() — PostgreSQL has no max(uuid)
  --    before 18 and this cluster is 17.6 (that bug is what 0057 fixed).
  create temp table _food_resolved on commit drop as
  select f.*,
         (select (array_agg(m.id order by (not m.is_active), (m.base_unit is null), m.id))[1]
            from public.master_items m
           where lower(m.name) = lower(f.item)) as master_item_id
    from _food_rows f;

  -- 3. Reactivate, then create only what is genuinely absent.
  --    IMPORTANT: all three of Little Luck's "new" items (Garlic Powder,
  --    Heavy Cream 40%, Whole Milk) already existed as INACTIVE masters.
  --    Blindly inserting would have duplicated the catalog -- the same
  --    duplicate-master problem 0047's merge tool exists to clean up -- and
  --    collided with master_items_organization_id_name_category_key. So:
  --    resolve to the existing row (step 2 now accepts inactive) and switch
  --    it back on, because the venue demonstrably stocks it.
  if p_commit then
    update public.master_items m
       set is_active = true
      from _food_resolved f
     where m.id = f.master_item_id
       and m.is_active = false;

    if p_create_missing then
      with ins as (
        insert into public.master_items (name, category, is_active)
        select distinct on (lower(f.item))
               f.item,
               case lower(coalesce(f.sheet, ''))
                 when 'meat_&_seafood' then 'Meat Cost'
                 when 'dairy_&_eggs'   then 'Dairy Cost'
                 when 'produce'        then 'Produce Cost'
                 else                       'Grocery and Dry Goods Cost'
               end,
               true
          from _food_resolved f
         where f.master_item_id is null
         order by lower(f.item)
        on conflict (organization_id, name, category) do update
           set is_active = true
        returning id, name
      )
      update _food_resolved f
         set master_item_id = ins.id
        from ins
       where lower(f.item) = lower(ins.name);
      get diagnostics v_created = row_count;
    end if;
  end if;

  select coalesce(jsonb_agg(distinct f.item), '[]'::jsonb) into v_unmatched
    from _food_resolved f where f.master_item_id is null;

  select coalesce(sum(f.qty * f.price), 0) into v_total_value
    from _food_resolved f where f.qty is not null and f.price is not null;

  -- 4. Commit: one food audit + its entries + venue costs + the food list.
  if p_commit then
    insert into public.kount_audits
      (venue_id, venue_name, status, count_phase, audit_kind, join_code,
       started_by_email, started_by_name, started_at, count1_closed_at, completed_at, notes)
    values
      (p_venue_id, v_venue_name, 'submitted', 'final', 'food',
       'FOOD-' || to_char(p_counted_at, 'MMDD-HH24MI'),
       v_email, coalesce(v_name, v_email), p_counted_at, p_counted_at, p_counted_at,
       'Imported from food inventory workbook by ' || v_email)
    returning id into v_audit_id;

    -- Entries: only rows that were actually counted. The sheet's own unit and
    -- pack size ride along, so a case count stays a case count.
    insert into public.kount_entries
      (audit_id, item_name, master_item_id, category, qty, zone, method,
       counted_by_email, counted_by_name, is_recount, count_unit, units_per_case,
       client_entry_id, timestamp)
    -- method 'manual': kount_entries_method_check allows only
    -- barcode|photo|manual|guided|quick|recount. 'manual' is also honest --
    -- the counter did count by hand onto a sheet. Deliberately NOT widening
    -- that CHECK, because it is shared with the beverage path; provenance is
    -- already carried by audit_kind='food', the FOOD- join code and the
    -- audit's notes.
    select v_audit_id, f.item, f.master_item_id, f.sheet, f.qty,
           coalesce(replace(f.sheet, '_', ' '), 'Food'), 'manual',
           v_email, coalesce(v_name, v_email), false, f.count_unit, f.units_per_case,
           'FOOD-' || v_audit_id::text || '-' || f.rn::text, p_counted_at
      from _food_resolved f
     where f.master_item_id is not null
       and f.qty is not null;
    get diagnostics v_entries = row_count;

    -- Costs. is_manual = false ON PURPOSE: the uploaded price is a SEED, so
    -- kount_refresh_venue_invoice_costs overwrites it once real itemised
    -- invoices arrive — which is the "enter cost once, then auto-pull from
    -- invoices" behaviour that was asked for.
    insert into public.kount_venue_cost_overrides
      (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
    select p_venue_id, f.master_item_id, f.price,
           'food workbook upload ' || to_char(p_counted_at, 'YYYY-MM-DD')
             || ' (' || coalesce(f.count_unit, 'unit') || ')',
           v_email, false, p_counted_at::date, now()
      from _food_resolved f
     where f.master_item_id is not null
       and f.price is not null and f.price > 0
    on conflict (venue_id, master_item_id) do update
       set cost_per_unit = excluded.cost_per_unit,
           source        = excluded.source,
           set_by        = excluded.set_by,
           is_manual     = false,
           price_date    = excluded.price_date,
           updated_at    = now();
    get diagnostics v_costs = row_count;

    -- The venue's food list + how it counts each item (kount_carried_items is
    -- global and cannot hold this).
    insert into public.kount_venue_food_items
      (venue_id, master_item_id, count_unit, units_per_case, sheet_category, sort_order, updated_at)
    select distinct on (f.master_item_id)
           p_venue_id, f.master_item_id, f.count_unit, f.units_per_case, f.sheet, f.sort_order, now()
      from _food_resolved f
     where f.master_item_id is not null
     order by f.master_item_id, f.rn
    on conflict (venue_id, master_item_id) do update
       set count_unit     = excluded.count_unit,
           units_per_case = coalesce(excluded.units_per_case, kount_venue_food_items.units_per_case),
           sheet_category = excluded.sheet_category,
           sort_order     = excluded.sort_order,
           updated_at     = now();
  end if;

  return jsonb_build_object(
    'ok',              true,
    'committed',       p_commit,
    'venue_id',        p_venue_id,
    'venue_name',      v_venue_name,
    'audit_id',        v_audit_id,
    'rows_in_sheet',   (select count(*) from _food_rows),
    'matched',         (select count(*) from _food_resolved where master_item_id is not null),
    'unmatched',       v_unmatched,
    'masters_created', v_created,
    'rows_with_qty',   (select count(*) from _food_resolved where qty is not null),
    'rows_with_price', (select count(*) from _food_resolved where price is not null),
    'entries_written', v_entries,
    'costs_written',   v_costs,
    'total_value',     round(v_total_value, 2)
  );
end;
$function$;

grant execute on function public.kount_import_food_count(text, jsonb, timestamptz, boolean, boolean) to authenticated;

commit;
