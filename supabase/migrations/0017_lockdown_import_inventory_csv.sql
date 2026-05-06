-- =============================================================================
--  0017_lockdown_import_inventory_csv
--
--  Background:
--    Migration 0015 created `import_inventory_csv` as a SECURITY DEFINER
--    function and granted EXECUTE to BOTH `anon` and `authenticated`.
--    Combined with the dev-mode permissive RLS this means literally any
--    holder of the public anon key can mutate the master catalog +
--    carried-items tables. That's a meaningful blast radius — a bored
--    user with browser DevTools could wipe inventory.
--
--  This migration:
--    1. Replaces the function body so it now CHECKS that the caller's
--       JWT email maps to an `app_users` row with role='corporate' AND
--       is_active=true. Without that, the function raises before any
--       writes happen.
--    2. Revokes EXECUTE from `anon` (anon callers no longer reach the
--       function at all — even before the role check).
--    3. Keeps EXECUTE on `authenticated` (corporate admins, post-Phase-1
--       auth migration, will have a JWT — they pass both gates).
--
--  Trade-off: legacy ACCESS_LIST admins (no Supabase Auth account yet)
--  cannot upload inventory until they migrate to Supabase Auth via
--  Phase 5. That's the right trade-off — the existing posture (anyone
--  with the anon key can mutate the catalog) is unsafe.
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
  v_caller_email     text;
begin
  -- 0017 lockdown: caller must be a corporate-role authenticated user.
  -- We pull the email from the JWT (auth.jwt() ->> 'email'), NOT from
  -- p_actor_email — that parameter is caller-controlled and can lie.
  -- p_actor_email stays in the signature so existing calls don't break;
  -- it's used only as the audit-column value on kount_carried_items.
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

-- Tighten EXECUTE: anon loses access entirely; authenticated keeps it
-- but only corporate gets past the role check above.
revoke execute on function public.import_inventory_csv(jsonb, boolean, text, text) from anon;
grant  execute on function public.import_inventory_csv(jsonb, boolean, text, text) to authenticated;
