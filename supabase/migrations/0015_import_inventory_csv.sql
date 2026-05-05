-- =============================================================================
--  0015_import_inventory_csv
--
--  RPC for the admin "Upload Inventory" CSV flow. Two reasons it's a server-
--  side function rather than client-side bulk upserts:
--    1. purchase_items has anon SELECT only — anon clients cannot INSERT or
--       UPDATE the master catalog directly. We need SECURITY DEFINER to
--       enrich the master from a venue's uploaded inventory.
--    2. The "replace mode" delete-then-add semantics need a transactional
--       window across two tables (purchase_items + kount_carried_items),
--       which a single RPC gives us cheaply.
--
--  Inputs:
--    p_items   jsonb array of {name, brand?, size?, upc?, category?, sku?}.
--              name is required; everything else is optional.
--    p_replace if true, AFTER processing the CSV, any kount_carried_items
--              row whose purchase_item_id is NOT represented in the CSV
--              is deleted (the CSV becomes the source of truth for the
--              carried set). Default false → merge (additive only).
--    p_actor_email / p_actor_name — for audit columns on
--              kount_carried_items.
--
--  Output: jsonb summary
--    {
--      inserted_master: int,   -- new purchase_items rows added
--      updated_master:  int,   -- existing purchase_items rows enriched
--      added_carried:   int,   -- new rows in kount_carried_items
--      removed_carried: int,   -- rows deleted in p_replace=true mode
--      skipped:         int    -- rows where name was missing
--    }
-- =============================================================================

create or replace function public.import_inventory_csv(
  p_items        jsonb,
  p_replace      boolean default false,
  p_actor_email  text default 'admin@hwoodgroup.com',
  p_actor_name   text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted_master  int := 0;
  v_updated_master   int := 0;
  v_added_carried    int := 0;
  v_removed_carried  int := 0;
  v_skipped          int := 0;
  v_item             jsonb;
  v_pid              uuid;
  v_existing_id      uuid;
  v_csv_pids         uuid[] := '{}';
  v_inserted_carry   boolean;
  v_name             text;
  v_upc              text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a jsonb array';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_name := nullif(trim(v_item->>'name'), '');
    if v_name is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_upc := nullif(trim(v_item->>'upc'), '');
    v_existing_id := null;

    -- Match priority: UPC first (definitive), then case-insensitive name.
    if v_upc is not null then
      select id into v_existing_id
        from public.purchase_items
       where upc = v_upc
       limit 1;
    end if;
    if v_existing_id is null then
      select id into v_existing_id
        from public.purchase_items
       where lower(name) = lower(v_name)
       limit 1;
    end if;

    if v_existing_id is not null then
      -- Existing master row — enrich with any non-empty CSV fields. We
      -- COALESCE so a blank CSV cell never wipes an existing value.
      update public.purchase_items
         set name        = coalesce(nullif(trim(v_item->>'name'),     ''), name),
             brand       = coalesce(nullif(trim(v_item->>'brand'),    ''), brand),
             size        = coalesce(nullif(trim(v_item->>'size'),     ''), size),
             upc         = coalesce(nullif(trim(v_item->>'upc'),      ''), upc),
             category    = coalesce(nullif(trim(v_item->>'category'), ''), category),
             sku         = coalesce(nullif(trim(v_item->>'sku'),      ''), sku)
       where id = v_existing_id;
      v_pid := v_existing_id;
      v_updated_master := v_updated_master + 1;
    else
      -- New master row. Only `name` is guaranteed; the rest may be null.
      insert into public.purchase_items (name, brand, size, upc, category, sku, is_active)
      values (
        v_name,
        nullif(trim(v_item->>'brand'),    ''),
        nullif(trim(v_item->>'size'),     ''),
        v_upc,
        nullif(trim(v_item->>'category'), ''),
        nullif(trim(v_item->>'sku'),      '')
      )
      returning id into v_pid;
      v_inserted_master := v_inserted_master + 1;
    end if;

    v_csv_pids := array_append(v_csv_pids, v_pid);

    -- Mark carried. ON CONFLICT skips already-carried rows so the upload
    -- is idempotent — re-uploading the same CSV doesn't bump audit times
    -- on rows that were already carried.
    v_inserted_carry := false;
    insert into public.kount_carried_items (
      purchase_item_id, added_by_email, added_by_name, notes
    )
    values (v_pid, p_actor_email, p_actor_name, 'imported via CSV')
    on conflict (purchase_item_id) do nothing
    returning true into v_inserted_carry;
    if v_inserted_carry then
      v_added_carried := v_added_carried + 1;
    end if;
  end loop;

  -- Replace mode: anything currently carried but NOT in this CSV gets
  -- removed. Skipped if the CSV was empty (defensive — accidentally
  -- uploading an empty CSV in replace mode shouldn't wipe everything).
  if p_replace and array_length(v_csv_pids, 1) > 0 then
    with deleted as (
      delete from public.kount_carried_items
       where not (purchase_item_id = any(v_csv_pids))
       returning 1
    )
    select count(*) into v_removed_carried from deleted;
  end if;

  return jsonb_build_object(
    'inserted_master', v_inserted_master,
    'updated_master',  v_updated_master,
    'added_carried',   v_added_carried,
    'removed_carried', v_removed_carried,
    'skipped',         v_skipped
  );
end;
$$;

-- Allow the anon role to call the RPC. The function itself is SECURITY
-- DEFINER and runs with elevated privileges, which is what enables it
-- to mutate purchase_items.
grant execute on function public.import_inventory_csv(jsonb, boolean, text, text) to anon, authenticated;
