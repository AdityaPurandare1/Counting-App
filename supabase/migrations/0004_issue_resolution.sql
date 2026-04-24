-- =============================================================================
--  kΩunt — add issue-resolution columns to kount_entries (0004)
--  Target: PostgreSQL (Supabase). Idempotent — safe to re-run.
-- =============================================================================
--
--  Supports the "mark issue resolved" action shipped in desktop v0.11 +
--  phone v1.10. An issue on a count entry (e.g. 'no-sticker', 'damaged')
--  stays open until an admin or the counter marks it resolved; the
--  resolution trail is stored on the row itself so we don't need a
--  separate issue_resolutions table.
-- =============================================================================

alter table public.kount_entries
  add column if not exists issue_resolved    boolean     not null default false;

alter table public.kount_entries
  add column if not exists issue_resolved_by text;

alter table public.kount_entries
  add column if not exists issue_resolved_at timestamptz;

create index if not exists kount_entries_open_issues_idx
  on public.kount_entries (audit_id)
  where issue is not null and issue <> 'none' and issue_resolved = false;

-- Verification:
-- select column_name from information_schema.columns
--  where table_schema='public' and table_name='kount_entries' and column_name like 'issue%';
