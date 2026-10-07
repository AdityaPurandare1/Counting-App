-- =============================================================================
--  0063_admin_audit_log
--
--  Ported from hursh-dev 0048_admin_audit_log (3cdc081, Harsh Jariwala),
--  renumbered (0048 is taken by lock_app_users_writes).
--
--  Every user-lifecycle action (invite, disable, enable, delete, reset
--  password, role/profile change, legacy migration) runs through the
--  admin-user-mgmt Edge Function and left no queryable trail beyond
--  app_users.updated_at — nothing recorded WHO changed a role or removed a
--  user, or WHEN. The function now appends a row here after each completed
--  action, using its service-role client (RLS bypassed; there is deliberately
--  no client-writable path).
--
--  CHANGED FROM THE BRANCH VERSION
--    SELECT is limited to role = 'admin' — the tier that can perform these
--    actions (canManageUsers, admin-user-mgmt's caller check) — instead of
--    corporate, which no longer manages users.
--
--  Additive and idempotent. Must be applied BEFORE the Edge Function that
--  writes to it is deployed (the writes are best-effort, so applying late
--  only loses rows — it never blocks an action).
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

revoke all on public.kount_admin_audit_log from anon, authenticated;

drop policy if exists kount_admin_audit_log_select on public.kount_admin_audit_log;
create policy kount_admin_audit_log_select
  on public.kount_admin_audit_log
  for select
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'admin'
         and u.is_active = true
    )
  );

grant select on public.kount_admin_audit_log to authenticated;

-- VERIFICATION
--   select relrowsecurity from pg_class where relname = 'kount_admin_audit_log';   -- true
--   select count(*) from information_schema.role_table_grants
--    where table_name = 'kount_admin_audit_log' and grantee = 'anon';               -- 0
