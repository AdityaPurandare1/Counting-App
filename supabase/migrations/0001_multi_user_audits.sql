-- =============================================================================
--  kΩunt / HWOOD Counting App — multi-user audit schema + RLS
--  Target: PostgreSQL (Supabase). Run in the SQL editor.
--  Idempotent: safe to re-run; every object uses IF NOT EXISTS / OR REPLACE.
--
--  All new tables are prefixed with `kount_` so they can never collide with
--  pre-existing tables in the project (Bevager/Craftable-imported, etc.).
-- =============================================================================
--
--  This file provisions:
--    1. four new tables      (kount_audits, kount_members, kount_entries,
--                             kount_recounts)
--    2. indexes + unique keys for realtime subscriptions and qty-merge upserts
--    3. realtime publication membership for all audit tables (and upc_mappings)
--    4. a join-code generator helper (generate_kount_join_code)
--    5. RLS policies in two flavors:
--         (A) PERMISSIVE-DEV   — matches today's anon-key + client-side role model
--         (B) AUTH-ENFORCED    — requires Supabase Auth (commented out, flip when ready)
--
--  Before running:
--    - purchase_items must already exist.
--    - upc_mappings must already exist from the previous iteration.
--    - Realtime must be enabled for the project.
--
--  After running, paste the verification queries at the bottom to confirm
--  RLS is on, realtime publication includes the new tables, and the
--  join-code function works.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. EXTENSIONS
-- -----------------------------------------------------------------------------
create extension if not exists "pgcrypto";


-- -----------------------------------------------------------------------------
-- 1. TABLES
-- -----------------------------------------------------------------------------

-- 1a. kount_audits: one row per audit session at a venue.
create table if not exists public.kount_audits (
  id                  uuid        primary key default gen_random_uuid(),
  venue_id            text        not null,                    -- e.g. 'v1' (matches ACCESS_LIST)
  venue_name          text        not null,                    -- denormalized for quick display
  status              text        not null default 'active'
                                  check (status in ('active', 'submitted', 'cancelled')),
  count_phase         text        not null default 'count1'
                                  check (count_phase in ('count1', 'review', 'count2', 'final')),
  join_code           text        not null unique,             -- e.g. 'BSC-482'
  started_by_email    text        not null,
  started_by_name     text,
  started_at          timestamptz not null default now(),
  count1_closed_at    timestamptz,
  count2_closed_at    timestamptz,
  completed_at        timestamptz,
  notes               text
);

create index if not exists kount_audits_venue_status_idx on public.kount_audits (venue_id, status);
create index if not exists kount_audits_join_code_idx    on public.kount_audits (join_code);
create index if not exists kount_audits_active_idx       on public.kount_audits (status) where status = 'active';


-- 1b. kount_members: which users are joined to which audit.
create table if not exists public.kount_members (
  id              uuid        primary key default gen_random_uuid(),
  audit_id        uuid        not null references public.kount_audits(id) on delete cascade,
  user_email      text        not null,
  user_name       text,
  role            text        not null
                              check (role in ('corporate', 'manager', 'counter')),
  assigned_zones  text[]      not null default '{}',
  joined_at       timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  unique (audit_id, user_email)
);

create index if not exists kount_members_audit_idx on public.kount_members (audit_id);
create index if not exists kount_members_email_idx on public.kount_members (user_email);


-- 1c. kount_entries: one row per counted item, per (audit, zone, is_recount).
--     The unique upsert key supports the "merge qty if already counted" rule.
create table if not exists public.kount_entries (
  id                uuid        primary key default gen_random_uuid(),
  audit_id          uuid        not null references public.kount_audits(id) on delete cascade,
  item_id           uuid        references public.purchase_items(id) on delete set null,
  item_name         text        not null,
  category          text,
  qty               numeric(12,2) not null default 0,
  zone              text        not null,
  method            text        check (method in ('barcode','photo','manual','guided','quick','recount') or method is null),
  issue             text        default 'none',
  issue_notes       text,
  sku               text,
  upc               text,
  counted_by_email  text        not null,
  counted_by_name   text,
  is_recount        boolean     not null default false,
  photo_id          text,
  "timestamp"       timestamptz not null default now()
);

-- Enforce "one row per item+zone+phase" so two counters scanning the same
-- bottle in the same zone merge via upsert instead of duplicating.
-- item_id is nullable for custom items; we fall back to lower(item_name).
create unique index if not exists kount_entries_merge_key
  on public.kount_entries (
    audit_id,
    zone,
    coalesce(item_id::text, lower(item_name)),
    is_recount
  );

