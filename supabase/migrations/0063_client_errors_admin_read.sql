-- =============================================================================
--  0063_client_errors_admin_read
--
--  kount_client_errors (0041) is readable by active CORPORATE users only — the
--  policy predates the admin tier (above corporate) that Counting-Admin v0.58
--  added, so a platform admin cannot read the error log at all. 0053 rebuilt
--  this table's INSERT policy but deliberately kept the corporate-only SELECT.
--
--  This widens SELECT to admin + corporate (the same role pair 0058's compute
--  gate and 0061's audit log use), for the Counting-Admin "Errors" screen.
--  kount_is_corporate() (0055) is NOT used: it matches 'corporate' only.
--
--  SELECT ONLY. INSERT (0053: authenticated only, anon deliberately excluded)
--  and the absence of UPDATE/DELETE policies are unchanged. anon still has no
--  read path.
--
--  Apply manually (NEVER db push):
--    supabase db query --linked --file supabase/migrations/0063_client_errors_admin_read.sql
--  Shared DB (KevaOS/Restaurant-App) — this table is isolated. Idempotent.
-- =============================================================================

drop policy if exists kount_client_errors_select on public.kount_client_errors;
create policy kount_client_errors_select
  on public.kount_client_errors
  for select
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = any (array['corporate', 'admin'])
    )
  );

-- The viewer filters by time window and app; this keeps those reads cheap as
-- the table grows. (0041 has occurred_at desc and (app, occurred_at desc).)
create index if not exists kount_client_errors_context_idx
  on public.kount_client_errors (context, occurred_at desc);

-- -----------------------------------------------------------------------------
-- VERIFICATION — run after applying.
-- -----------------------------------------------------------------------------
--   select qual from pg_policies
--    where tablename = 'kount_client_errors' and policyname = 'kount_client_errors_select';
--   -- expect: ... role = ANY (ARRAY['corporate','admin']) ...
-- As an admin-tier user (in a rolled-back txn):
--   set local request.jwt.claims = '{"email":"<admin email>"}'; set local role authenticated;
--   select count(*) from kount_client_errors;   -- expect: a real count, not 0
-- As a manager: expect 0 rows.
