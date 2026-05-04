-- =============================================================================
--  0014_recount_audit_results
--
--  Adds the "audit result + context" fields to kount_recounts so every
--  recount row records WHY a count was changed or verified, plus which
--  zone the issue was found in. Both are blocking inputs in the recount
--  UI: a manager cannot close the recount until every flagged row has
--  audit_result set ('corrected' or 'verified') and audit_reason filled in.
--
--  Columns are nullable so in-flight audits keep loading; the frontend
--  enforces the not-null requirement on save and on close.
-- =============================================================================

alter table public.kount_recounts
  add column if not exists audit_result text
    check (audit_result in ('corrected', 'verified')),
  add column if not exists audit_reason text,
  add column if not exists zone text,
  add column if not exists category text,
  add column if not exists counter_initials text,
  -- AVT qty variance, snapshotted at closeCount1 so the admin Reports
  -- table doesn't need to re-join against kount_avt_rows. variance_value
  -- already exists for the dollar figure.
  add column if not exists variance_qty numeric(12,2);

-- Index for the admin Reports table — pulls all rows for a venue ordered by
-- audit timestamp.
create index if not exists kount_recounts_audit_zone_idx
  on public.kount_recounts (audit_id, zone, category);