create index if not exists kount_entries_audit_idx         on public.kount_entries (audit_id);
create index if not exists kount_entries_audit_zone_idx    on public.kount_entries (audit_id, zone);
create index if not exists kount_entries_audit_counter_idx on public.kount_entries (audit_id, counted_by_email);
create index if not exists kount_entries_timestamp_idx     on public.kount_entries (audit_id, "timestamp" desc);


-- 1d. kount_recounts: items flagged for count 2 after close-of-count1.
create table if not exists public.kount_recounts (
  id              uuid        primary key default gen_random_uuid(),
  audit_id        uuid        not null references public.kount_audits(id) on delete cascade,
  item_id         uuid        references public.purchase_items(id) on delete set null,
  item_name       text        not null,
  severity        text        not null
                              check (severity in ('CRITICAL','HIGH','MEDIUM','WATCH','LOW')),
  variance_value  numeric(14,2),
  count1_qty      numeric(12,2),
  count2_qty      numeric(12,2),
  status          text        not null default 'pending'
                              check (status in ('pending','done','dismissed')),
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz
);

create unique index if not exists kount_recounts_item_uniq
  on public.kount_recounts (audit_id, coalesce(item_id::text, lower(item_name)));
create index if not exists kount_recounts_status_idx
  on public.kount_recounts (audit_id, status);


-- -----------------------------------------------------------------------------
-- 2. HELPER: join-code generator
--    Produces `<2-4 letter venue initials>-<3 digit random>`, e.g. 'BSC-482'.
--    Collision-safe: retries up to 16 times on unique-violation.
-- -----------------------------------------------------------------------------
create or replace function public.generate_kount_join_code(p_venue_name text)
returns text
language plpgsql
as $$
declare
  slug     text;
  code     text;
  attempts int := 0;
begin
  -- First letter of each word in venue_name, uppercased, max 3 chars.
  slug := upper(substring(array_to_string(
    (
      select array_agg(left(w, 1))
      from regexp_split_to_table(coalesce(p_venue_name, 'V'), '\s+') as w
      where w ~ '^[A-Za-z]'
    ), ''
  ), 1, 3));
  if slug is null or length(slug) = 0 then slug := 'AUD'; end if;

  loop
    code := slug || '-' || lpad(floor(random() * 1000)::text, 3, '0');
    exit when not exists (select 1 from public.kount_audits where join_code = code);
    attempts := attempts + 1;
    if attempts > 16 then
      raise exception 'could not allocate unique join_code after 16 attempts';
    end if;
  end loop;

  return code;
end;
$$;


-- -----------------------------------------------------------------------------
-- 3. REALTIME PUBLICATION
-- -----------------------------------------------------------------------------
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then
    raise notice 'supabase_realtime publication not found — create it before continuing.';
    return;
  end if;

  begin execute 'alter publication supabase_realtime add table public.kount_audits';   exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.kount_members';  exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.kount_entries';  exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.kount_recounts'; exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.upc_mappings';   exception when duplicate_object then null; end;
end $$;

-- REPLICA IDENTITY FULL so UPDATE events carry the previous row shape.
alter table public.kount_entries replica identity full;
alter table public.kount_members replica identity full;


-- -----------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
--    Enabled on every new table. Permissive-dev policies active now;
--    auth-enforced block is commented and ready to flip.
-- -----------------------------------------------------------------------------
alter table public.kount_audits   enable row level security;
alter table public.kount_members  enable row level security;
alter table public.kount_entries  enable row level security;
alter table public.kount_recounts enable row level security;


-- -----------------------------------------------------------------------------
-- 4A. PERMISSIVE DEV policies — matches today's anon-key + client-side role.
-- -----------------------------------------------------------------------------

-- kount_audits
drop policy if exists "dev_kount_audits_select" on public.kount_audits;
create policy "dev_kount_audits_select" on public.kount_audits for select to anon using (true);
drop policy if exists "dev_kount_audits_insert" on public.kount_audits;
create policy "dev_kount_audits_insert" on public.kount_audits for insert to anon with check (true);
drop policy if exists "dev_kount_audits_update" on public.kount_audits;
create policy "dev_kount_audits_update" on public.kount_audits for update to anon using (true) with check (true);

-- kount_members
drop policy if exists "dev_kount_members_select" on public.kount_members;
create policy "dev_kount_members_select" on public.kount_members for select to anon using (true);
drop policy if exists "dev_kount_members_insert" on public.kount_members;
create policy "dev_kount_members_insert" on public.kount_members for insert to anon with check (true);
drop policy if exists "dev_kount_members_update" on public.kount_members;
create policy "dev_kount_members_update" on public.kount_members for update to anon using (true) with check (true);

