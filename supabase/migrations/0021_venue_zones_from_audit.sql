-- =============================================================================
--  0021_venue_zones_from_audit
--
--  Replaces the boilerplate kount_venues.default_zones for the 6 active
--  venues with their real per-venue zone lists, sourced from
--  Bar_Items_Master_By_Venue_Location.xlsx (2026-05-14 inventory audit
--  export). Also deactivates v7 (Bootsy Bellows) and v9 (Harriets) since
--  those venues don't exist anymore; v8/v10 were already inactive.
--
--  Background:
--  -----------
--  Today's default_zones are generic strings ("Main Bar / Back Bar /
--  Walk-in Cooler / Dry Storage") that don't match the actual layout of
--  any venue. Counters end up typing custom zones on the fly which:
--    - bypasses validation
--    - causes drift between venues (slightly different spellings)
--    - makes per-zone curation impossible
--
--  The XLSX provided by the user has every venue's real zones based on
--  current stocked inventory. Zones are normalized for casing (1St -> 1st)
--  and obvious truncations (Frid -> Fridge, Backba -> Backbar, Liqrm ->
--  Liquor Room, Svc -> Service, Bev -> Beverage, Bth -> Bath). Proper
--  nouns ("DiDi Backbar", "BTG Fridge", "Dusty's") preserved verbatim.
--
--  This migration only touches kount_venues. No zone normalization is
--  applied to existing kount_entries.zone strings — those are historical
--  records and stay as the counter typed them at audit time. New audits
--  pick from the new default_zones list.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- v1 — Delilah LA  (13 zones)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         'Liquor Room',
         'Bar',
         'Small Liquor Room',
         'Bar Fridges',
         'Champagne Fridge',
         'Wine 1 Bath Room',
         'Wine 4',
         'Wine 2',
         'Wine 3',
         'Well',
         'Walk-In Fridge',
         'Office Safe',
         'N/A Beverage Shed'
       ],
       updated_at = now()
 where id = 'v1';

-- -----------------------------------------------------------------------------
-- v2 — Delilah Miami  (10 zones)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         'Wine Room',
         'Service Bar',
         'Liquor Room',
         'White Wine Fridge',
         'Champagne Cage',
         'Wine Room Closet',
         'Main Bar',
         'Main Bar Fridge',
         'BTG Fridge',
         'Service Bar Fridge'
       ],
       updated_at = now()
 where id = 'v2';

-- -----------------------------------------------------------------------------
-- v3 — The Nice Guy  (9 zones)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         'Liquor Racks',
         'Back Bar',
         'Wine Tree',
         'Bar Fridges',
         'Bar Wells',
         'WW Fridge',
         'Stack',
         'Low Bar Bottles',
         'Shed'
       ],
       updated_at = now()
 where id = 'v3';

-- -----------------------------------------------------------------------------
-- v4 — The Birdstreet Club  (11 zones; floor-based)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         '1st Floor Liquor Room',
         '2nd Floor Wine',
         '3rd Floor Beverage',
         '2nd Floor Beverage',
         'Wine Room Fridge',
         'Game Room',
         '3rd Floor Fridge',
         '2nd Floor Fridge',
         'Dusty''s',
         '3rd Floor Wine',
         'Kitchen Beverage'
       ],
       updated_at = now()
 where id = 'v4';

-- -----------------------------------------------------------------------------
-- v5 — Poppy  (7 zones)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         'Storage Room',
         'Service Well',
         'Bar',
         'Back Bar',
         'Walk In',
         'Well',
         'DiDi Backbar'
       ],
       updated_at = now()
 where id = 'v5';

-- -----------------------------------------------------------------------------
-- v6 — Keys  (15 zones; multi-floor)
-- -----------------------------------------------------------------------------
update public.kount_venues
   set default_zones = ARRAY[
         'Liquor Room',
         'Service Bar',
         'Main Backbar',
         'Service Cooler',
         'Second Service',
         'Second Backbar',
         '2nd Service Cooler',
         'Basement Backbar',
         'Main Wells',
         'Second Coolers',
         'Main Coolers',
         'Basement Cooler',
         'Second Wells',
         'Basement Wells',
         'Second Bibs'
       ],
       updated_at = now()
 where id = 'v6';

-- -----------------------------------------------------------------------------
-- Deactivate venues that don't exist anymore
-- -----------------------------------------------------------------------------
-- v7 (Bootsy Bellows) and v9 (Harriets) aren't in the inventory audit and
-- per the user no longer operate. Soft-deleting (is_active=false) hides
-- them from pickers but preserves history for any past audits/entries.
-- v8 (The Fleur Room) and v10 (40 Love) are already is_active=false.
update public.kount_venues
   set is_active = false,
       updated_at = now()
 where id in ('v7', 'v9')
   and is_active = true;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
-- 1. Inspect the new zone lists per active venue:
--      select id, name, array_length(default_zones, 1) as zone_count, default_zones
--        from public.kount_venues
--       where is_active = true
--       order by ordinal;
--
-- 2. Confirm v7/v9 are now soft-deleted:
--      select id, name, is_active
--        from public.kount_venues
--       where id in ('v7', 'v9');
--
-- 3. Confirm no historical entries reference the soft-deleted venues
--    (none should be lost; they're just hidden from new-audit pickers):
--      select count(*) from public.kount_audits
--       where venue_id in ('v7', 'v9');
