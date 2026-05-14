-- =============================================================================
--  0026_master_rpcs
--
--  Rewrites approve_upc_mapping + approve_pending_item to target master_items
--  instead of purchase_items.
--
--  approve_upc_mapping (new):
--    - Flips upc_mappings to approved (with concurrency guard).
--    - Inserts a row into master_item_upcs (master_item_id = mapping's linked
--      master, or caller-supplied, or name-fallback against master_items).
--    - Stops writing to purchase_items.upc — that path produced the over-
--      propagation problem we cleaned up in 0022.
--
--  approve_pending_item (new):
--    - Flips kount_pending_items to approved (with concurrency guard).
--    - Mints a new master_items row in an in-scope category. Brand is
--      folded into the name (master_items has no brand column; existing
--      catalog names like "Belvedere 750ml" already do this).
--    - Sets kount_pending_items.master_item_id back to the new master.
--    - Stops minting purchase_items rows — procurement integration owns
--      that table going forward.
--    - If the pending row carries a UPC, inserts a master_item_upcs row too.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Drop the legacy signatures so the new ones aren't accidentally bypassed
-- via PostgreSQL function-overload resolution. Idempotent on re-run.
-- -----------------------------------------------------------------------------
drop function if exists public.approve_upc_mapping(uuid, text, text);
drop function if exists public.approve_pending_item(uuid, text, text, uuid);

