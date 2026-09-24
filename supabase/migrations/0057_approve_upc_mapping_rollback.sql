-- =============================================================================
--  0057_approve_upc_mapping_rollback
--
--  Ports ONE of the two changes from hursh-dev's `0046_upc_mapping_admin_gate
--  _and_rollback` (commit c2577e4). Renumbered 0046 -> 0057 because 0046 is
--  already taken by the APPLIED `0046_clear_avt_on_audit_cancel`.
--
--  ── FOUND WHILE VERIFYING: a crash that predates BOTH branches ────────────
--  The rollback fix below could not be proved by test, because the branch it
--  protects was UNREACHABLE. The name-fallback did:
--
--      select count(*), max(mi.id) into match_count, target_master_id
--
--  master_items.id is uuid, and PostgreSQL has no max(uuid) aggregate before
--  version 18 — this cluster is 17.6. So every call that reached the
--  name-fallback aborted with:
--
--      42883: function max(uuid) does not exist
--
--  USER-VISIBLE EFFECT: approving a scanned barcode whose pending mapping has
--  no master_item_id fails outright. Both callers omit p_master_item_id (the
--  phone's approveUPCPending passes only id/email/name), and rec.master_item_id
--  is null for exactly the scan-a-new-bottle case, so the name-fallback is the
--  DEFAULT path for a counter-submitted barcode — i.e. the "link a barcode to
--  a bottle" engine has been broken on its main path since 0026 introduced
--  this line. It is carried forward verbatim in 0052 and in hursh-dev's 0046,
--  so neither branch fixes it. Nothing stranded rows as 'approved' after all:
--  the raised exception aborts the transaction, which undoes the step-1 flip
--  for free. That masked the defect as an occasional "failed to approve" toast
--  rather than visibly corrupt data.
--
--  Verified contained: approve_upc_mapping is the ONLY live function whose
--  body contains this expression.
--
--  Fixed below with (array_agg(mi.id order by mi.id))[1].
--
--  ── WHAT IS PORTED: the rollback (a real, live bug) ────────────────────────
--  approve_upc_mapping flips upc_mappings.status to 'approved' in step 1,
--  BEFORE it resolves which master_item the UPC attaches to in step 2. When
--  that resolution fails — the item_name matches several active masters, or
--  none — the function returns {ok:false, ...} but the step-1 UPDATE has
--  already committed (a plpgsql function runs inside the caller's transaction;
--  returning normally commits, it does not roll back).
--
--  The row is then stranded: permanently 'approved' with NO master_item_upcs
--  link, and every retry — including one where the admin explicitly supplies
--  p_master_item_id — re-enters at step 1, misses the `and status = 'pending'`
--  guard, and returns the misleading "Mapping not found or already finalized".
--  The barcode can never be linked without a manual UPDATE to the table.
--
--  Confirmed live in prod before writing this (2026-09-24): the deployed
--  function body contains no rollback on either failure branch.
--
--  Fix: on both failure branches, compensate the step-1 flip by restoring
--  status='pending' and clearing the reviewed_* stamps, so the mapping stays
--  retryable. This is the same pattern approve_pending_item (0026) already
--  uses on its own validation-failure branch. A compensating UPDATE (rather
--  than `raise exception`, which would roll the transaction back for free) is
--  deliberate: both callers — the phone's approveUPCPending and the admin's
--  /approvals route — branch on `data.ok === false` and surface data.error as
--  a toast. Raising would change that contract into an RPC-level error and
--  lose the specific "admin must pick explicitly" guidance.
--
--  ── WHAT IS DELIBERATELY *NOT* PORTED: his authorization gate ─────────────
--  hursh-dev also adds an "admin role check". DO NOT TAKE IT — against the
--  currently-deployed function it is a SECURITY REGRESSION, not an addition:
--
--    his gate:   where lower(u.email) = lower(coalesce(p_admin_email, ''))
--    live gate:  where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
--
--  p_admin_email is a plain function ARGUMENT the caller supplies, so his
--  version authorizes against a value the attacker controls — any signed-in
--  user could pass a corporate colleague's address and pass the check. The
--  live gate (added 2026-09-08, migration 0052-era) reads the verified JWT
--  claim instead, which cannot be spoofed, and `raise exception` with 42501
--  rather than returning a soft {ok:false}. The live gate is strictly
--  stronger and is preserved verbatim below.
--
--  reject_upc_mapping needs no change: it is a single UPDATE with nothing to
--  roll back, and already carries the correct auth.jwt() gate.
--
--  Everything else in this body is byte-identical to the deployed function.
--
--  Apply by hand (NEVER db push), same as every other migration here:
--    supabase db query --linked --file supabase/migrations/0057_approve_upc_mapping_rollback.sql
-- =============================================================================

create or replace function public.approve_upc_mapping(
  p_mapping_id     uuid,
  p_admin_email    text,
  p_admin_name     text default null,
  p_master_item_id uuid default null
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
  -- Authorization (added 2026-09-08). This function is SECURITY DEFINER and
  -- previously had NO internal check: it trusted p_admin_email, a value the
  -- caller supplies, and wrote it straight into reviewed_by_email. It was
  -- reachable only because Supabase's default PUBLIC EXECUTE grant was in
  -- place; once that was correctly revoked, granting EXECUTE back to
  -- authenticated without this gate would let any signed-in user approve
  -- catalog and barcode changes with owner privileges.
  -- corporate|manager mirrors both existing callers: the phone's
  -- approveUPCPending role check and the admin's /approvals route gate.
  -- NOTE: reads the VERIFIED JWT claim, never the p_admin_email argument.
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role in ('corporate', 'manager')
  ) then
    raise exception 'not authorized: approve_upc_mapping is corporate/manager only'
      using errcode = '42501';
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
    -- v0057 CRASH FIX: was `max(mi.id)`. mi.id is uuid and PostgreSQL has no
    -- max(uuid) before 18 (this cluster is 17.6), so EVERY call that reached
    -- this branch aborted with 42883 "function max(uuid) does not exist" —
    -- see the header. array_agg has no such gap; `order by mi.id` keeps the
    -- pick deterministic, and when zero rows match array_agg returns NULL so
    -- the [1] subscript yields NULL and match_count = 0 routes to the
    -- no-match branch exactly as intended.
    select count(*), (array_agg(mi.id order by mi.id))[1]
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
      -- v0057 ROLLBACK: undo the step-1 flip so the mapping stays 'pending'
      -- and retryable. Without this the row is stranded 'approved' with no
      -- master_item_upcs link and every retry returns "already finalized".
      -- target_master_id is NOT written back (step 4 is never reached), so
      -- the row returns to exactly its pre-call state.
      update public.upc_mappings
         set status            = 'pending',
             reviewed_at       = null,
             reviewed_by_email = null,
             reviewed_by_name  = null
       where id = rec.id;
      return jsonb_build_object('ok', false, 'error', 'Multiple master_items match the name; admin must pick explicitly');
    else
      matched_by := 'no-match';
      -- v0057 ROLLBACK: same compensation for the no-match branch.
      update public.upc_mappings
         set status            = 'pending',
             reviewed_at       = null,
             reviewed_by_email = null,
             reviewed_by_name  = null
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

-- EXECUTE privilege carries over from the existing grant (CREATE OR REPLACE
-- keeps the signature), so no new grant is needed — see 0052 for why the
-- explicit `to authenticated` grant matters on this schema.
