-- 0048_lock_app_users_writes
--
-- app_users.role is a privilege boundary and must NOT be client-writable.
--
-- Ares security review (2026-07-09): anon + authenticated hold INSERT/UPDATE/
-- DELETE on public.app_users — policies dev_app_users_insert/update +
-- auth_dev_app_users_insert/update (with_check = true), dev_/auth_dev_
-- app_users_delete (no check) — plus full table grants. The public anon key is
-- hardcoded in the shipped phone HTML, so ANYONE can, with one PostgREST call:
--   INSERT app_users {email:'x@evil.com', role:'corporate', is_active:true}
--   -- or UPDATE app_users SET role='corporate' WHERE email='<their login>'
-- then satisfy EVERY corporate gate — merge_master_items (0047),
-- compute_avt_for_audit, import_inventory_csv, and the admin UI role checks.
-- This is the root cause that makes the merge RPC's corporate gate a paper wall.
--
-- SAFE TO LOCK DOWN (verified 2026-07-09):
--  * All legitimate app_users mutations go through the admin-user-mgmt Edge
--    Function (supabase/functions/admin-user-mgmt/index.ts), which validates the
--    caller is an ACTIVE corporate app_user and then writes with the SERVICE_ROLE
--    key. service_role BYPASSES RLS and is NOT affected by anon/authenticated
--    grant or policy changes — so invite/disable/enable/update/delete keep working.
--  * KevaOS / Restaurant-App does NOT touch app_users (zero references) — blast
--    radius is Counting-App + Counting-Admin only.
--  * SELECT is intentionally LEFT OPEN (policies dev_/auth_dev_app_users_select +
--    grant) so the phone/admin can still read roles.
--
-- Apply via `supabase db query --linked` (never db push). Idempotent.
-- ROLLBACK (only if the Edge Function path were ever lost — NOT recommended):
--   grant insert, update, delete on public.app_users to anon, authenticated;
--   -- and recreate the dropped policies from git history.

alter table public.app_users enable row level security;

drop policy if exists dev_app_users_insert     on public.app_users;
drop policy if exists dev_app_users_update      on public.app_users;
drop policy if exists dev_app_users_delete      on public.app_users;
drop policy if exists auth_dev_app_users_insert on public.app_users;
drop policy if exists auth_dev_app_users_update on public.app_users;
drop policy if exists auth_dev_app_users_delete on public.app_users;

revoke insert, update, delete on public.app_users from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
-- 1. Only SELECT policies remain:
--      select policyname, cmd, roles::text from pg_policies
--       where tablename='app_users' order by cmd;   -- expect SELECT rows only
-- 2. anon/authenticated no longer hold write privileges:
--      select grantee, privilege_type from information_schema.role_table_grants
--       where table_name='app_users' and grantee in ('anon','authenticated')
--       order by grantee, privilege_type;            -- expect NO INSERT/UPDATE/DELETE
-- 3. Negative test — a raw anon PostgREST INSERT/UPDATE to app_users must now
--    return 401/403 (RLS/permission denied), where before it succeeded.
-- 4. Regression — the admin Security screen can still invite / disable / enable /
--    update-profile / delete a user (Edge Function → service_role path), unchanged.
