-- =============================================================================
--  0061_admin_audit_log
--
--  Every admin-lifecycle action (invite, disable, enable, delete, reset
--  password, role/profile change, legacy migration) runs through the
--  admin-user-mgmt Edge Function and, until now, left no queryable trail
--  beyond app_users' own updated_at — no record of WHO changed a role, WHO
--  disabled or deleted a user, or WHEN. This adds an append-only log the
--  function writes to on every completed action.
--
--  Writer: the Edge Function's existing service-role client, which bypasses
--  RLS. There is deliberately no INSERT/UPDATE/DELETE policy and no write
--  grant for anon/authenticated — no client can write or forge a row. The
--  actor recorded is the caller's VERIFIED JWT email (resolved server-side
--  via auth.getUser), never a client-supplied value.
--
--  Reader: authenticated admin/corporate only — the same role pair 0058's
--  compute_avt_for_audit gate uses (`role = any (array['corporate','admin'])`).
--  kount_is_corporate() (0055) is NOT used here: it predates the admin tier
--  and matches 'corporate' only.
--
--  Apply manually (NEVER db push):
--    supabase db query --linked --file supabase/migrations/0061_admin_audit_log.sql
--  Shared DB (KevaOS/Restaurant-App) — this table is isolated and additive.
--  Idempotent.
-- =============================================================================

create table if not exists public.kount_admin_audit_log (
  id           uuid primary key default gen_random_uuid(),
  occurred_at  timestamptz not null default now(),
  actor_email  text not null,
  action       text not null check (action in (
                 'invite', 'disable', 'enable', 'delete',
                 'reset_password', 'update_profile', 'migrate_legacy'
               )),
  target_email text,           -- null only for the migrate_legacy batch summary
  ok           boolean not null,
  details      jsonb,          -- e.g. {"updated_fields": ["role"], "role": "manager"}
  error        text            -- populated when ok = false
);

create index if not exists kount_admin_audit_log_occurred_idx
  on public.kount_admin_audit_log (occurred_at desc);
create index if not exists kount_admin_audit_log_target_idx
  on public.kount_admin_audit_log (target_email, occurred_at desc);

alter table public.kount_admin_audit_log enable row level security;

revoke all on public.kount_admin_audit_log from anon;

drop policy if exists kount_admin_audit_log_select on public.kount_admin_audit_log;
create policy kount_admin_audit_log_select
  on public.kount_admin_audit_log
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

grant select on public.kount_admin_audit_log to authenticated;

-- -----------------------------------------------------------------------------
-- VERIFICATION — run after applying.
-- -----------------------------------------------------------------------------
--   select relrowsecurity from pg_class where relname = 'kount_admin_audit_log';  -- expect t
--   select count(*) from pg_policies where tablename = 'kount_admin_audit_log';   -- expect 1
--   select grantee, privilege_type from information_schema.role_table_grants
--    where table_name = 'kount_admin_audit_log';  -- expect authenticated SELECT only (no anon)
-- After one invite/disable through the Admin app:
--   select actor_email, action, target_email, ok from kount_admin_audit_log
--    order by occurred_at desc limit 5;