-- kount_entries
drop policy if exists "dev_kount_entries_select" on public.kount_entries;
create policy "dev_kount_entries_select" on public.kount_entries for select to anon using (true);
drop policy if exists "dev_kount_entries_insert" on public.kount_entries;
create policy "dev_kount_entries_insert" on public.kount_entries for insert to anon with check (true);
drop policy if exists "dev_kount_entries_update" on public.kount_entries;
create policy "dev_kount_entries_update" on public.kount_entries for update to anon using (true) with check (true);
drop policy if exists "dev_kount_entries_delete" on public.kount_entries;
create policy "dev_kount_entries_delete" on public.kount_entries for delete to anon using (true);

-- kount_recounts
drop policy if exists "dev_kount_recounts_select" on public.kount_recounts;
create policy "dev_kount_recounts_select" on public.kount_recounts for select to anon using (true);
drop policy if exists "dev_kount_recounts_insert" on public.kount_recounts;
create policy "dev_kount_recounts_insert" on public.kount_recounts for insert to anon with check (true);
drop policy if exists "dev_kount_recounts_update" on public.kount_recounts;
create policy "dev_kount_recounts_update" on public.kount_recounts for update to anon using (true) with check (true);

-- purchase_items: anon SELECT was already added in a previous step. We do
-- NOT grant INSERT/UPDATE here — UPC writes go through upc_mappings (and a
-- client-side purchase_items.upc update from linkUPCToItem for the approved
-- paths). Keep RLS enabled on purchase_items with just the anon SELECT.


-- -----------------------------------------------------------------------------
-- 4B. AUTH-ENFORCED policies (commented; flip on when Supabase Auth is wired).
--     Requires an app_users(email, role, venue_ids) table and Supabase Auth
--     sessions so auth.jwt()->>'email' carries the user identity.
-- -----------------------------------------------------------------------------
/*
-- create or replace function public.current_user_email() returns text
-- language sql stable as $$ select auth.jwt() ->> 'email' $$;
--
-- create or replace function public.current_user_role() returns text
-- language sql stable as $$
--   select role from public.app_users where email = public.current_user_email()
-- $$;

-- kount_audits: corporate reads all; manager/counter reads audits they joined
-- or ones where they're a member. Only corporate/manager can insert. Only
-- corporate or the starter can update.
-- create policy "auth_kount_audits_select" on public.kount_audits for select to authenticated using (
--   public.current_user_role() = 'corporate'
--   or started_by_email = public.current_user_email()
--   or exists (select 1 from public.kount_members m where m.audit_id = kount_audits.id and m.user_email = public.current_user_email())
-- );
-- create policy "auth_kount_audits_insert" on public.kount_audits for insert to authenticated with check (
--   public.current_user_role() in ('corporate','manager')
-- );
-- create policy "auth_kount_audits_update" on public.kount_audits for update to authenticated using (
--   public.current_user_role() = 'corporate' or started_by_email = public.current_user_email()
-- );

-- kount_entries: read if member-of-audit, write own entries, corporate full access.
-- create policy "auth_kount_entries_select" on public.kount_entries for select to authenticated using (
--   public.current_user_role() = 'corporate'
--   or exists (select 1 from public.kount_members m where m.audit_id = kount_entries.audit_id and m.user_email = public.current_user_email())
-- );
-- create policy "auth_kount_entries_insert" on public.kount_entries for insert to authenticated with check (
--   counted_by_email = public.current_user_email()
--   and exists (select 1 from public.kount_members m where m.audit_id = kount_entries.audit_id and m.user_email = public.current_user_email())
-- );
-- create policy "auth_kount_entries_update" on public.kount_entries for update to authenticated using (
--   public.current_user_role() = 'corporate' or counted_by_email = public.current_user_email()
-- );
-- create policy "auth_kount_entries_delete" on public.kount_entries for delete to authenticated using (
--   public.current_user_role() = 'corporate'
-- );

-- ...same shape for kount_members and kount_recounts.
*/


-- -----------------------------------------------------------------------------
-- 5. VERIFICATION — run these after the migration and eyeball the output.
-- -----------------------------------------------------------------------------
-- Expected: 4 rows, each with rowsecurity = true
-- select relname, relrowsecurity
--   from pg_class
--  where relname in ('kount_audits','kount_members','kount_entries','kount_recounts');

-- Expected: 5 rows
-- select tablename from pg_publication_tables
--  where pubname = 'supabase_realtime'
--    and tablename in ('kount_audits','kount_members','kount_entries','kount_recounts','upc_mappings');

-- Expected: a handful of 'dev_kount_*' policies per table
-- select tablename, policyname, cmd
--   from pg_policies
--  where tablename in ('kount_audits','kount_members','kount_entries','kount_recounts')
--  order by tablename, policyname;

-- Smoke-test the join-code generator:
-- select public.generate_kount_join_code('Bootsy Bellows');   -- -> BB-xxx
-- select public.generate_kount_join_code('The Nice Guy');     -- -> TNG-xxx
