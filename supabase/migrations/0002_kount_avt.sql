-- =============================================================================
--  kΩunt / HWOOD Counting App — AVT (Craftable variance) in Supabase
--  Target: PostgreSQL (Supabase). Run in the SQL editor.
--  Idempotent — safe to re-run.
-- =============================================================================
--
--  Context:
--    AVT (Actual vs Theoretical) data used to live in localStorage on the
--    phone app only. The desktop admin now uploads it once, both apps read
--    it from here. Split into two tables so old reports stay as history:
--
--      kount_avt_reports   — one row per upload (metadata + audit trail)
--      kount_avt_rows      — individual AVT line items, FK'd to the report
--
--    Keeping reports separate means:
--      • admins can see upload history and who uploaded what,
--      • deleting a bad upload is a single DELETE with cascade,
--      • both apps can just pick "latest report per venue" at read time.
-- =============================================================================

create extension if not exists "pgcrypto";


-- -----------------------------------------------------------------------------
-- 1. TABLES
-- -----------------------------------------------------------------------------

create table if not exists public.kount_avt_reports (
  id                 uuid        primary key default gen_random_uuid(),
  uploaded_by_email  text        not null,
  uploaded_by_name   text,
  uploaded_at        timestamptz not null default now(),
  file_name          text,
  row_count          integer     not null default 0,
  venue_ids          text[]      not null default '{}',   -- venues represented in this upload
  notes              text
);

create index if not exists kount_avt_reports_uploaded_idx on public.kount_avt_reports (uploaded_at desc);


create table if not exists public.kount_avt_rows (
  id              uuid          primary key default gen_random_uuid(),
  report_id       uuid          not null references public.kount_avt_reports(id) on delete cascade,
  store           text,                                   -- raw Craftable store label
  venue_id        text          not null,                 -- mapped to ACCESS_LIST venue id (v1..v10)
  venue_name      text,
  item_name       text          not null,
  category        text,
  actual          numeric(14,3),
  theo            numeric(14,3),
  variance        numeric(14,3),
  variance_value  numeric(14,2),
  variance_pct    numeric(10,4),
  cu_price        numeric(14,4),
  start_qty       numeric(14,3),
  purchases       numeric(14,3),
  depletions      numeric(14,3)
);

create index if not exists kount_avt_rows_report_idx    on public.kount_avt_rows (report_id);
create index if not exists kount_avt_rows_venue_idx     on public.kount_avt_rows (venue_id);
create index if not exists kount_avt_rows_report_item   on public.kount_avt_rows (report_id, lower(item_name));


-- -----------------------------------------------------------------------------
-- 2. REALTIME publication
--    Reports get a live feed so the desktop + phone see new uploads instantly.
--    Rows are queried on demand; don't bloat the publication with them.
-- -----------------------------------------------------------------------------
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then
    raise notice 'supabase_realtime publication missing — add kount_avt_reports manually after creating it.';
    return;
  end if;
  begin execute 'alter publication supabase_realtime add table public.kount_avt_reports'; exception when duplicate_object then null; end;
end $$;


-- -----------------------------------------------------------------------------
-- 3. RLS — permissive-dev (matches the rest of the kount_* tables)
-- -----------------------------------------------------------------------------
alter table public.kount_avt_reports enable row level security;
alter table public.kount_avt_rows    enable row level security;

drop policy if exists "dev_kount_avt_reports_select" on public.kount_avt_reports;
create policy "dev_kount_avt_reports_select" on public.kount_avt_reports for select to anon using (true);
drop policy if exists "dev_kount_avt_reports_insert" on public.kount_avt_reports;
create policy "dev_kount_avt_reports_insert" on public.kount_avt_reports for insert to anon with check (true);
drop policy if exists "dev_kount_avt_reports_delete" on public.kount_avt_reports;
create policy "dev_kount_avt_reports_delete" on public.kount_avt_reports for delete to anon using (true);

drop policy if exists "dev_kount_avt_rows_select" on public.kount_avt_rows;
create policy "dev_kount_avt_rows_select" on public.kount_avt_rows for select to anon using (true);
drop policy if exists "dev_kount_avt_rows_insert" on public.kount_avt_rows;
create policy "dev_kount_avt_rows_insert" on public.kount_avt_rows for insert to anon with check (true);


-- -----------------------------------------------------------------------------
-- 4. VERIFICATION
-- -----------------------------------------------------------------------------
-- select relname, relrowsecurity from pg_class where relname in ('kount_avt_reports', 'kount_avt_rows');
-- select tablename from pg_publication_tables where pubname='supabase_realtime' and tablename='kount_avt_reports';
