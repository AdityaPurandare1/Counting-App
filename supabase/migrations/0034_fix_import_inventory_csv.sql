-- =============================================================================
--  0034_fix_import_inventory_csv
--
--  Three fixes to import_inventory_csv (defined 0015, locked down 0017).
--  The 0017 corporate-JWT gate and the function signature are preserved.
--
--  1. BUG (broken since 0015): the new-item INSERT into purchase_items names
--     7 target columns (name, brand, size, upc, category, sku, is_active)
--     but supplies only 6 VALUES expressions — every CSV row that needed a
--     brand-new master row failed with 42601/42804. Fixed by supplying
--     is_active = true explicitly.
--
--  2. Path B awareness (0033 re-keyed kount_carried_items on master_item_id):
--     carried writes now resolve master_item_id — first via master_item_upcs
--     on the normalized UPC (0020 semantics: digits only, leading zeros
--     stripped), else a lower(name) match against ACTIVE master_items, else
--     NULL — and write it alongside purchase_item_id. The result jsonb gains
--     `unresolved_master_count` so the admin upload UI can surface how many
--     CSV rows landed carried without a master link.
--
--  3. Replace-mode delete previously removed ANY carried row whose
--     purchase_item_id wasn't in the CSV — including the master-curated rows
--     (purchase_item_id NULL or stale, master_item_id set) that the phone and
--     admin actually read (both clients filter `master_item_id is not null`).
--     A replace-mode CSV upload could therefore silently wipe the live
--     catalog. Now it only deletes rows with master_item_id IS NULL.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
--
--  Idempotent: CREATE OR REPLACE, grants re-applied.
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
  v_inserted_master    int := 0;
  v_updated_master     int := 0;
  v_added_carried      int := 0;
  v_removed_carried    int := 0;
  v_skipped            int := 0;
  v_unresolved_master  int := 0;
  v_item               jsonb;
  v_pid                uuid;
  v_existing_id        uuid;
  v_csv_pids           uuid[] := '{}';
  v_name               text;
  v_upc                text;
  v_upc_norm           text;
  v_master_id          uuid;
  v_carried_id         uuid;
  v_caller_email       text;
