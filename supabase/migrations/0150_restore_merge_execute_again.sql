-- =============================================================================
--  0150_restore_merge_execute_again
--
--  2026-11-03: merging catalog duplicates (Haku / Belvedere / Giffard strawberry,
--  found in the barcode check) failed with "permission denied for function
--  merge_master_items" — EXECUTE for authenticated was gone AGAIN (0052 and
--  0079 restored it after earlier sweeps; the KevaOS migration log does not
--  say which change took it this time; 0149's CREATE OR REPLACE keeps ACLs).
--  So Catalog -> Merge duplicates was broken for everyone.
--
--  Safe to grant: the function checks the caller itself (app_users with the
--  admin:catalog permission, 0149) and is SECURITY DEFINER with a fixed
--  search_path.
-- =============================================================================
begin;
grant execute on function public.merge_master_items(p_winner uuid, p_losers uuid[], p_dry_run boolean) to authenticated;
commit;
