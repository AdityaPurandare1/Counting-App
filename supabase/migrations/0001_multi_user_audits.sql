-- =============================================================================
--  kΩunt / HWOOD Counting App — multi-user audit schema + RLS
--  Target: PostgreSQL (Supabase). Run in the SQL editor.
--  Idempotent: safe to re-run; every object uses IF NOT EXISTS / OR REPLACE.
-- =============================================================================
--
--  This file provisions:
--    1. four new tables      (audits, audit_members, count_entries, audit_recounts)
--    2. indexes + unique keys for realtime subscriptions and qty-merge upserts
--    3. realtime publication membership for all audit tables (and upc_mappings)
--    4. a join-code generator helper
--    5. RLS policies in two flavors:
--         (A) PERMISSIVE-DEV   — matches today's anon-key + client-side role model
--         (B) AUTH-ENFORCED    — requires Supabase Auth (commented out, flip when ready)
--
--  Before running:
--    - purchase_items must already exist with the columns named in the spec.
--    - upc_mappings must already exist from the previous iteration.
--    - Realtime must be enabled for the project (it is, since upc_mappings
--      was added in the last session).
--
--  After running:
--    - Run the final verification block at the bottom to confirm RLS + realtime.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. EXTENSIONS (pgcrypto for gen_random_uuid; usually already enabled)
-- -----------------------------------------------------------------------------
create extension if not exists "pgcrypto";


-- -----------------------------------------------------------------------------
-- 1. TABLES
-- -----------------------------------------------------------------------------

-- 1a. audits: one row per audit session at a venue.
create table if not exists public.audits (
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

create index if not exists audits_venue_status_idx    on public.audits (venue_id, status);
create index if not exists audits_join_code_idx       on public.audits (join_code);
create index if not exists audits_active_idx          on public.audits (status) where status = 'active';


-- 1b. audit_members: which users are joined to which audit.
create table if not exists public.audit_members (
  id              uuid        primary key default gen_random_uuid(),
  audit_id        uuid        not null references public.audits(id) on delete cascade,
  user_email      text        not null,
  user_name       text,
  role            text        not null
                              check (role in ('corporate', 'manager', 'counter')),
  assigned_zones  text[]      not null default '{}',           -- optional zone-scoping
  joined_at       timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),          -- for live-presence indicator
  unique (audit_id, user_email)
);

create index if not exists audit_members_audit_idx  on public.audit_members (audit_id);
create index if not exists audit_members_email_idx  on public.audit_members (user_email);


-- 1c. count_entries: one row per counted item (per audit, zone, is_recount).
--     The unique upsert key supports the "merge qty if already counted" rule.
create table if not exists public.count_entries (
  id                uuid        primary key default gen_random_uuid(),
  audit_id          uuid        not null references public.audits(id) on delete cascade,
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
  photo_id          text,                                        -- optional ref to local IndexedDB blob
  "timestamp"       timestamptz not null default now()
);

-- Enforce the "one row per item+zone+phase" so two counters scanning the same
-- bottle in the same zone merge via upsert (ON CONFLICT ... DO UPDATE).
-- item_id is nullable for custom items; we fall back to item_name for those.
create unique index if not exists count_entries_merge_key
  on public.count_entries (
    audit_id,
    zone,
    coalesce(item_id::text, lower(item_name)),
    is_recount
  );

create index if not exists count_entries_audit_idx        on public.count_entries (audit_id);
create index if not exists count_entries_audit_zone_idx   on public.count_entries (audit_id, zone);
create index if not exists count_entries_audit_counter_idx on public.count_entries (audit_id, counted_by_email);
create index if not exists count_entries_timestamp_idx    on public.count_entries (audit_id, "timestamp" desc);


