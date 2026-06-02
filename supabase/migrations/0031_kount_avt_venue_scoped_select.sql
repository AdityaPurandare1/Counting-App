-- =============================================================================
--  0031_kount_avt_venue_scoped_select
--
--  Tightens SELECT policies on kount_avt_reports + kount_avt_rows to gate by
--  venue. Mirrors the write-side guard in compute_avt_for_audit (0030).
--
--  Background:
--    0002_kount_avt.sql (lines 88-99) created `dev_kount_avt_{reports,rows}_select`
--    `to anon using (true)`, and 0016_extend_dev_policies_to_authenticated.sql
--    (lines 66-67) added `auth_dev_kount_avt_{reports,rows}_select`
--    `to authenticated using (true)`. Result: any signed-in user could SELECT
--    every venue's AVT data. 0030 closed the write side (RPC is gated against
--    app_users.venue_ids) but reads are still wide-open.
--
--  This migration:
--    - Drops the four wide-open SELECT policies (anon + authenticated, on
--      both tables) if they exist. Other policies (insert/delete) are left
--      alone -- writes already flow through compute_avt_for_audit which is
--      SECURITY DEFINER, and uploaded reports come from the admin app (anon).
--    - Creates one new venue-scoped SELECT policy per table, granted to
--      authenticated only:
--        corporate -> see everything
--        manager / counter -> only venues in their app_users.venue_ids
--      app_users.venue_ids is text[] (0003_app_users.sql:30), which matches
--      kount_avt_reports.venue_ids (text[]) and kount_avt_rows.venue_id (text).
--
--  Predicate shape mirrors 0030's compute_avt_for_audit gate exactly
--  (lower(email) + is_active + role='corporate'). Note: app_users.role CHECK
--  constraint only allows 'corporate' / 'manager' / 'counter' (0003:28-29),
--  so there is no 'admin' role to enumerate -- 'corporate' IS the admin tier.
--
--  Re-running is safe: drops use IF EXISTS, creates use drop-then-create.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- kount_avt_reports — drop the four wide-open SELECT policies, add scoped one
-- -----------------------------------------------------------------------------
drop policy if exists "dev_kount_avt_reports_select"      on public.kount_avt_reports;
drop policy if exists "auth_dev_kount_avt_reports_select" on public.kount_avt_reports;

drop policy if exists "venue_scoped_read_kount_avt_reports" on public.kount_avt_reports;
create policy "venue_scoped_read_kount_avt_reports"
  on public.kount_avt_reports
  for select to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and (
           u.role = 'corporate'
           or (kount_avt_reports.venue_ids && u.venue_ids)
         )
    )
  );


-- -----------------------------------------------------------------------------
-- kount_avt_rows — same treatment, predicate uses scalar venue_id = any()
-- -----------------------------------------------------------------------------
drop policy if exists "dev_kount_avt_rows_select"      on public.kount_avt_rows;
drop policy if exists "auth_dev_kount_avt_rows_select" on public.kount_avt_rows;

drop policy if exists "venue_scoped_read_kount_avt_rows" on public.kount_avt_rows;
create policy "venue_scoped_read_kount_avt_rows"
  on public.kount_avt_rows
  for select to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and (
           u.role = 'corporate'
           or (kount_avt_rows.venue_id = any(u.venue_ids))
         )
    )
  );

commit;

-- =============================================================================
-- Verification (run by hand after apply):
--
--   select schemaname, tablename, policyname, roles, cmd, qual
--     from pg_policies
--    where schemaname='public'
--      and tablename in ('kount_avt_reports','kount_avt_rows')
--      and cmd = 'SELECT'
--   order by tablename, policyname;
--   -- Expect exactly one SELECT policy per table, both venue-scoped.
--
--   set request.jwt.claims to '{"email":"apurandare@hwoodgroup.com"}';
--   select count(*) from kount_avt_reports;  -- corporate: sees all
--
--   set request.jwt.claims to '{"email":"<a counter email>"}';
--   select count(*) from kount_avt_reports;  -- counter: subset only
--
--   set request.jwt.claims to '{"email":"nope@example.com"}';
--   select count(*) from kount_avt_reports;  -- unknown: 0
-- =============================================================================
