-- 0079_restore_zone_select_and_merge_execute.sql
--
-- Re-applies two grants lost on 2026-10-13 when KevaOS security migrations
-- (520261012200000..520261013400000, most likely the untracked
-- `security_leftovers`) ran against the shared Supabase. Same failure family as
-- the 2026-09 outage that 0051/0052 fixed.
--
-- 1. kount_venue_zones had INSERT + DELETE policies but no SELECT policy, so the
--    phone and admin could add a custom zone and never read it back (the phone
--    silently falls back to the hardcoded default zones). 0051 restored it as
--    USING (true); this time it is scoped to the venues the caller can see,
--    matching 0055's G3 scoping and the intent of the KevaOS lockdown.
-- 2. merge_master_items lost EXECUTE for authenticated, so the admin Catalog
--    "Merge duplicates" panel fails. The function is SECURITY DEFINER and gates
--    itself (corporate-only, raises 42501), so the grant exposes nothing; see
--    0052 group A.
--
-- Idempotent. Rollback: 0079_ROLLBACK_restore_zone_select_and_merge_execute.sql

begin;

drop policy if exists auth_kount_venue_zones_select on public.kount_venue_zones;
create policy auth_kount_venue_zones_select
  on public.kount_venue_zones
  for select
  to authenticated
  using (public.kount_can_see_venue(venue_id));

grant execute on function public.merge_master_items(p_winner uuid, p_losers uuid[], p_dry_run boolean) to authenticated;

commit;

-- ── Verification ────────────────────────────────────────────────────────────
-- Expect zones_select = 1 and merge_exec = true:
-- select (select count(*) from pg_policies where tablename = 'kount_venue_zones' and cmd = 'SELECT') as zones_select,
--        has_function_privilege('authenticated', 'public.merge_master_items(uuid, uuid[], boolean)', 'execute') as merge_exec;
