-- =============================================================================
--  0062_rename_venue_zone
--
--  Ported from hursh-dev 0049_rename_venue_zone (3f4bb85, Harsh Jariwala),
--  renumbered (0049 is taken by transfers) and reworked before applying.
--
--  WHY
--  Zones are free-text labels. The only tools were add and remove, so a
--  renamed space ("Back Bar" -> "Service Bar") was done as remove + add, which
--  strands every historical kount_entries / kount_recounts row under the old
--  label. Item history and variance then split at the rename, and the next
--  audit's START quantity (compute_avt reads the prior audit by zone) no
--  longer lines up with what is counted now.
--
--  WHAT rename_venue_zone(venue, old, new) does
--    - relabels kount_entries.zone, kount_recounts.zone and
--      kount_members.assigned_zones across the venue's audits, and
--    - relabels the zone-list entry (kount_venues.default_zones and/or
--      kount_venue_zones), or drops the old entry when the new name is
--      already a zone (a merge).
--
--  CHANGED FROM THE BRANCH VERSION
--    1. Authorization reads the JWT (kount_is_corporate(), which covers
--       corporate + admin, 0055). The branch trusted a caller-supplied
--       p_actor_email and granted EXECUTE to anon — anyone with the public
--       anon key could have rewritten any venue's count history. Same reason
--       0057 did not take the branch's 0046 gate. EXECUTE: authenticated only.
--    2. Refuses while the venue has an ACTIVE audit. Phones hold zone names in
--       local state and in the offline queue; relabelling under them would
--       land queued counts in a zone that no longer exists.
--    3. Refuses when any single audit has rows under BOTH names (incl. case
--       variants). The branch blindly UPDATEd zone = new, which
--         - violates kount_entries_merge_key (audit, zone, item, is_recount)
--           the moment both zones counted the same bottle — the normal case
--           for two coexisting zones — so the merge failed outright; and
--         - even if summed, would be WRONG: compute_avt treats a zone recount
--           as REPLACING that zone's entry sum, so a recount from one side
--           would overwrite the merged total of both.
--       Merging two zones that never coexisted in an audit — the
--       remove-then-re-add case this exists for — is exactly a relabel and
--       is safe. Genuinely combining separately-counted history is not done
--       silently; the error says how many audits are affected.
--    4. The old name may be a zone that only survives in history (removed
--       from the lists, still labelling past counts) — the stranded-history
--       case this exists for; the branch rejected it as "not found". A venue
--       whose default_zones is NULL no longer reads as "not found" either.
--    5. Venue row locked FOR UPDATE so two renames cannot interleave.
--
--  Errors are returned as {ok:false, error} (not raised) so the admin can show
--  them; the authorization failure raises 42501 like every other gated RPC.
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
  v_old_idx          int;
  v_old_in_custom    boolean;
  v_target_exists    boolean;
  v_both_audits      int;
  v_entries_updated  int;
  v_recounts_updated int;
  v_members_updated  int;