-- 1d. audit_recounts: items flagged for count 2 after close-of-count1.
create table if not exists public.audit_recounts (
  id              uuid        primary key default gen_random_uuid(),
  audit_id        uuid        not null references public.audits(id) on delete cascade,
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

create unique index if not exists audit_recounts_item_uniq
  on public.audit_recounts (audit_id, coalesce(item_id::text, lower(item_name)));
create index if not exists audit_recounts_status_idx
  on public.audit_recounts (audit_id, status);


-- -----------------------------------------------------------------------------
-- 2. HELPER: join-code generator
--    Produces a 3-letter venue slug + '-' + 3-digit random number, e.g. 'BSC-482'.
--    The venue slug is derived from the first letters of each word in venue_name.
--    Collision-safe: re-tries up to 16 times before surfacing a clean error.
-- -----------------------------------------------------------------------------
create or replace function public.generate_audit_join_code(p_venue_name text)
returns text
language plpgsql
as $$
declare
  slug     text;
  code     text;
  attempts int := 0;
begin
  -- first letter of each word, uppercased, 2-4 chars
  slug := upper(substring(
    regexp_replace(coalesce(p_venue_name, 'V'), '[^A-Za-z ]', '', 'g'),
    '^[A-Za-z]'
  ));
  -- richer slug: first letter of each word
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
    exit when not exists (select 1 from public.audits where join_code = code);
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
--    Add all audit tables to the supabase_realtime publication so the JS SDK
--    gets postgres_changes events on INSERT/UPDATE/DELETE.
-- -----------------------------------------------------------------------------
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then
    raise notice 'supabase_realtime publication not found — create it before continuing.';
    return;
  end if;

  -- add tables (ignore if already present)
  begin execute 'alter publication supabase_realtime add table public.audits';          exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.audit_members';   exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.count_entries';   exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.audit_recounts';  exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.upc_mappings';    exception when duplicate_object then null; end;
end $$;

-- Standard REPLICA IDENTITY is fine for INSERT/DELETE; bump to FULL if you need
-- the previous row shape on UPDATE events (realtime carries both new and old).
alter table public.count_entries replica identity full;
alter table public.audit_members replica identity full;


-- -----------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
--    We enable RLS on every new table. Two policy flavors are included below.
--    Pick ONE flavor by uncommenting the block you want; leave the other off.
-- -----------------------------------------------------------------------------
alter table public.audits          enable row level security;
alter table public.audit_members   enable row level security;
alter table public.count_entries   enable row level security;
alter table public.audit_recounts  enable row level security;


-- -----------------------------------------------------------------------------
-- 4A. PERMISSIVE DEV policies — matches today's anon-key + client-side role.
--     Security model: the client decides who can do what. The DB only
--     guarantees "some request came in with a valid anon key". Role
--     enforcement is honor-system. Fine for an internal tool; trivial to
--     spoof with curl. Intended to get multi-user audits working end-to-end
--     before layering real auth.
-- -----------------------------------------------------------------------------

-- audits: anon can read + insert; only the starter or a corporate user
-- should update/delete. Without real identity we can't enforce "starter"
-- here, so we allow update/delete for any anon. Flip to auth-enforced
-- policies below before going to production.
drop policy if exists "dev_audits_select" on public.audits;
create policy "dev_audits_select" on public.audits for select  to anon using (true);

drop policy if exists "dev_audits_insert" on public.audits;
create policy "dev_audits_insert" on public.audits for insert  to anon with check (true);

drop policy if exists "dev_audits_update" on public.audits;
create policy "dev_audits_update" on public.audits for update  to anon using (true) with check (true);

-- audit_members
drop policy if exists "dev_audit_members_select" on public.audit_members;
create policy "dev_audit_members_select" on public.audit_members for select to anon using (true);

drop policy if exists "dev_audit_members_insert" on public.audit_members;
create policy "dev_audit_members_insert" on public.audit_members for insert to anon with check (true);

drop policy if exists "dev_audit_members_update" on public.audit_members;
create policy "dev_audit_members_update" on public.audit_members for update to anon using (true) with check (true);

-- count_entries: every role can insert/update. Realtime fan-out handles
-- the "every phone sees every entry" behavior once subscribed.
drop policy if exists "dev_count_entries_select" on public.count_entries;
create policy "dev_count_entries_select" on public.count_entries for select to anon using (true);

drop policy if exists "dev_count_entries_insert" on public.count_entries;
create policy "dev_count_entries_insert" on public.count_entries for insert to anon with check (true);

drop policy if exists "dev_count_entries_update" on public.count_entries;
create policy "dev_count_entries_update" on public.count_entries for update to anon using (true) with check (true);

drop policy if exists "dev_count_entries_delete" on public.count_entries;
create policy "dev_count_entries_delete" on public.count_entries for delete to anon using (true);

-- audit_recounts
drop policy if exists "dev_audit_recounts_select" on public.audit_recounts;
create policy "dev_audit_recounts_select" on public.audit_recounts for select to anon using (true);

drop policy if exists "dev_audit_recounts_insert" on public.audit_recounts;
create policy "dev_audit_recounts_insert" on public.audit_recounts for insert to anon with check (true);

drop policy if exists "dev_audit_recounts_update" on public.audit_recounts;
create policy "dev_audit_recounts_update" on public.audit_recounts for update to anon using (true) with check (true);

-- purchase_items: anon SELECT was already added in a previous step. We do
-- NOT grant INSERT/UPDATE here — the UPC write path goes through
-- upc_mappings (auto-approved via trigger) or a service-role edge function.
-- If you disabled RLS to test uploads, re-enable it:
--   alter table public.purchase_items enable row level security;
-- and keep only the anon SELECT policy you already added.


-- -----------------------------------------------------------------------------
-- 4B. AUTH-ENFORCED policies (COMMENTED OUT until Supabase Auth is wired up).
--     Requires the app to sign users in with Supabase Auth (magic link,
--     OAuth, or JWT from your own issuer). auth.jwt()->>'email' carries the
--     user's identity; role lookup is via a users_roles table you maintain.
--     Uncomment this whole block and drop the 4A policies when ready.
-- -----------------------------------------------------------------------------
/*
-- First, you need a mapping of email -> role in the DB (replaces ACCESS_LIST
-- baked into the app). Example table:
--
--   create table public.app_users (
--     email      text primary key,
--     display_name text,
--     role       text not null check (role in ('corporate','manager','counter')),
--     venue_ids  text[] not null default '{}'   -- 'all' not supported here; expand in code
--   );
--
-- Then:
--
-- create or replace function public.current_user_email() returns text
-- language sql stable as $$ select auth.jwt() ->> 'email' $$;
--
-- create or replace function public.current_user_role() returns text
-- language sql stable as $$
--   select role from public.app_users where email = public.current_user_email()
-- $$;

-- audits: corporate reads all; manager reads audits for assigned venues + ones they started;
-- counter reads only audits they're a member of.
-- drop policy if exists "auth_audits_select" on public.audits;
-- create policy "auth_audits_select" on public.audits for select to authenticated using (
--   public.current_user_role() = 'corporate'
--   or started_by_email = public.current_user_email()
--   or exists (select 1 from public.audit_members m
--              where m.audit_id = audits.id and m.user_email = public.current_user_email())
-- );

-- audits: only corporate or a manager can start an audit (insert).
-- create policy "auth_audits_insert" on public.audits for insert to authenticated with check (
--   public.current_user_role() in ('corporate','manager')
-- );

-- audits: only corporate or the starter can update phase/status/notes.
-- create policy "auth_audits_update" on public.audits for update to authenticated using (
--   public.current_user_role() = 'corporate' or started_by_email = public.current_user_email()
-- );

-- count_entries: member-of-audit read, self-write, corporate can adjust anything.
-- create policy "auth_ce_select" on public.count_entries for select to authenticated using (
--   public.current_user_role() = 'corporate'
--   or exists (select 1 from public.audit_members m
--              where m.audit_id = count_entries.audit_id
--                and m.user_email = public.current_user_email())
-- );
-- create policy "auth_ce_insert" on public.count_entries for insert to authenticated with check (
--   counted_by_email = public.current_user_email()
--   and exists (select 1 from public.audit_members m
--               where m.audit_id = count_entries.audit_id
--                 and m.user_email = public.current_user_email())
-- );
-- create policy "auth_ce_update" on public.count_entries for update to authenticated using (
--   public.current_user_role() = 'corporate'
--   or counted_by_email = public.current_user_email()
-- );
-- create policy "auth_ce_delete" on public.count_entries for delete to authenticated using (
--   public.current_user_role() = 'corporate'
-- );

-- ...similar pattern for audit_members and audit_recounts.
*/


-- -----------------------------------------------------------------------------
-- 5. VERIFICATION — run these after the migration and eyeball the output.
-- -----------------------------------------------------------------------------
-- Expected: 4 rows, each with rowsecurity = true
-- select relname, relrowsecurity
--   from pg_class
--  where relname in ('audits','audit_members','count_entries','audit_recounts');

-- Expected: all 5 tables listed
-- select schemaname, tablename from pg_publication_tables
--  where pubname = 'supabase_realtime'
--    and tablename in ('audits','audit_members','count_entries','audit_recounts','upc_mappings');

-- Expected: a handful of 'dev_*' policies per table
-- select tablename, policyname, cmd
--   from pg_policies
--  where tablename in ('audits','audit_members','count_entries','audit_recounts')
--  order by tablename, policyname;

-- Smoke-test the join-code generator:
-- select public.generate_audit_join_code('Bootsy Bellows');   -- -> BB-xxx
-- select public.generate_audit_join_code('The Nice Guy');     -- -> TNG-xxx
