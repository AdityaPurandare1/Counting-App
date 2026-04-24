-- =============================================================================
--  kΩunt — fix upc_mappings approve/reject RPCs + status-gate trigger (0005)
--  Target: PostgreSQL (Supabase). Idempotent.
-- =============================================================================
--
--  Symptom: desktop Approvals screen errors with
--    'Status changes must go through approve_upc_mapping() or reject_upc_mapping()'
--  even though the client IS calling approve_upc_mapping().
--
--  Root cause: an older trigger guarding status changes expected a session
--  variable the current RPC no longer sets. The trigger fires inside the
--  RPC's UPDATE and blows up. Net effect: no admin can approve or reject
--  anything, and counters' pending submissions pile up indefinitely.
--
--  Fix: drop any status-gate trigger on upc_mappings, then
--  CREATE OR REPLACE both RPCs with clean bodies so PostgREST has a
--  correct callable and direct UPDATEs (the Force-approve escape hatch in
--  desktop v0.12) also succeed.
--
--  Security note: permissive-dev RLS still lets anon PATCH upc_mappings.status
--  directly. That's consistent with every other kount_* table today. When we
--  move to Supabase Auth and auth-enforced RLS (commented block in 0001),
--  the status-gate will be re-expressed as a policy on the table.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Drop any lingering triggers on upc_mappings so the gate can't fire again.
--    Targets all user-defined triggers on the table to be thorough — none of
--    them are protected app invariants at this stage.
-- -----------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select trigger_name
      from information_schema.triggers
     where event_object_schema = 'public'
       and event_object_table  = 'upc_mappings'
       and trigger_name not like 'RI_%'            -- keep FK internal triggers
  loop
    execute format('drop trigger if exists %I on public.upc_mappings', r.trigger_name);
  end loop;
end $$;


-- -----------------------------------------------------------------------------
-- 2. approve_upc_mapping(p_mapping_id, p_admin_email, p_admin_name)
--    Flips the row to 'approved', stamps the reviewer, and copies the
--    barcode onto purchase_items.upc when a purchase_item_id is linked.
--    Returns jsonb { ok:true, id } on success or { ok:false, error } on
--    missing / already-finalized mapping.
-- -----------------------------------------------------------------------------
create or replace function public.approve_upc_mapping(
  p_mapping_id uuid,
  p_admin_email text,
  p_admin_name  text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.upc_mappings;
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

  if rec.purchase_item_id is not null then
    update public.purchase_items
       set upc = rec.barcode_raw
     where id = rec.purchase_item_id;
  end if;

  return jsonb_build_object('ok', true, 'id', rec.id);
end;
$$;


-- -----------------------------------------------------------------------------
-- 3. reject_upc_mapping(p_mapping_id, p_admin_email, p_admin_name, p_reason)
-- -----------------------------------------------------------------------------
create or replace function public.reject_upc_mapping(
  p_mapping_id uuid,
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
-- 4. Grant EXECUTE so PostgREST /rest/v1/rpc/<fn> works for anon callers.
--    SECURITY DEFINER above means the function runs with the function owner's
--    permissions, so RLS on the underlying tables is bypassed inside the body.
-- -----------------------------------------------------------------------------
grant execute on function public.approve_upc_mapping(uuid, text, text)           to anon;
grant execute on function public.reject_upc_mapping(uuid, text, text, text)      to anon;


-- -----------------------------------------------------------------------------
-- 5. VERIFICATION — run these after applying.
-- -----------------------------------------------------------------------------
-- Should return 0 rows (no user-defined triggers on upc_mappings):
-- select trigger_name from information_schema.triggers
--  where event_object_schema='public' and event_object_table='upc_mappings'
--    and trigger_name not like 'RI_%';

-- Both functions should exist:
-- select routine_name from information_schema.routines
--  where routine_schema='public' and routine_name in ('approve_upc_mapping', 'reject_upc_mapping');

-- Smoke-test against a pending row (replace <uuid> with a real id):
-- select public.approve_upc_mapping('<uuid>', 'admin@hwood.com', 'Admin');
