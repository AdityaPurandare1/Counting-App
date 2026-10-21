-- =============================================================================
--  0104_little_luck_cancel_test_audits  (DATA)
--
--  LL-366 (10/17, 2 entries by hjariwala in 4 minutes) and LL-134 (10/18, 0 entries, closed 5 AM) were
--  test audits left 'submitted'; three sibling tests from the same nights (LL-492, LL-673, LL-908) were
--  already cancelled. compute_avt_for_audit chains each window from the previous SUBMITTED audit, so
--  LL-038 -- Little Luck's first real count (472 entries) -- started from LL-134's empty count: every
--  bottle read as found stock, +$78,866 on a $0 expected, in the Overview total from 2026-10-21
--  (0099's missing-report job gave LL-038 its first report). Cancelled here so LL-038 is the venue's
--  opening count and the next Little Luck count compares against it.
--  ROLLBACK: update kount_audits set status = 'submitted' where venue_id = 'v11' and join_code in ('LL-366','LL-134');
--            then recompute LL-038.
-- =============================================================================
begin;
update public.kount_audits set status = 'cancelled'
 where venue_id = 'v11' and join_code in ('LL-366', 'LL-134') and status = 'submitted'
   and (select count(*) from public.kount_entries e where e.audit_id = kount_audits.id) <= 2;
do $$ begin
  if (select count(*) from public.kount_audits where venue_id = 'v11' and join_code in ('LL-366','LL-134') and status = 'cancelled') <> 2 then
    raise exception '0104: expected both test audits cancelled';
  end if;
end $$;
commit;
