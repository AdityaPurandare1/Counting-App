-- =============================================================================
--  0047_pending_item_admin_gate
--
--  Closes the same authorization gap 0046 fixed on approve_upc_mapping /
--  reject_upc_mapping, on their sibling pair approve_pending_item /
--  reject_pending_item (0009, approve_pending_item last redefined in 0026).
--
--  Neither function ever verified that p_admin_email actually holds an
--  admin (corporate/manager) role in app_users. Both are SECURITY DEFINER
--  with EXECUTE granted to anon (0009) and authenticated (0016), so the
--  "only admin/manager can approve/reject" rule enforced in
--  counting-app.html (approvePendingItem/rejectPendingItem) was purely
--  cosmetic — anyone holding the public anon key could call either RPC
--  directly with an arbitrary p_admin_email and approve/reject any pending
--  item. Note: 0028's own comment ("the role check already lives inside
--  the RPC's own guards") was incorrect — no such check ever existed here.
--
--  Both functions keep their existing signatures (CREATE OR REPLACE), so no
--  new GRANT is needed — the existing EXECUTE privileges carry over.
--
--  Apply by hand (NEVER db push), same as every other migration here:
--    supabase db query --linked --file supabase/migrations/0047_pending_item_admin_gate.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- approve_pending_item (master-aware, now admin-gated)
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
  -- 0. Authorization gate — mirrors compute_avt_for_audit (0039) and the
  --    0046 fix on approve_upc_mapping. Checked BEFORE touching
  --    kount_pending_items at all, so an unauthorized call leaves no trace
  --    of a status flip to roll back.
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(p_admin_email, ''))
       and u.is_active = true
       and u.role in ('corporate', 'manager')
  ) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized: admin or manager role required');
  end if;

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

-- -----------------------------------------------------------------------------
-- reject_pending_item (now admin-gated — same authorization check as above)
-- -----------------------------------------------------------------------------
create or replace function public.reject_pending_item(
  p_pending_id uuid,
  p_admin_email text,
  p_admin_name  text default null,
  p_reason      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.kount_pending_items;
begin
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(p_admin_email, ''))
       and u.is_active = true
       and u.role in ('corporate', 'manager')
  ) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized: admin or manager role required');
  end if;

  update public.kount_pending_items
     set status            = 'rejected',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now(),
         reject_reason     = p_reason
   where id     = p_pending_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pending item not found or already finalized');
  end if;

  return jsonb_build_object('ok', true, 'pending_id', rec.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- VERIFICATION — run these after applying.
-- -----------------------------------------------------------------------------
-- A non-admin email must be rejected without touching the row:
-- select public.approve_pending_item('<some pending item uuid>', 'not-an-admin@hwood.com', 'Nobody');
-- expect: {"ok": false, "error": "Not authorized: admin or manager role required"}
-- then confirm the row is still 'pending':
-- select status from public.kount_pending_items where id = '<same uuid>';

-- select public.reject_pending_item('<some pending item uuid>', 'not-an-admin@hwood.com', 'Nobody', 'test');
-- expect: {"ok": false, "error": "Not authorized: admin or manager role required"}
-- select status from public.kount_pending_items where id = '<same uuid>';  -- expect: still pending

-- A real admin/manager email must still work end-to-end as before:
-- select public.approve_pending_item('<some pending item uuid>', '<real admin email>', 'Admin');
-- select status, master_item_id from public.kount_pending_items where id = '<same uuid>';  -- expect: approved, master_item_id set
