-- =============================================================================
--  kΩunt — kount_venues table + seed of v1..v10 (0013)
-- =============================================================================
--  Originally drafted as `public.venues`, but the Supabase project shares
--  schema with another application that already owns a different `venues`
--  table (UUID ids, pos_type, r365_entity_id, etc. — a restaurant-POS
--  schema). Renamed to `kount_venues` to match the naming convention the
--  rest of kΩunt's tables use (kount_audits, kount_entries, kount_members,
--  kount_recounts, kount_avt_*, kount_carried_items, kount_venue_zones,
--  kount_pending_items) and to avoid clobbering the other app's data.
--
--  Until this migration the canonical venue list lived in FOUR hardcoded
--  places — phone counting-app.html appState.venues, admin VENUES const,
--  admin STORE_MAP, admin DEFAULT_VENUE_ZONES — all of which had to be
--  edited in lockstep to add or rename a location. This migration moves
--  the list into Supabase so admin can CRUD venues from the desktop and
--  the phone picks up changes via realtime.
--
--  Existing data integrity:
--    - kount_audits.venue_id, kount_avt_rows.venue_id, app_users.venue_ids,
--      kount_venue_zones.venue_id all already use the same 'v1'..'v10'
--      convention. Nothing changes there — kount_venues.id is the same
--      string, just now writable.
--    - Soft-delete via is_active=false (rather than hard delete) so
--      historic audits can still resolve a venue name even after admin
--      retires the location. The CRUD UI hides inactive venues from
--      "select a venue to start an audit" pickers but keeps showing them
--      on Summary's list of historic audits.
-- =============================================================================

create table if not exists public.kount_venues (
  id            text        primary key,
  name          text        not null,
  address       text,
  default_zones text[]      not null default '{}',
  store_aliases text[]      not null default '{}',
  ordinal       integer     not null default 100,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists kount_venues_active_ordinal_idx
  on public.kount_venues (is_active, ordinal, name);


-- updated_at touch trigger so the admin UI can sort by recency
create or replace function public._set_kount_venues_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists kount_venues_set_updated_at on public.kount_venues;
create trigger kount_venues_set_updated_at
  before update on public.kount_venues
  for each row execute function public._set_kount_venues_updated_at();


-- Realtime so admin CRUD propagates to the phone within a render tick.
do $$ begin
  begin
    execute 'alter publication supabase_realtime add table public.kount_venues';
  exception when duplicate_object then null;
  end;
end $$;


-- Permissive dev-tier RLS — same pattern as the rest of the app's tables.
alter table public.kount_venues enable row level security;

drop policy if exists "dev_kount_venues_select" on public.kount_venues;
create policy "dev_kount_venues_select" on public.kount_venues for select to anon using (true);

drop policy if exists "dev_kount_venues_insert" on public.kount_venues;
create policy "dev_kount_venues_insert" on public.kount_venues for insert to anon with check (true);

drop policy if exists "dev_kount_venues_update" on public.kount_venues;
create policy "dev_kount_venues_update" on public.kount_venues for update to anon using (true) with check (true);

drop policy if exists "dev_kount_venues_delete" on public.kount_venues;
create policy "dev_kount_venues_delete" on public.kount_venues for delete to anon using (true);


-- =============================================================================
-- SEED — v1..v10 from the existing hardcoded data in counting-app.html
-- (line 3689) merged with venueMap.ts STORE_MAP aliases.
--
-- ON CONFLICT DO NOTHING (intentionally — not "do update set"). Once admin
-- starts editing venues via the VenueSettings UI, re-running this seed
-- (e.g. fresh staging clone, CI bootstrap, idempotent migration tool)
-- must NOT silently revert their edits to the values frozen in this file.
-- Trade-off: a fix to a typo in a default_zones list won't propagate via
-- a re-run; admin would have to re-edit through the UI. That's the right
-- direction — the UI is the source of truth once 0013 is live.
-- =============================================================================

insert into public.kount_venues (id, name, address, default_zones, store_aliases, ordinal) values
  ('v1',  'Delilah LA',
          '7969 Santa Monica Blvd, West Hollywood',
          array['Main Bar','Back Bar','Service Bar','Wine Room','Main Fridge','Back Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['delilah la','delilah - la','delilah','delilah los angeles','delilah west hollywood'],
          10),
  ('v2',  'Delilah Miami',
          '2201 Collins Ave, Miami Beach',
          array['Main Bar','Service Bar','Wine Room','Pool Bar','Main Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['delilah miami','delilah - miami','delilah mia','delilah miami beach'],
          20),
  ('v3',  'The Nice Guy',
          '401 N La Cienega Blvd, Los Angeles',
          array['Main Bar','Back Bar','Wine Fridge','Cellar','Main Fridge','Kitchen','Dry Storage','Back Office'],
          array['the nice guy','nice guy','tng'],
          30),
  ('v4',  'The Birdstreet Club',
          '8741 Sunset Blvd, West Hollywood',
          array['Main Bar','Back Bar','Lounge Bar','Wine Cellar','Main Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['bird street','birdstreet','the birdstreet club','birdstreet club','bird street club'],
          40),
  ('v5',  'Poppy',
          '8171 Santa Monica Blvd, West Hollywood',
          array['Main Bar','DJ Booth Bar','VIP Bar','Main Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['poppy'],
          50),
  ('v6',  'Keys',
          'West Hollywood',
          array['Main Bar','Back Bar','Main Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['keys','the keys'],
          60),
  ('v7',  'Bootsy Bellows',
          '9229 Sunset Blvd, West Hollywood',
          array['Main Bar','Back Bar','VIP Bar','Main Fridge','Dry Storage','Back Office'],
          array['bootsy bellows','bootsy'],
          70),
  ('v8',  'The Fleur Room',
          '8430 Sunset Blvd, West Hollywood',
          array['Main Bar','Lounge Bar','Main Fridge','Dry Storage','Back Office'],
          array['the fleur room','fleur room','fleur'],
          80),
  ('v9',  'Harriets',
          '1 Hotel West Hollywood',
          array['Rooftop Bar','Pool Bar','Main Fridge','Dry Storage','Back Office'],
          array['harriets','harriet''s','harriets rooftop'],
          90),
  ('v10', '40 Love',
          '115 N La Cienega Blvd, West Hollywood',
          array['Main Bar','Patio Bar','Main Fridge','Walk-in Cooler','Dry Storage','Back Office'],
          array['40 love','forty love'],
          100)
on conflict (id) do nothing;


-- -----------------------------------------------------------------------------
-- Cleanup note: an earlier draft of this migration used the bare `venues`
-- name. If you ran that draft and got a "column ordinal does not exist"
-- error, the only thing that may have leaked into the *other* app's
-- `venues` table is potentially nothing (the create table if not exists
-- was skipped, the index/seed errored before doing anything). Run this
-- new version on a fresh schema and you'll get the kount_venues table
-- as expected. The other app's `venues` is untouched.
--
-- Verification (run after apply):
--   select id, name, ordinal, is_active, array_length(default_zones, 1) as zone_count
--     from public.kount_venues order by ordinal;
--   -- expect 10 rows v1..v10, ordinals 10..100, all is_active=true
-- -----------------------------------------------------------------------------
