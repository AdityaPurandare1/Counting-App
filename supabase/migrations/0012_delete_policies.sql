-- =============================================================================
--  kΩunt — anon DELETE policies for kount_audits + cascade children (0012)
-- =============================================================================
--  When migration 0001 set up dev-tier RLS it created select/insert/update
--  policies for the anon role on kount_audits, kount_members, kount_recounts,
--  but the DELETE policy was only added on kount_entries (0001 line 244).
--  RLS-enabled tables with no matching DELETE policy silently filter all
--  rows out of a DELETE — PostgREST returns 204 with zero rows affected,
--  no error, and the admin app's "Delete audit" button appears to do
--  nothing. Same failure mode as the historic purchase_items.upc PATCH
--  bug we fixed via the approve_upc_mapping RPC.
--
--  Two layers of fix needed:
--    1. kount_audits — the actual DELETE the admin clicks. Without this
--       policy, anon never gets past the parent row.
--    2. kount_members / kount_recounts — children of kount_audits with
--       `on delete cascade`. PostgreSQL applies RLS to the cascading
--       deletes as well; without DELETE policies on the children, the
--       cascade itself would be blocked even after fix 1 lands.
--
--  Both fixes are dev-tier permissive (`using (true)`) — same convention
--  the existing kount_entries delete policy uses. When the app moves to
--  authenticated auth, these get replaced by per-venue-scoped policies
--  along the lines commented out in 0001 (lines 277-310).
-- =============================================================================

-- 1. kount_audits — primary fix.
drop policy if exists "dev_kount_audits_delete" on public.kount_audits;
create policy "dev_kount_audits_delete"
  on public.kount_audits for delete to anon using (true);

-- 2. kount_members — needed for cascade from kount_audits delete.
drop policy if exists "dev_kount_members_delete" on public.kount_members;
create policy "dev_kount_members_delete"
  on public.kount_members for delete to anon using (true);

-- 3. kount_recounts — same reason.
drop policy if exists "dev_kount_recounts_delete" on public.kount_recounts;
create policy "dev_kount_recounts_delete"
  on public.kount_recounts for delete to anon using (true);


-- -----------------------------------------------------------------------------
-- Verification (run after apply):
--   select policyname from pg_policies
--    where schemaname='public'
--      and tablename in ('kount_audits','kount_members','kount_recounts')
--    order by tablename, policyname;
--   -- should list dev_<table>_(select|insert|update|delete) for each
--
-- Smoke test (corporate user, on a test cancelled audit):
--   delete from public.kount_audits where id = '<test_uuid>'
--     returning id;
--   -- should return one row (the deleted id), not empty
-- -----------------------------------------------------------------------------
