-- =============================================================================
--  0112_lady_delilah_cancel_test_audit  (DATA)
--
--  LD-410 (Lady Delilah, v14) was a test count: 3 entries in two minutes by
--  hjariwala on 10/26 (-196 Vodka Seltzer, Campari x2), left 'submitted'.
--  compute_avt_for_audit chains each count's window from the previous
--  SUBMITTED count, so Lady Delilah's first real count would start from this
--  near-empty test and read every bottle as found stock -- exactly what
--  happened to Little Luck's LL-038 (+$78,866, fixed by 0104). Cancelled so
--  the first real count is Lady Delilah's opening count.
--  ROLLBACK: update kount_audits set status = 'submitted' where venue_id = 'v14' and join_code = 'LD-410';
-- =============================================================================
begin;
update public.kount_audits set status = 'cancelled'
 where venue_id = 'v14' and join_code = 'LD-410' and status = 'submitted'
   and (select count(*) from public.kount_entries e where e.audit_id = kount_audits.id) <= 3;
do $$ begin
  if (select status from public.kount_audits where join_code = 'LD-410') <> 'cancelled' then
    raise exception '0112: LD-410 was not cancelled';
  end if;
end $$;
select join_code, status from public.kount_audits where venue_id = 'v14';
commit;