begin
  -- 0017 lockdown (unchanged): caller must be a corporate-role authenticated
  -- user. Email comes from the JWT, NOT from p_actor_email — that parameter
  -- is caller-controlled and is used only as the audit-column value.
  v_caller_email := lower(coalesce((auth.jwt() ->> 'email'), ''));
  if v_caller_email = '' then
    raise exception 'import_inventory_csv requires an authenticated session';
  end if;
  if not exists (
    select 1 from public.app_users
     where lower(email) = v_caller_email
       and role = 'corporate'
       and is_active = true
  ) then
    raise exception 'import_inventory_csv requires corporate role; caller % is not authorized', v_caller_email;
  end if;

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
      -- New purchase_items row. FIX 0034: 0015/0017 listed 7 target columns
      -- but only 6 values (is_active had no expression) — this branch has
      -- never worked. New rows are explicitly active.
      insert into public.purchase_items (name, brand, size, upc, category, sku, is_active)
      values (
        v_name,
        nullif(trim(v_item->>'brand'),    ''),
        nullif(trim(v_item->>'size'),     ''),
        v_upc,
        nullif(trim(v_item->>'category'), ''),
        nullif(trim(v_item->>'sku'),      ''),
        true
      )
      returning id into v_pid;
      v_inserted_master := v_inserted_master + 1;
    end if;

    v_csv_pids := array_append(v_csv_pids, v_pid);

    -- Path B (0034): resolve the master for the carried row.
    --   1. master_item_upcs lookup on the normalized UPC (digits only,
    --      leading zeros stripped — same normalization as 0020).
    --   2. else case-insensitive name match against ACTIVE master_items.
    --   3. else NULL (counted in unresolved_master_count).
    v_master_id := null;
    v_upc_norm  := case
      when v_upc is not null
      then nullif(regexp_replace(regexp_replace(v_upc, '[^0-9]', '', 'g'), '^0+', ''), '')
    end;
    if v_upc_norm is not null then
      select master_item_id into v_master_id
        from public.master_item_upcs
       where upc_normalized = v_upc_norm
       limit 1;
    end if;
    if v_master_id is null then
      select id into v_master_id
        from public.master_items
       where lower(name) = lower(v_name)
         and is_active = true
       limit 1;
    end if;
    if v_master_id is null then
      v_unresolved_master := v_unresolved_master + 1;
    end if;

    -- Mark carried. Two unique keys now exist (purchase_item_id AND
    -- master_item_id, both from 0033) and ON CONFLICT can only arbitrate on
    -- one, so we resolve the existing row explicitly instead. Master match
    -- is checked first — it's the key both clients read by. Existing rows
    -- are only backfilled (never overwritten), and audit columns are not
    -- bumped, so re-uploading the same CSV stays idempotent.
    v_carried_id := null;
    if v_master_id is not null then
      select id into v_carried_id
        from public.kount_carried_items
       where master_item_id = v_master_id
       limit 1;
    end if;

    if v_carried_id is not null then
      -- Master-keyed row exists: backfill its purchase link, but only if no
      -- OTHER row already holds this purchase_item_id (unique index).
      update public.kount_carried_items
         set purchase_item_id = v_pid
       where id = v_carried_id
         and purchase_item_id is null
         and not exists (
           select 1 from public.kount_carried_items x
            where x.purchase_item_id = v_pid
         );
    else
      select id into v_carried_id
        from public.kount_carried_items
       where purchase_item_id = v_pid
       limit 1;

      if v_carried_id is not null then
        -- Purchase-keyed row exists: backfill the master link. Safe — we
        -- just verified no row carries v_master_id.
        update public.kount_carried_items
           set master_item_id = v_master_id
         where id = v_carried_id
           and master_item_id is null
           and v_master_id is not null;
      else
        insert into public.kount_carried_items (
          purchase_item_id, master_item_id, added_by_email, added_by_name, notes
        )
        values (v_pid, v_master_id, p_actor_email, p_actor_name, 'imported via CSV');
        v_added_carried := v_added_carried + 1;
      end if;
    end if;
  end loop;

  -- Replace mode: ONLY purchase-only rows (master_item_id IS NULL) not in
  -- this CSV are removed. Master-curated rows are NEVER deleted here: the
  -- phone and admin catalog both read `master_item_id is not null`, so the
  -- pre-0034 unconditional delete let a CSV upload wipe the live curated
  -- catalog. Curated rows are removed only via the admin Catalog toggle.
  -- Still skipped entirely if the CSV was empty (defensive).
  if p_replace and array_length(v_csv_pids, 1) > 0 then
    with deleted as (
      delete from public.kount_carried_items
       where master_item_id is null
         and purchase_item_id is not null
         and not (purchase_item_id = any(v_csv_pids))
       returning 1
    )
    select count(*) into v_removed_carried from deleted;
  end if;

  return jsonb_build_object(
    'inserted_master',         v_inserted_master,
    'updated_master',          v_updated_master,
    'added_carried',           v_added_carried,
    'removed_carried',         v_removed_carried,
    'skipped',                 v_skipped,
    'unresolved_master_count', v_unresolved_master
  );
end;
$$;

-- Re-assert the 0017 grant posture: no anon, authenticated only (the
-- corporate-role check inside the body is the real gate).
revoke execute on function public.import_inventory_csv(jsonb, boolean, text, text) from anon;
grant  execute on function public.import_inventory_csv(jsonb, boolean, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
-- 1. New-item branch works (as corporate user):
--      select import_inventory_csv(
--        '[{"name":"__migration_test_item__","upc":"000111222333"}]'::jsonb);
--    Expect inserted_master = 1 (first run), and a carried row with both
--    purchase_item_id and (if UPC/name resolved) master_item_id set.
--    Clean up: delete from kount_carried_items where notes='imported via CSV'
--    and ... ; delete from purchase_items where name='__migration_test_item__';
--
-- 2. Replace-mode safety: count master-curated rows before/after a replace
--    upload — must be unchanged:
--      select count(*) from kount_carried_items where master_item_id is not null;
