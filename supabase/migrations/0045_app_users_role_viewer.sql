-- 0045_app_users_role_viewer.sql
--
-- Adds an additive read-only role to public.app_users: 'venue_manager'
-- (display label "Venue Management"). Widens the role CHECK constraint from
-- the existing three roles to four. This is purely additive — no existing
-- 'corporate' / 'manager' / 'counter' row is touched.
--
-- NOTE: app_users is SHARED with KevaOS / Restaurant-App. Widening a CHECK
-- (adding an allowed value) is additive and safe for the other consumers —
-- it never invalidates an existing row and never narrows what they may write.
--
-- Idempotent: drops-if-exists then re-adds the constraint with the same name.
-- Apply by hand (NEVER db push):
--   supabase db query --linked --file supabase/migrations/0045_app_users_role_viewer.sql

alter table public.app_users
  drop constraint if exists app_users_role_check;

alter table public.app_users
  add constraint app_users_role_check
  check (role in ('corporate', 'manager', 'counter', 'venue_manager'));

-- Read-back verification (run separately):
-- select conname, pg_get_constraintdef(oid)
--   from pg_constraint
--  where conrelid = 'public.app_users'::regclass and contype = 'c';
-- expect: CHECK ((role = ANY (ARRAY['corporate','manager','counter','venue_manager'])))