begin
  if not public.kount_is_corporate() then
    raise exception 'not authorized: rename_venue_zone is corporate/admin only'
      using errcode = '42501';
  end if;

  if v_old = '' or v_new = '' then
    return jsonb_build_object('ok', false, 'error', 'Old and new zone names are required');
  end if;
  if lower(v_old) = lower(v_new) then
    return jsonb_build_object('ok', false, 'error', 'New zone name must be different from the old one');
  end if;

  select coalesce(default_zones, '{}') into v_default_zones
    from public.kount_venues
   where id = p_venue_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venue not found');
  end if;

  if exists (select 1 from public.kount_audits
              where venue_id = p_venue_id and status = 'active') then
    return jsonb_build_object('ok', false, 'error',
      'This venue has an audit in progress. Rename zones after it is submitted or cancelled.');
  end if;

  select min(o) into v_old_idx
    from unnest(v_default_zones) with ordinality u(z, o)
   where lower(z) = lower(v_old);
  v_old_in_custom := exists (
    select 1 from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_old));

  -- A zone that was removed from the lists but still labels past counts is
  -- the main thing this exists to fix, so history alone is enough.
  if v_old_idx is null and not v_old_in_custom
     and not exists (select 1 from public.kount_entries e
                       join public.kount_audits a on a.id = e.audit_id
                      where a.venue_id = p_venue_id and lower(e.zone) = lower(v_old))
     and not exists (select 1 from public.kount_recounts r
                       join public.kount_audits a on a.id = r.audit_id
                      where a.venue_id = p_venue_id and lower(r.zone) = lower(v_old)) then
    return jsonb_build_object('ok', false, 'error', 'Zone "' || v_old || '" not found for this venue');
  end if;

  v_target_exists :=
       exists (select 1 from unnest(v_default_zones) z where lower(z) = lower(v_new))
    or exists (select 1 from public.kount_venue_zones
                where venue_id = p_venue_id and lower(zone_name) = lower(v_new));

  -- Any audit that already holds more than one distinct label among
  -- {old, new} (case variants included) would have to COMBINE counts.
  select count(*) into v_both_audits
    from (
      select x.audit_id
        from (
          select e.audit_id, e.zone
            from public.kount_entries e
            join public.kount_audits a on a.id = e.audit_id
           where a.venue_id = p_venue_id
             and lower(e.zone) in (lower(v_old), lower(v_new))
          union
          select r.audit_id, r.zone
            from public.kount_recounts r
            join public.kount_audits a on a.id = r.audit_id
           where a.venue_id = p_venue_id
             and lower(r.zone) in (lower(v_old), lower(v_new))
        ) x
       group by x.audit_id
      having count(distinct x.zone) > 1
    ) both_zones;

  if v_both_audits > 0 then
    return jsonb_build_object('ok', false, 'error',
      v_both_audits || ' past audit(s) counted both "' || v_old || '" and "' || v_new ||
      '" separately, so merging would combine their counts. Nothing was changed.',
      'conflicting_audits', v_both_audits);
  end if;

  -- 1. History. Safe by the check above: no audit holds both labels, so no
  --    unique key can collide and no recount can land on a different sum.
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
     and lower(r.zone) = lower(v_old);
  get diagnostics v_recounts_updated = row_count;

  update public.kount_members m
     set assigned_zones = (
           select array_agg(z order by first_o)
             from (select case when lower(u.z) = lower(v_old) then v_new else u.z end as z,
                          min(u.o) as first_o
                     from unnest(m.assigned_zones) with ordinality u(z, o)
                    group by 1) d)
    from public.kount_audits a
   where m.audit_id = a.id
     and a.venue_id = p_venue_id
     and exists (select 1 from unnest(m.assigned_zones) z where lower(z) = lower(v_old));
  get diagnostics v_members_updated = row_count;

  -- 2. Zone lists. Rename relabels in place (keeps its default/custom status
  --    and position); merge just drops the old entry.
  if v_old_idx is not null then
    if v_target_exists then
      v_default_zones := v_default_zones[1 : v_old_idx - 1]
                      || v_default_zones[v_old_idx + 1 : array_length(v_default_zones, 1)];
    else
      v_default_zones[v_old_idx] := v_new;
    end if;
    update public.kount_venues set default_zones = v_default_zones where id = p_venue_id;
  end if;

  if v_old_in_custom then
    if v_target_exists or v_old_idx is not null then
      -- target already listed, or the default list now carries the new name
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
    'recounts_updated', v_recounts_updated,
    'members_updated', v_members_updated
  );
end;
$$;

revoke all on function public.rename_venue_zone(text, text, text) from public, anon;
grant execute on function public.rename_venue_zone(text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- VERIFICATION (run in a rolled-back transaction with a JWT claim set, e.g.
--   begin; set local role authenticated;
--   select set_config('request.jwt.claims', '{"email":"<corporate email>"}', true);
--   ... ; rollback;)
--   - counter/manager JWT                         -> 42501
--   - venue with an active audit                  -> {ok:false, "...in progress..."}
--   - pure rename of a zone with history          -> {ok:true, merged:false}, entries moved
--   - merge where one audit holds both labels     -> {ok:false, conflicting_audits:n}, nothing changed
--   - anon: has no EXECUTE
-- -----------------------------------------------------------------------------
