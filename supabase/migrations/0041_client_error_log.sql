-- =============================================================================
--  0041_client_error_log
--
--  Lightweight client-side error telemetry. Both clients (phone PWA + admin SPA)
--  best-effort INSERT here from a global error handler + key catch points, so we
--  have *some* visibility into prod failures (there was none before). No external
--  SaaS — just a table the existing anon Supabase client can write to.
--
--  Privacy/volume: clients truncate message/stack and throttle+dedupe before
--  sending, so this is not a firehose and holds no secrets. anon may INSERT only
--  (never SELECT — an error row could echo back operational context). Reads are
--  limited to authenticated corporate users (for a future admin viewer / ad-hoc
--  SQL); everyone else is blocked by RLS.
--
--  Apply manually:
--    supabase db query --linked --file supabase/migrations/0041_client_error_log.sql
--  Shared DB (KevaOS/Restaurant-App) — this table is isolated and additive.
--  Idempotent.
-- =============================================================================

create table if not exists public.kount_client_errors (
  id           uuid primary key default gen_random_uuid(),
  occurred_at  timestamptz not null default now(),
  app          text not null check (app in ('phone','admin')),
  app_version  text,
  level        text not null default 'error' check (level in ('error','warn')),
  context      text,            -- where it happened (e.g. 'syncEntryToSupabase')
  message      text,            -- truncated client-side
  stack        text,            -- truncated client-side
  url          text,
  user_email   text,
  venue_id     text,
  user_agent   text
);

create index if not exists kount_client_errors_occurred_idx
  on public.kount_client_errors (occurred_at desc);
create index if not exists kount_client_errors_app_idx
  on public.kount_client_errors (app, occurred_at desc);

alter table public.kount_client_errors enable row level security;

-- INSERT: anyone (anon + authenticated) may log. WITH CHECK constrains the row
-- to this table's purpose; the check (app in ...) is enforced by the column
-- constraint too. No USING clause (USING doesn't apply to INSERT).
drop policy if exists kount_client_errors_insert on public.kount_client_errors;
create policy kount_client_errors_insert
  on public.kount_client_errors
  for insert
  to anon, authenticated
  with check (true);

-- SELECT: authenticated corporate users only (for a future admin viewer / SQL).
drop policy if exists kount_client_errors_select on public.kount_client_errors;
create policy kount_client_errors_select
  on public.kount_client_errors
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

grant insert on public.kount_client_errors to anon, authenticated;
grant select on public.kount_client_errors to authenticated;

-- Verification (after apply):
--   insert into kount_client_errors(app,app_version,context,message)
--     values ('phone','0041-test','migration','hello');  -- expect 1 row
--   select count(*) from kount_client_errors;             -- corporate only
--   delete from kount_client_errors where app_version='0041-test';
