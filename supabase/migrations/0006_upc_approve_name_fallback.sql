-- =============================================================================
--  kΩunt — approve_upc_mapping name-fallback + one-time backfill (0006)
--  Target: PostgreSQL (Supabase). Idempotent.
-- =============================================================================
--
--  Context: migration 0005 made approve_upc_mapping() work end-to-end, but
--  only COPY the barcode onto purchase_items.upc when the pending row
--  carried a non-null purchase_item_id. Most counter submissions come in
--  with purchase_item_id=null because the phone's scanning flow creates a
--  'custom item' for anything it can't exact-match against the catalog.
--  Net effect: approvals succeed but purchase_items stays empty, so the
--  next scan of the same bottle doesn't match.
--
--  This migration:
--    1. Replaces approve_upc_mapping with a version that, when
--       purchase_item_id is null, tries a best-effort lookup against
--       public.purchase_items by case-insensitive exact name match. It
--       only updates when exactly ONE candidate row has a blank upc, so
--       we never touch the wrong item or overwrite a prior UPC.
--    2. Back-fills every upc_mappings row that is currently approved
--       using the same rules, so the five rows already approved today
--       get their barcode copied into purchase_items.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. approve_upc_mapping — now with a name-fallback match.
-- -----------------------------------------------------------------------------
create or replace function public.approve_upc_mapping(
  p_mapping_id  uuid,
  p_admin_email text,
  p_admin_name  text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec          public.upc_mappings;
  match_count  int;
  matched_id   uuid;
  matched_by   text := 'none';
begin
  update public.upc_mappings
     set status = 'approved',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id = p_mapping_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mapping not found or already finalized');
  end if;

  -- Preferred: use the explicit link
  if rec.purchase_item_id is not null then
    update public.purchase_items
       set upc = rec.barcode_raw
     where id = rec.purchase_item_id
       and (upc is null or upc = '' or upc is distinct from rec.barcode_raw);
    matched_by := 'purchase_item_id';
    matched_id := rec.purchase_item_id;
  else
    -- Best-effort: exact-name match when there's exactly one candidate
    -- whose upc slot is blank. Don't overwrite a different UPC silently.
    select count(*), max(id) into match_count, matched_id
      from public.purchase_items
     where lower(name) = lower(rec.item_name)
       and (upc is null or upc = '');

    if match_count = 1 then
      update public.purchase_items
         set upc = rec.barcode_raw
       where id = matched_id;
      matched_by := 'name';
    elsif match_count > 1 then
      matched_by := 'ambiguous-name';      -- admin needs to fix manually
    else
      matched_by := 'no-match';            -- item not in catalog
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', rec.id,
    'matched_by', matched_by,
    'purchase_item_id', matched_id
  );
end;
$$;

grant execute on function public.approve_upc_mapping(uuid, text, text) to anon;


-- -----------------------------------------------------------------------------
-- 2. Back-fill the existing approved rows using the same rules.
--    Two passes: first the direct-link case, then the unambiguous-name case.
-- -----------------------------------------------------------------------------

-- 2a. Direct link — rows that have purchase_item_id set.
update public.purchase_items pi
   set upc = um.barcode_raw
  from public.upc_mappings um
 where pi.id = um.purchase_item_id
   and um.status = 'approved'
   and (pi.upc is null or pi.upc = '' or pi.upc is distinct from um.barcode_raw);

-- 2b. Name fallback — rows with purchase_item_id IS NULL.
--     Only apply where exactly one purchase_items row with a blank upc
--     matches on lower(name). Multi-match rows are left alone.
with candidates as (
  select um.id as mapping_id, um.barcode_raw, um.item_name
    from public.upc_mappings um
   where um.status = 'approved'
     and um.purchase_item_id is null
),
resolved as (
  select c.mapping_id, c.barcode_raw, pi.id as target_id
    from candidates c
    join public.purchase_items pi
      on lower(pi.name) = lower(c.item_name)
     and (pi.upc is null or pi.upc = '')
   group by c.mapping_id, c.barcode_raw, pi.id
),
unique_resolved as (
  select mapping_id, barcode_raw, target_id
    from resolved r1
   where 1 = (
     select count(*) from resolved r2
      where r2.mapping_id = r1.mapping_id
   )
)
update public.purchase_items pi
   set upc = ur.barcode_raw
  from unique_resolved ur
 where pi.id = ur.target_id;


-- -----------------------------------------------------------------------------
-- 3. VERIFICATION
-- -----------------------------------------------------------------------------
-- How many approved mappings have a matching purchase_items.upc now?
-- select count(*) from public.upc_mappings um
--  where um.status='approved'
--    and exists (select 1 from public.purchase_items pi where pi.upc = um.barcode_raw);

-- Which approved mappings still don't have the barcode on purchase_items?
-- (Usually means the item is not in the catalog, or the name is ambiguous.)
-- select um.id, um.barcode_raw, um.item_name, um.purchase_item_id
--   from public.upc_mappings um
--  where um.status='approved'
--    and not exists (select 1 from public.purchase_items pi where pi.upc = um.barcode_raw);
