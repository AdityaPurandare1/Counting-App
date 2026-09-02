-- 0046_clear_avt_on_audit_cancel.sql
--
-- Problem: every report surface (admin Variance/Reports/Stock/Venues + the
-- phone) selects a venue's variance report by (source asc, uploaded_at desc)
-- -- newest computed report wins, REGARDLESS of whether its audit was
-- cancelled. So a barely-counted, then-cancelled audit (e.g. Poppy P-282:
-- ~2 items counted, 290/292 items at actual=0 -> a fake -$214,416 "shrink")
-- overrode the real submitted audit (P-075, +$66,603) and stuck there even
-- after the user cancelled it. Cancelling did nothing because the selector
-- ignores audit status.
--
-- Fix: a cancelled audit must never drive a venue's variance. When an audit
-- transitions to 'cancelled', delete its kount_avt_reports row(s); the rows
-- cascade (kount_avt_rows FK is ON DELETE CASCADE). Every read surface then
-- naturally falls back to the next-newest report for the venue. This is one
-- DB-level guard that covers admin + phone + manual SQL + all future cancels,
-- with no client changes.
--
-- Also a one-time cleanup of the specific junk report (P-282) so Poppy
-- immediately falls back to P-075. The other currently-cancelled-audit report
-- (a different venue, no fallback) is intentionally left untouched here -- only
-- future cancels of it would clear it.
--
-- Idempotent: create-or-replace function, drop-if-exists trigger, guarded
-- one-time delete.

begin;

create or replace function kount_clear_avt_on_cancel()
returns trigger
language plpgsql
as $$
begin
  -- Only act on the active->cancelled transition (not every update of an
  -- already-cancelled row). rows cascade-delete with the report.
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    delete from kount_avt_reports where audit_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_kount_clear_avt_on_cancel on kount_audits;
create trigger trg_kount_clear_avt_on_cancel
  after update of status on kount_audits
  for each row
  execute function kount_clear_avt_on_cancel();

-- One-time cleanup: drop the P-282 junk report (cancelled audit). Scoped by
-- join_code + status so a re-run is a no-op once it's gone.
delete from kount_avt_reports r
  using kount_audits a
  where r.audit_id = a.id
    and a.join_code = 'P-282'
    and a.status = 'cancelled';

commit;

-- ---- verification (run separately, read-only) ----
-- Expect: trigger present; P-282 report gone; v5's newest remaining report is
-- P-075 (+66603).
-- select tgname from pg_trigger where tgname = 'trg_kount_clear_avt_on_cancel';
-- select a.join_code, a.status, round((select sum(variance_value) from kount_avt_rows where report_id=r.id)::numeric,0) net, r.uploaded_at
--   from kount_avt_reports r join kount_audits a on a.id=r.audit_id
--   where r.venue_ids @> array['v5'] order by r.source asc, r.uploaded_at desc limit 3;
