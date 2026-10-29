-- =============================================================================
--  0119_recompute_poppy_recount_corrections   (DATA: recompute 6 reports)
--
--  After 0118 linked the recount rows, six submitted Poppy counts are
--  recomputed so their final variance includes the managers' "Count Corrected"
--  results. These six were chosen because a recompute changes them by the
--  corrections alone (dry run, 2026-10-28; net variance effect):
--    P-000 10/18 -$1,173 | P-706 8/30 +$5 | P-330 8/23 -$867
--    P-340 8/16 +$453    | P-328 8/9 +$115 | P-281 8/2 +$303
--  Left alone on purpose: Poppy P-373 (9/20) and P-320 (10/4), which a plain
--  recompute moves by thousands for reasons other than recounts (to be looked
--  into first), and audits with no report yet.
--
--  ROLLBACK: none in SQL. compute_avt_for_audit deletes and re-inserts the
--  report; the previous numbers are listed above for reference, and the
--  0118 rollback plus another recompute restores pre-correction figures.
-- =============================================================================
begin;

do $$
declare
  v_ids uuid[];
  v_id  uuid;
begin
  select array_agg(a.id) into v_ids
    from public.kount_audits a
   where a.venue_name = 'Poppy'
     and a.status = 'submitted'
     and (a.join_code, to_char(a.started_at at time zone 'America/Los_Angeles', 'YYYY-MM-DD')) in (
           ('P-000', '2026-10-18'), ('P-706', '2026-08-30'), ('P-330', '2026-08-23'),
           ('P-340', '2026-08-16'), ('P-328', '2026-08-09'), ('P-281', '2026-08-02'));
  if coalesce(array_length(v_ids, 1), 0) <> 6 then
    raise exception '0119: expected 6 Poppy audits, found %', coalesce(array_length(v_ids, 1), 0);
  end if;
  foreach v_id in array v_ids loop
    perform public.compute_avt_for_audit(v_id);
  end loop;
end $$;

-- Check: each audit's new net variance.
select a.join_code,
       to_char(a.started_at at time zone 'America/Los_Angeles', 'YYYY-MM-DD') as started,
       round(sum(x.variance_value), 0) as net_variance
  from public.kount_audits a
  join public.kount_avt_reports p on p.audit_id = a.id
  join public.kount_avt_rows x on x.report_id = p.id
 where a.venue_name = 'Poppy'
   and a.join_code in ('P-000', 'P-706', 'P-330', 'P-340', 'P-328', 'P-281')
   and a.status = 'submitted'
 group by 1, 2
 order by 2 desc;

commit;
