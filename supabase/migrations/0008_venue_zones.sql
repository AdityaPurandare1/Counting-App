-- 0008: persist user-added zones at the venue level so they sync across devices.
--
-- Background: zones were originally hardcoded in counting-app.html (one array
-- per venue). Managers could add custom zones via the "+ Zone" button, but
-- those only saved to localStorage on the device that added them — counters
-- and other devices never saw them. This migration introduces a real table
-- so zones round-trip through Supabase like every other entity.

create table if not exists public.kount_venue_zones (
  id          uuid primary key default gen_random_uuid(),
  venue_id    text        not null,
  zone_name   text        not null,
  created_by  text,
  created_at  timestamptz not null default now(),
  unique (venue_id, zone_name)
);

create index if not exists kount_venue_zones_venue_idx
  on public.kount_venue_zones (venue_id);

-- Realtime: emit changes for live multi-device updates.
alter publication supabase_realtime add table public.kount_venue_zones;

-- RLS — match the dev policy used elsewhere in this app (anon access).
-- Tighten when migrating to authenticated-only access.
alter table public.kount_venue_zones enable row level security;

create policy "dev_kount_venue_zones_select"
  on public.kount_venue_zones for select
  to anon using (true);

create policy "dev_kount_venue_zones_insert"
  on public.kount_venue_zones for insert
  to anon with check (true);

create policy "dev_kount_venue_zones_delete"
  on public.kount_venue_zones for delete
  to anon using (true);

-- Note: no UPDATE policy — zones are immutable; rename = delete + insert.
