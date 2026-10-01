-- =============================================================================
--  0049_rename_venue_zone
--
--  Zones are free-text labels, not a real foreign-keyed record — the only
--  existing tools are "add a zone" and "remove a zone" (0008's own comment
--  says it outright: "zones are immutable; rename = delete + insert").
--  Removing and re-adding a zone to represent a rename/consolidation
--  orphans every historical kount_entries/kount_recounts row that
--  referenced the old name: they stay stuck under the old label forever,
--  with nothing linking them to the new one. Variance/trend reports then
--  silently split in two at the rename point, and a later recount under
--  the new name looks like brand-new stock instead of a continuation.
--
--  This is deliberately a NEW, separate action — NOT a change to
--  removeCustomZone's behavior (v1.99). "Remove" still means "this zone
--  is genuinely gone" (data preserved server-side, hidden from totals, no
--  continuity implied). "Rename" is for "same physical space, different
--  label" — the only case where continuity should be preserved.
--
--  rename_venue_zone(p_venue_id, p_old_zone_name, p_new_zone_name, p_actor_email):
--    - Rewrites kount_entries.zone + kount_recounts.zone for every audit
--      belonging to this venue, old name -> new name.
--    - If the new name already exists for this venue, this is a MERGE:
--      the old zone's own list entry is dropped, the target is left as-is.
--      If it doesn't exist yet, this is a pure rename: the zone-list entry
--      itself is relabeled.
--    - Zones can live in two places depending on how they were created —
--      kount_venues.default_zones (the curated per-venue preset array from
--      0021) or kount_venue_zones (ad-hoc rows from addCustomZone, 0008).
--      Both are checked/updated so this works regardless of which kind of
--      zone is being renamed or merged into.
--    - Admin-gated the same way 0046/0047 gate their RPCs — same
--      SECURITY DEFINER + anon-grantable shape, same class of bug, no
--      reason to reintroduce it here.
--
--  Apply manually:
--    supabase db query --linked --file supabase/migrations/0049_rename_venue_zone.sql
--  Shared DB (KevaOS/Restaurant-App) — scoped to kount_* tables + the
--  default_zones column on kount_venues. Additive, idempotent.
-- =============================================================================

create or replace function public.rename_venue_zone(
  p_venue_id      text,
  p_old_zone_name text,
  p_new_zone_name text,
  p_actor_email   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old            text := trim(coalesce(p_old_zone_name, ''));
  v_new            text := trim(coalesce(p_new_zone_name, ''));
  v_default_zones  text[];
  v_old_is_default boolean;
  v_new_idx        int;
  v_target_exists  boolean;
  v_entries_updated  int;
  v_recounts_updated int;
begin
  -- 0. Authorization gate — same pattern as 0046/0047.
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(p_actor_email, ''))
       and u.is_active = true
       and u.role in ('corporate', 'manager')
  ) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized: admin or manager role required');
  end if;

  if v_old = '' or v_new = '' then
    return jsonb_build_object('ok', false, 'error', 'Old and new zone names are required');
  end if;
  if lower(v_old) = lower(v_new) then
    return jsonb_build_object('ok', false, 'error', 'New zone name must be different from the old one');
  end if;

  select default_zones into v_default_zones
    from public.kount_venues
   where id = p_venue_id;

  if v_default_zones is null then
    return jsonb_build_object('ok', false, 'error', 'Venue not found');
  end if;

  v_old_is_default := exists (
    select 1 from unnest(v_default_zones) z where lower(z) = lower(v_old)
  );

  if not v_old_is_default and not exists (
    select 1 from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_old)
  ) then
    return jsonb_build_object('ok', false, 'error', 'Zone "' || v_old || '" not found for this venue');
  end if;

  v_target_exists := exists (
    select 1 from unnest(v_default_zones) z where lower(z) = lower(v_new)
  ) or exists (
    select 1 from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_new)
  );

  -- 1. Rewrite historical references, scoped to this venue's own audits.
  update public.kount_entries e
     set zone = v_new
    from public.kount_audits a
   where e.audit_id = a.id
     and a.venue_id = p_venue_id
     and lower(e.zone) = lower(v_old);
  get diagnostics v_entries_updated = row_count;

  update public.kount_recounts r
     set zone = v_new
    from public.kount_audits a
   where r.audit_id = a.id
     and a.venue_id = p_venue_id
     and lower(coalesce(r.zone, '')) = lower(v_old);
  get diagnostics v_recounts_updated = row_count;

  -- 2. Zone-list bookkeeping. A merge (target already exists) only ever
  --    needs the OLD entry removed from wherever it lived. A pure rename
  --    relabels that same entry in place, preserving its default/custom
  --    status going forward.
  if v_old_is_default then
    v_new_idx := array_position(v_default_zones, (
      select z from unnest(v_default_zones) z where lower(z) = lower(v_old) limit 1
    ));
    if v_target_exists then
      v_default_zones := v_default_zones[1 : v_new_idx - 1] || v_default_zones[v_new_idx + 1 : array_length(v_default_zones, 1)];
    else
      v_default_zones[v_new_idx] := v_new;
    end if;
    update public.kount_venues set default_zones = v_default_zones, updated_at = now() where id = p_venue_id;
  else
    if v_target_exists then
      delete from public.kount_venue_zones
       where venue_id = p_venue_id and lower(zone_name) = lower(v_old);
    else
      update public.kount_venue_zones
         set zone_name = v_new
       where venue_id = p_venue_id and lower(zone_name) = lower(v_old);
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'merged', v_target_exists,
    'old_zone', v_old,
    'new_zone', v_new,
    'entries_updated', v_entries_updated,
    'recounts_updated', v_recounts_updated
  );
end;
$$;

grant execute on function public.rename_venue_zone(text, text, text, text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- VERIFICATION — run these after applying.
-- -----------------------------------------------------------------------------
-- A non-admin email must be rejected without touching anything:
-- select public.rename_venue_zone('<a real venue id>', 'Back Bar', 'Service Bar', 'not-an-admin@hwood.com');
-- expect: {"ok": false, "error": "Not authorized: admin or manager role required"}

-- A real admin renaming a default zone with no merge target:
-- select public.rename_venue_zone('<a real venue id>', 'Back Bar', 'Service Bar', '<real admin email>');
-- select default_zones from kount_venues where id = '<same venue id>';            -- "Back Bar" replaced by "Service Bar"
-- select count(*) from kount_entries where zone = 'Service Bar';                  -- old rows followed the rename

-- Merging an existing custom zone into another existing zone:
-- select public.rename_venue_zone('<a real venue id>', 'Old Custom Zone', 'Service Bar', '<real admin email>');
-- select * from kount_venue_zones where venue_id = '<same venue id>' and zone_name = 'Old Custom Zone';  -- expect: 0 rows
