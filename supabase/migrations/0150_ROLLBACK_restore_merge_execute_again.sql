-- ROLLBACK for 0150: take EXECUTE back (Catalog -> Merge duplicates stops working).
begin;
revoke execute on function public.merge_master_items(p_winner uuid, p_losers uuid[], p_dry_run boolean) from authenticated;
commit;
