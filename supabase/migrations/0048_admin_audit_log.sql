-- =============================================================================
--  0048_admin_audit_log
--
--  Every admin-lifecycle action (invite, disable, enable, delete, reset
--  password, role/profile change) runs through the admin-user-mgmt Edge
--  Function and, until now, left no queryable trail beyond app_users'
--  own updated_at — no record of WHO changed a role, WHO disabled or
--  deleted a user, or WHEN. This adds an append-only log the function
--  writes to on every completed action, using its existing service-role
--  client (RLS is bypassed for the writer by design — only the Edge
--  Function is meant to write here, same trust boundary it already has
--  for auth.users).
--
--  Apply manually:
--    supabase db query --linked --file supabase/migrations/0048_admin_audit_log.sql
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

-- No INSERT/UPDATE/DELETE policy for anon or authenticated — the Edge
-- Function writes using the service-role client, which bypasses RLS
-- entirely. This table has no client-writable path by design.

-- SELECT: authenticated corporate users only (mirrors kount_client_errors,
-- 0041), for a future admin viewer / ad-hoc SQL.
drop policy if exists kount_admin_audit_log_select on public.kount_admin_audit_log;
create policy kount_admin_audit_log_select
  on public.kount_admin_audit_log
  for select
  to authenticated
  using (
    exists (
      select 1 from public.app_users
       where lower(email) = lower(coalesce((auth.jwt() ->> 'email'), ''))
         and role = 'corporate'
         and is_active = true
    )
  );

grant select on public.kount_admin_audit_log to authenticated;

-- Verification (after apply):
--   insert into kount_admin_audit_log(actor_email, action, target_email, ok, details)
--     values ('test@hwood.com', 'update_profile', 'someone@hwood.com', true, '{"updated_fields":["role"]}');
--   select * from kount_admin_audit_log order by occurred_at desc limit 1;
--   delete from kount_admin_audit_log where actor_email = 'test@hwood.com';
