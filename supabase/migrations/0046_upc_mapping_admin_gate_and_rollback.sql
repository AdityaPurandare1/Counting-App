-- =============================================================================
--  0046_upc_mapping_admin_gate_and_rollback
--
--  Fixes two bugs in approve_upc_mapping / reject_upc_mapping found in
--  review (both introduced/left open across 0005/0006/0026):
--
--  1. SECURITY — neither function ever verified that p_admin_email actually
--     holds an admin (corporate/manager) role in app_users. Both are
--     SECURITY DEFINER and EXECUTE is available to anon (default PUBLIC
--     grant), so the "only admin/manager can approve/reject" rule enforced
--     in counting-app.html (approveUPCPending/rejectUPCPending) was purely
--     cosmetic — anyone holding the public anon key could call the RPC
--     directly with an arbitrary p_admin_email and approve/reject any
--     pending mapping. Same pattern compute_avt_for_audit already uses
--     (0039's "Authorization gate") is applied here.
--
--  2. ROLLBACK — approve_upc_mapping flips upc_mappings.status to 'approved'
--     BEFORE attempting to resolve the target master_item (step 2). If that
--     resolution fails (ambiguous name match, or no match at all), the
--     function returns {ok:false, ...} but the earlier UPDATE already
--     committed — the row is left permanently 'approved' with no
--     master_item_upcs link, and every retry (even one that supplies
--     p_master_item_id explicitly) hits the `where status = 'pending'`
--     guard and returns a misleading "already finalized" error. Its
--     sibling approve_pending_item (same file, 0026) already rolls back on
--     its own validation-failure branch — this applies the same pattern.
--
--  Both functions keep their existing signatures (CREATE OR REPLACE), so no
--  new GRANT is needed — the existing EXECUTE privilege carries over.
--
--  Apply by hand (NEVER db push), same as every other migration here:
--    supabase db query --linked --file supabase/migrations/0046_upc_mapping_admin_gate_and_rollback.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- approve_upc_mapping (master-aware, admin-gated, rollback-on-failure)
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
  -- 0. Authorization gate — mirrors compute_avt_for_audit (0039). Checked
  --    BEFORE touching upc_mappings at all, so an unauthorized call leaves
  --    no trace of a status flip to roll back.
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(p_admin_email, ''))
       and u.is_active = true
       and u.role in ('corporate', 'manager')
  ) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized: admin or manager role required');
  end if;

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
      -- Roll the flip back so the row stays 'pending' and retryable —
      -- previously this left the row stuck 'approved' with no link.
      update public.upc_mappings
         set status = 'pending', reviewed_at = null, reviewed_by_email = null, reviewed_by_name = null
       where id = rec.id;
      return jsonb_build_object('ok', false, 'error', 'Multiple master_items match the name; admin must pick explicitly');
    else
      -- Same rollback for the no-match branch.
      update public.upc_mappings
         set status = 'pending', reviewed_at = null, reviewed_by_email = null, reviewed_by_name = null
       where id = rec.id;
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
-- reject_upc_mapping (admin-gated — same authorization check as above)
-- -----------------------------------------------------------------------------
create or replace function public.reject_upc_mapping(
  p_mapping_id  uuid,
  p_admin_email text,
  p_admin_name  text default null,
  p_reason      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.upc_mappings;
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

  update public.upc_mappings
     set status = 'rejected',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id = p_mapping_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mapping not found or already finalized');
  end if;

  return jsonb_build_object('ok', true, 'id', rec.id, 'reason', p_reason);
end;
$$;

-- -----------------------------------------------------------------------------
-- VERIFICATION — run these after applying.
-- -----------------------------------------------------------------------------
-- A non-admin email must be rejected without touching the row:
-- select public.approve_upc_mapping('<some pending mapping uuid>', 'not-an-admin@hwood.com', 'Nobody');
-- expect: {"ok": false, "error": "Not authorized: admin or manager role required"}
-- then confirm the row is still 'pending':
-- select status from public.upc_mappings where id = '<same uuid>';

-- A mapping whose item_name matches zero/multiple active masters must stay
-- retryable after a failed admin approval:
-- select public.approve_upc_mapping('<ambiguous/no-match mapping uuid>', '<real admin email>', 'Admin');
-- select status from public.upc_mappings where id = '<same uuid>';  -- expect: pending (not approved)
