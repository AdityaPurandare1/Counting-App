-- =============================================================================
--  0087_reopen_ll038   (DATA)  -- reopen Little Luck audit LL-038 at Aditya's request
--
--  LL-038 (2de57200-ee0d-43d6-8dfe-8dd6a5126831) was finalized from Count 1
--  (count1_closed_at 2026-10-18 20:02, count2_closed_at NULL, completed_at
--  2026-10-19 17:27, phase 'final'). 210 entries, 0 recounts. No other active
--  Little Luck audit exists, so the LL-038 join code is unambiguous again.
--
--  Back to status 'active', phase 'count1', so counters can join with the same
--  code and keep counting. All 210 entries are kept.
--
--  count1_closed_at MUST be cleared, not just the status: the close path only
--  stamps it when null (`if (!audit.count1ClosedAt) ...`), and
--  compute_avt_for_audit ends its window at coalesce(count2_closed_at,
--  completed_at, count1_closed_at). Leaving the 10/18 stamp would make the next
--  close reuse it and silently drop every sale after 10/18 20:02 from variance.
--
--  The computed AVT report is removed: a reopened audit has no final variance,
--  and leaving it would show as Little Luck's latest report. Same precedent as
--  0046 (clear AVT on cancel). It is derived data -- compute_avt_for_audit
--  regenerates it on the next close.
-- =============================================================================
begin;

delete from public.kount_avt_rows
 where report_id in (select id from public.kount_avt_reports
                      where audit_id = '2de57200-ee0d-43d6-8dfe-8dd6a5126831' and source = 'computed');
delete from public.kount_avt_reports
 where audit_id = '2de57200-ee0d-43d6-8dfe-8dd6a5126831' and source = 'computed';

update public.kount_audits
   set status = 'active', count_phase = 'count1',
       count1_closed_at = null, count2_closed_at = null, completed_at = null
 where id = '2de57200-ee0d-43d6-8dfe-8dd6a5126831'
   and join_code = 'LL-038';

select join_code, status, count_phase, count1_closed_at, completed_at,
       (select count(*) from public.kount_entries where audit_id = a.id) entries,
       (select count(*) from public.kount_avt_reports where audit_id = a.id) avt_reports,
       (select count(*) from public.kount_audits where venue_id = 'v11' and status = 'active') v11_active
  from public.kount_audits a where id = '2de57200-ee0d-43d6-8dfe-8dd6a5126831';

commit;
