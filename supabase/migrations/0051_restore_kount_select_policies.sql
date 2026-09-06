-- =============================================================================
--  0051_restore_kount_select_policies.sql
--
--  INCIDENT FIX — 2026-09-06. Poppy could not start an audit; the phone showed
--  "Could not create the shared audit (network issue). Nothing was started."
--
--  ROOT CAUSE: the permissive dev_/anon RLS policies were dropped across the
--  kount_* tables some time after 2026-09-02, and the cleanup was incomplete —
--  `kount_audits` and `kount_venue_zones` were left with NO SELECT policy at
--  all, while kount_entries / kount_members / kount_recounts /
--  kount_carried_items all kept theirs.
--
--  Why a missing SELECT breaks *creating* an audit: the phone's
--  supabaseRest.insert sends `Prefer: return=representation`
--  (counting-app.html ~3296), and startNetworkedAudit requires the row back —
--  `if (insErr || !inserted || !inserted[0]) return null` (~5768). PostgREST
--  inserts, then re-reads the row to return it; with no SELECT policy that
--  read is denied, the whole statement rolls back, and the caller reports a
--  network error. "Nothing was started" was literally true — the INSERT
--  policy passed, the read-back did not.
--
--  Separately, `venues` returned HTTP 401 to anon with
--  `permission denied for function vendor_visible_venue_ids`: the
--  KevaOS-side `venues_select_vendor` policy targets role `public` (which
--  includes anon) and calls that SECURITY DEFINER function, but anon was
--  never granted EXECUTE on it — unlike is_platform_admin / is_super_admin,
--  which both carry `anon=X`. Granting it restores parity with those two.
--
--  SCOPE: additive and fully reversible. These SELECT policies are no more
--  permissive than the ones kount_entries and kount_members already carry
--  for `authenticated` (using (true)). Nothing is granted to anon here.
--
--  NOT THE END STATE: venue-scoped policies keyed off app_users.venue_ids are
--  the right shape (the G3 gap flagged in the 2026-09-02 security review).
--  This restores service without widening anything; scoping is a follow-up.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
-- =============================================================================

begin;

-- kount_audits: the audit row must be readable by the authenticated user who
-- just created it, or return=representation can never complete.
drop policy if exists auth_kount_audits_select on public.kount_audits;
create policy auth_kount_audits_select
  on public.kount_audits
  for select
  to authenticated
  using (true);

-- kount_venue_zones: same omission. Without this the phone silently falls back
-- to the hardcoded default zones in venueMap.ts and any counter-added zone
-- disappears from the picker.
drop policy if exists auth_kount_venue_zones_select on public.kount_venue_zones;
create policy auth_kount_venue_zones_select
  on public.kount_venue_zones
  for select
  to authenticated
  using (true);

-- venues: let anon evaluate the vendor policy's predicate instead of erroring.
-- The function is SECURITY DEFINER and returns only the venue ids a vendor may
-- see, so EXECUTE does not itself expose rows — the policy still filters.
grant execute on function public.vendor_visible_venue_ids() to anon;

commit;

-- ── Verification ────────────────────────────────────────────────────────────
-- Expect one row per table, each with cmd = SELECT and roles = {authenticated}:
--
--   select tablename, policyname, cmd, roles::text
--     from pg_policies
--    where schemaname = 'public'
--      and tablename in ('kount_audits','kount_venue_zones')
--      and cmd = 'SELECT';
--
-- Expect anon=X to appear in the ACL:
--
--   select proacl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'vendor_visible_venue_ids';
