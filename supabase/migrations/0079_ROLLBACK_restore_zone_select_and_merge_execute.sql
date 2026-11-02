-- Rollback for 0079: returns to the state found on 2026-10-13 (both broken).
begin;
drop policy if exists auth_kount_venue_zones_select on public.kount_venue_zones;
revoke execute on function public.merge_master_items(p_winner uuid, p_losers uuid[], p_dry_run boolean) from authenticated;
commit;
