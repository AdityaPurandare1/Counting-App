-- =============================================================================
--  0062_rename_venue_zone
--
--  Zones are free-text labels with no rename tool — only add/remove (0008:
--  "zones are immutable; rename = delete + insert"). Using remove+add to
--  represent a rename or consolidation orphans every historical kount_entries /
--  kount_recounts row under the old name, so variance and trend history splits
--  in two at the rename point.
--
--  This is a NEW, separate action. Removing a zone still means "this zone is
--  gone"; rename/merge is for "same physical space, different label" — the
--  only case where history should follow.
--
--  rename_venue_zone(p_venue_id, p_old_zone_name, p_new_zone_name):
--    * Gate: verified JWT email (auth.jwt()), active admin/corporate — the same
--      check shape 0052/0057 use and the same role pair as 0058. NOT a
--      caller-supplied email argument (that pattern was rejected in 0057 as a
--      security regression). raise 42501 on failure, like 0052/0057.
--    * Refused while the venue has an ACTIVE audit: phones mid-count hold zone
--      names in local state and per-(item,zone) recount keys; renaming under
--      them would desync their sync. Renames are a between-audits desk action.
--    * Old/target names are resolved to their STORED spelling (default_zones
--      or kount_venue_zones) and matched EXACTLY, because the uniqueness keys
--      below use the exact zone text. Legacy case/spacing variants in old
--      history are left untouched rather than risk folding them incorrectly.
--    * If the target name already exists (or old history already uses it),
--      rows that would collide are FOLDED instead of failing the unique index:
--        - kount_entries  (unique: audit, zone, item key, is_recount):
--            target.qty += source.qty, source row deleted (0050 snapshots the
--            delete into kount_entries_deleted_log, so it stays recoverable)
--        - kount_recounts (unique: audit, item key, zone):
--            count1/count2 summed (null only if both null), status 'done' only
--            if both done, 'corrected' wins over 'verified', reasons joined.
--      Non-colliding rows are simply relabeled.
--    * kount_entries_deleted_log is NOT rewritten — it is a recovery record and
--      keeps the zone name each row actually had.
--    * Zone list: a default zone is relabeled in place in kount_venues
--      .default_zones (or dropped on merge). A custom zone is re-created under
--      the new name and the old row deleted (not UPDATEd): the phone's realtime
--      zone listener only handles INSERT/DELETE on kount_venue_zones.
--
--  EXECUTE: authenticated only (anon and PUBLIC revoked).
--
--  Apply manually (NEVER db push):
--    supabase db query --linked --file supabase/migrations/0062_rename_venue_zone.sql
--  Shared DB (KevaOS/Restaurant-App) — touches kount_* tables and
--  kount_venues.default_zones only. Additive, idempotent.
-- =============================================================================