-- -----------------------------------------------------------------------------
-- approve_upc_mapping (master-aware)
-- -----------------------------------------------------------------------------
create or replace function public.approve_upc_mapping(
  p_mapping_id     uuid,
  p_admin_email    text,
  p_admin_name     text default null,
  p_master_item_id uuid default null     -- explicit override (admin picked)
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec               public.upc_mappings;
  target_master_id  uuid;
  upc_norm          text;
  match_count       int;
  matched_by        text := 'none';
begin
  -- 1. Lock + flip the mapping to approved.
  update public.upc_mappings
     set status            = 'approved',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id     = p_mapping_id
     and status = 'pending'
   returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mapping not found or already finalized');
  end if;

  -- 2. Decide which master_item this UPC attaches to.
  --    Priority: caller-supplied override > mapping's own master_item_id >
  --    name-fallback against master_items.
  if p_master_item_id is not null then
    target_master_id := p_master_item_id;
    matched_by := 'caller_supplied';
  elsif rec.master_item_id is not null then
    target_master_id := rec.master_item_id;
    matched_by := 'mapping_master_item_id';
  else
    -- Fallback: exact case-insensitive name match against ACTIVE masters
    -- with no UPC already attached to them via master_item_upcs.
    select count(*), max(mi.id)
      into match_count, target_master_id
      from public.master_items mi
     where lower(mi.name) = lower(rec.item_name)
       and mi.is_active = true
       and not exists (
         select 1 from public.master_item_upcs miu where miu.master_item_id = mi.id
       );
    if match_count = 1 then
      matched_by := 'name';
    elsif match_count > 1 then
      matched_by := 'ambiguous-name';
      return jsonb_build_object('ok', false, 'error', 'Multiple master_items match the name; admin must pick explicitly');
    else
      matched_by := 'no-match';
      return jsonb_build_object('ok', false, 'error', 'No master_items match the item_name; admin must pick explicitly');
    end if;
  end if;

  -- 3. Insert into master_item_upcs. Normalize the UPC to match the column
  --    invariant (digits only, no leading zeros). If a row already exists
  --    for this UPC, the unique index makes this a no-op via ON CONFLICT.
  upc_norm := regexp_replace(regexp_replace(trim(coalesce(rec.barcode_raw, '')), '[^0-9]', '', 'g'), '^0+', '');
  if upc_norm = '' then
    return jsonb_build_object(
      'ok', true, 'id', rec.id,
      'matched_by', matched_by, 'master_item_id', target_master_id,
      'warning', 'No digits in barcode — no master_item_upcs row created'
    );
  end if;

  insert into public.master_item_upcs
    (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
  values (
    target_master_id,
    trim(rec.barcode_raw),
    upc_norm,
    'scan_approved',
    'Approved via approve_upc_mapping (' || matched_by || ')',
    p_admin_email
  )
  on conflict (upc_normalized) do nothing;

  -- 4. Write master_item_id back onto the mapping so future lookups are clean.
  update public.upc_mappings
     set master_item_id = target_master_id
   where id = rec.id
     and master_item_id is null;

  return jsonb_build_object(
    'ok', true,
    'id', rec.id,
    'matched_by', matched_by,
    'master_item_id', target_master_id
  );
end;
$function$;

-- -----------------------------------------------------------------------------
-- approve_pending_item (master-aware)
-- -----------------------------------------------------------------------------
create or replace function public.approve_pending_item(
  p_pending_id     uuid,
  p_admin_email    text,
  p_admin_name     text default null,
  p_organization_id uuid default null,
  p_target_master_id uuid default null   -- if caller wants to LINK to existing master instead of minting a new one
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec        public.kount_pending_items;
  new_master uuid;
  org_id     uuid;
  has_org_col_master boolean;
  composed_name      text;
  parsed_size        numeric;
  parsed_unit        text;
  size_match         text[];
  upc_norm           text;
begin
  -- 1. Lock + flip pending row.
  update public.kount_pending_items
     set status            = 'approved',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id     = p_pending_id
     and status = 'pending'
   returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pending item not found or already finalized');
  end if;

  -- 2. Branch: link to an existing master OR mint a new one.
  if p_target_master_id is not null then
    new_master := p_target_master_id;
  else
    -- Validate category is in-scope for the counting app.
    if rec.category is not null and rec.category not in (
      'Wine Cost', 'wine', 'Wine',
      'Liquor Cost', 'liquor', 'Liquor',
      'Beer Cost', 'beer',
      'N/A Beverage Cost', 'non_alcoholic_beverage',
      'Bar Consumables', 'bar_consumable',
      'Bar Supplies'
    ) then
      -- Roll the flip back so the admin can change category and retry.
      update public.kount_pending_items
         set status = 'pending', reviewed_at = null, reviewed_by_email = null, reviewed_by_name = null
       where id = rec.id;
      return jsonb_build_object('ok', false, 'error', 'Out-of-scope category: ' || rec.category);
    end if;

    -- Resolve org id (caller > most-common in catalog).
    org_id := p_organization_id;
    select exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'master_items' and column_name = 'organization_id'
    ) into has_org_col_master;
    if has_org_col_master and org_id is null then
      execute $sql$
        select organization_id from public.master_items
         where organization_id is not null
         group by organization_id order by count(*) desc limit 1
      $sql$ into org_id;
    end if;

    -- Compose display name. master_items has no `brand` column; brand is
    -- conventionally embedded in the name. Example: pending row
    --   { name='Reposado', brand='Don Julio', size='750ml' }
    --   → composed: "Don Julio Reposado 750ml"
    composed_name := trim(
      coalesce(rec.brand, '') || ' ' ||
      coalesce(rec.name, '')  || ' ' ||
      coalesce(rec.size, '')
    );
    composed_name := regexp_replace(composed_name, '\s+', ' ', 'g');

    -- Parse the size text into base_size + base_unit (best-effort).
    size_match := regexp_match(coalesce(rec.size, ''), '^\s*(\d+(?:\.\d+)?)\s*(ml|cl|l|oz|each|ea)\s*$', 'i');
    if size_match is not null then
      parsed_size := size_match[1]::numeric;
      parsed_unit := lower(size_match[2]);
      if parsed_unit = 'cl' then
        parsed_size := parsed_size * 10;
        parsed_unit := 'ml';
      end if;
    end if;

    -- Mint the master.
    if has_org_col_master then
      insert into public.master_items(name, category, subcategory, base_size, base_unit, organization_id, is_active)
      values (composed_name, rec.category, rec.subcategory, parsed_size, parsed_unit, org_id, true)
      returning id into new_master;
    else
      insert into public.master_items(name, category, subcategory, base_size, base_unit, is_active)
      values (composed_name, rec.category, rec.subcategory, parsed_size, parsed_unit, true)
      returning id into new_master;
    end if;
  end if;

  -- 3. Link pending row to its master.
  update public.kount_pending_items
     set master_item_id = new_master
   where id = rec.id;

  -- 4. If the pending row carried a UPC, attach it to the new master.
  upc_norm := regexp_replace(regexp_replace(trim(coalesce(rec.upc, '')), '[^0-9]', '', 'g'), '^0+', '');
  if upc_norm <> '' then
    insert into public.master_item_upcs
      (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
    values (
      new_master, trim(rec.upc), upc_norm,
      'scan_approved',
      'From kount_pending_items via approve_pending_item',
      p_admin_email
    )
    on conflict (upc_normalized) do nothing;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', rec.id,
    'master_item_id', new_master
  );
end;
$function$;
