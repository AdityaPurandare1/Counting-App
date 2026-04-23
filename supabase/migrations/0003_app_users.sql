-- =============================================================================
--  kΩunt / HWOOD Counting App — app_users table + seed
--  Target: PostgreSQL (Supabase). Run in the SQL editor. Idempotent.
-- =============================================================================
--
--  Context:
--    Until now, each app carried its own hardcoded ACCESS_LIST — email →
--    role + venue_ids. Drift risk was high and the admin couldn't manage
--    access without a code push. This migration moves the list into
--    Supabase so both apps share one source of truth and the desktop
--    Security screen can CRUD it live.
--
--  Convention for venue_ids:
--    • role = 'corporate'  → venue_ids is ignored (client treats as "all").
--    • role = 'manager' / 'counter' → venue_ids is the exact allowed set.
--    Empty array on manager/counter means no access.
-- =============================================================================

create extension if not exists "pgcrypto";


-- -----------------------------------------------------------------------------
-- 1. TABLE
-- -----------------------------------------------------------------------------
create table if not exists public.app_users (
  email        text        primary key,
  name         text,
  role         text        not null
                           check (role in ('corporate', 'manager', 'counter')),
  venue_ids    text[]      not null default '{}',
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists app_users_role_idx   on public.app_users (role);
create index if not exists app_users_active_idx on public.app_users (is_active) where is_active = true;


-- -----------------------------------------------------------------------------
-- 2. updated_at trigger
-- -----------------------------------------------------------------------------
create or replace function public.app_users_bump_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists app_users_bump_updated_at_trg on public.app_users;
create trigger app_users_bump_updated_at_trg
  before update on public.app_users
  for each row execute function public.app_users_bump_updated_at();


-- -----------------------------------------------------------------------------
-- 3. REALTIME publication — admins see roster changes live
-- -----------------------------------------------------------------------------
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then return; end if;
  begin execute 'alter publication supabase_realtime add table public.app_users'; exception when duplicate_object then null; end;
end $$;


-- -----------------------------------------------------------------------------
-- 4. RLS — permissive-dev (both apps need SELECT at login; admin page writes)
-- -----------------------------------------------------------------------------
alter table public.app_users enable row level security;

drop policy if exists "dev_app_users_select" on public.app_users;
create policy "dev_app_users_select" on public.app_users for select to anon using (true);

drop policy if exists "dev_app_users_insert" on public.app_users;
create policy "dev_app_users_insert" on public.app_users for insert to anon with check (true);

drop policy if exists "dev_app_users_update" on public.app_users;
create policy "dev_app_users_update" on public.app_users for update to anon using (true) with check (true);

drop policy if exists "dev_app_users_delete" on public.app_users;
create policy "dev_app_users_delete" on public.app_users for delete to anon using (true);


-- -----------------------------------------------------------------------------
-- 5. SEED from the baked-in ACCESS_LIST
--    ON CONFLICT means re-runs are safe and won't clobber edits made through
--    the Security screen. If you want to reset a seed row to defaults, DELETE
--    it via the Security screen first, then re-run this migration.
-- -----------------------------------------------------------------------------
insert into public.app_users (email, name, role, venue_ids) values
  ('admin@hwood.com',    'Admin',     'corporate', '{}'),
  ('ceo@hwood.com',      'CEO',       'corporate', '{}'),
  ('manager1@hwood.com', 'Manager 1', 'manager',   '{v1,v2,v3}'),
  ('manager2@hwood.com', 'Manager 2', 'manager',   '{v4,v5,v6}'),
  ('manager3@hwood.com', 'Manager 3', 'manager',   '{v7,v8,v9,v10}'),
  ('counter1@team.com',  'Counter 1', 'counter',   '{v1,v2}'),
  ('counter2@team.com',  'Counter 2', 'counter',   '{v3,v4}'),
  ('counter3@team.com',  'Counter 3', 'counter',   '{v5,v6}'),
  ('counter4@team.com',  'Counter 4', 'counter',   '{v7,v8}'),
  ('counter5@team.com',  'Counter 5', 'counter',   '{v9,v10}')
on conflict (email) do nothing;


-- -----------------------------------------------------------------------------
-- 6. VERIFICATION
-- -----------------------------------------------------------------------------
-- select email, role, venue_ids, is_active from public.app_users order by role, email;
-- select tablename from pg_publication_tables where pubname='supabase_realtime' and tablename='app_users';