create or replace function public.rename_venue_zone(
  p_venue_id      text,
  p_old_zone_name text,
  p_new_zone_name text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old              text := trim(coalesce(p_old_zone_name, ''));
  v_new              text := trim(coalesce(p_new_zone_name, ''));
  v_default_zones    text[];
  v_old_stored       text;
  v_old_is_default   boolean := false;
  v_target           text;
  v_target_listed    boolean := false;
  v_idx              int;
  v_actor            text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_entries_folded   int := 0;
  v_entries_moved    int := 0;
  v_recounts_folded  int := 0;
  v_recounts_moved   int := 0;
begin
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = v_actor
       and u.is_active = true
       and u.role = any (array['corporate', 'admin'])
  ) then
    raise exception 'not authorized: rename_venue_zone is admin/corporate only'
      using errcode = '42501';
  end if;

  if v_old = '' or v_new = '' then
    return jsonb_build_object('ok', false, 'error', 'Old and new zone names are required');
  end if;
  if lower(v_old) = lower(v_new) then
    return jsonb_build_object('ok', false, 'error', 'New zone name must be different from the old one');
  end if;

  -- Lock the venue row so two admins can't rename concurrently.
  select default_zones into v_default_zones
    from public.kount_venues where id = p_venue_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venue not found');
  end if;

  if exists (select 1 from public.kount_audits where venue_id = p_venue_id and status = 'active') then
    return jsonb_build_object('ok', false, 'error',
      'This venue has an audit in progress. Finish or cancel it first — phones mid-count would fall out of sync with a renamed zone.');
  end if;

  -- Resolve the OLD zone to its stored spelling.
  select z into v_old_stored from unnest(v_default_zones) z where lower(z) = lower(v_old) limit 1;
  if v_old_stored is not null then
    v_old_is_default := true;
  else
    select zone_name into v_old_stored
      from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_old)
     limit 1;
  end if;
  if v_old_stored is null then
    return jsonb_build_object('ok', false, 'error', 'Zone "' || v_old || '" not found for this venue');
  end if;

  -- Resolve the TARGET: an existing listed zone's stored spelling (merge), or
  -- the typed name (rename).
  select z into v_target from unnest(v_default_zones) z where lower(z) = lower(v_new) limit 1;
  if v_target is null then
    select zone_name into v_target
      from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_new)
     limit 1;
  end if;
  v_target_listed := v_target is not null;
  if not v_target_listed then v_target := v_new; end if;

  -- ---- kount_entries: fold collisions, then relabel the rest ---------------
  with pairs as (
    select s.id as src_id, t.id as tgt_id, s.qty as src_qty
      from public.kount_entries s
      join public.kount_audits a on a.id = s.audit_id and a.venue_id = p_venue_id
      join public.kount_entries t
        on t.audit_id = s.audit_id
       and t.zone = v_target
       and t.is_recount = s.is_recount
       and coalesce(t.item_id::text, lower(t.item_name)) = coalesce(s.item_id::text, lower(s.item_name))
     where s.zone = v_old_stored
  ), upd as (
    update public.kount_entries t
       set qty = t.qty + p.src_qty
      from pairs p
     where t.id = p.tgt_id
    returning p.src_id
  )
  delete from public.kount_entries where id in (select src_id from upd);
  get diagnostics v_entries_folded = row_count;

  update public.kount_entries e
     set zone = v_target
    from public.kount_audits a
   where a.id = e.audit_id and a.venue_id = p_venue_id
     and e.zone = v_old_stored;
  get diagnostics v_entries_moved = row_count;

  -- ---- kount_recounts: fold collisions, then relabel the rest --------------
  with pairs as (
    select s.id as src_id, t.id as tgt_id,
           s.count1_qty as s_c1, s.count2_qty as s_c2, s.status as s_status,
           s.audit_result as s_result, s.audit_reason as s_reason, s.resolved_at as s_resolved
      from public.kount_recounts s
      join public.kount_audits a on a.id = s.audit_id and a.venue_id = p_venue_id
      join public.kount_recounts t
        on t.audit_id = s.audit_id
       and coalesce(t.zone, '') = v_target
       and coalesce(t.item_id::text, lower(t.item_name)) = coalesce(s.item_id::text, lower(s.item_name))
     where coalesce(s.zone, '') = v_old_stored
  ), upd as (
    update public.kount_recounts t
       set count1_qty   = case when t.count1_qty is null and p.s_c1 is null then null
                               else coalesce(t.count1_qty, 0) + coalesce(p.s_c1, 0) end,
           count2_qty   = case when t.count2_qty is null and p.s_c2 is null then null
                               else coalesce(t.count2_qty, 0) + coalesce(p.s_c2, 0) end,
           status       = case when t.status = 'done' and p.s_status = 'done' then 'done'
                               when t.status = 'dismissed' and p.s_status = 'dismissed' then 'dismissed'
                               else 'pending' end,
           audit_result = case when t.audit_result = 'corrected' or p.s_result = 'corrected' then 'corrected'
                               else coalesce(t.audit_result, p.s_result) end,
           audit_reason = nullif(concat_ws(' / ', nullif(t.audit_reason, ''), nullif(p.s_reason, '')), ''),
           resolved_at  = greatest(t.resolved_at, p.s_resolved)
      from pairs p
     where t.id = p.tgt_id
    returning p.src_id
  )
  delete from public.kount_recounts where id in (select src_id from upd);
  get diagnostics v_recounts_folded = row_count;

  update public.kount_recounts r
     set zone = v_target
    from public.kount_audits a
   where a.id = r.audit_id and a.venue_id = p_venue_id
     and coalesce(r.zone, '') = v_old_stored;
  get diagnostics v_recounts_moved = row_count;

  -- ---- zone list bookkeeping ------------------------------------------------
  if v_old_is_default then
    v_idx := array_position(v_default_zones, v_old_stored);
    if v_target_listed then
      v_default_zones := array_remove(v_default_zones, v_old_stored);
    else
      v_default_zones[v_idx] := v_target;
    end if;
    update public.kount_venues set default_zones = v_default_zones where id = p_venue_id;
  else
    if not v_target_listed then
      insert into public.kount_venue_zones (venue_id, zone_name, created_by)
      values (p_venue_id, v_target, v_actor)
      on conflict (venue_id, zone_name) do nothing;
    end if;
    delete from public.kount_venue_zones
     where venue_id = p_venue_id and zone_name = v_old_stored;
  end if;

  return jsonb_build_object(
    'ok', true,
    'merged', v_target_listed,
    'old_zone', v_old_stored,
    'new_zone', v_target,
    'entries_moved', v_entries_moved,
    'entries_folded', v_entries_folded,
    'recounts_moved', v_recounts_moved,
    'recounts_folded', v_recounts_folded
  );
end;
$$;

revoke all on function public.rename_venue_zone(text, text, text) from public, anon;
grant execute on function public.rename_venue_zone(text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- VERIFICATION — run each block inside BEGIN ... ROLLBACK against prod data.
-- -----------------------------------------------------------------------------
-- 1. Unauthorized caller is refused before anything is touched:
--    set local request.jwt.claims = '{"email":"not-an-admin@hwood.com"}';
--    select public.rename_venue_zone('<venue id>', 'Back Bar', 'Service Bar');
--    -- expect: ERROR 42501 not authorized
-- 2. As a real admin, pure rename of a default zone (no active audit):
--    set local request.jwt.claims = '{"email":"<admin email>"}';
--    select public.rename_venue_zone('<venue id>', 'Back Bar', 'Service Bar');
--    select default_zones from kount_venues where id = '<venue id>';  -- relabeled in place
--    select count(*) from kount_entries e join kount_audits a on a.id = e.audit_id
--     where a.venue_id = '<venue id>' and e.zone = 'Back Bar';         -- expect 0
-- 3. Merge into an existing zone where an audit counted the same item in both:
--    the target row's qty must equal the sum; no unique-violation error.
-- 4. With an active audit at the venue: expect {ok:false, error:'...in progress...'}.
