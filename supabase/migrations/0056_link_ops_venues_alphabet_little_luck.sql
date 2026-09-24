-- =============================================================================
--  0056_link_ops_venues_alphabet_little_luck
--
--  DATA FIX (no schema change). Bridges the two newest counting venues to
--  their ops-side `venues` rows.
--
--  WHY
--  `kount_venues.ops_venue_id` was NULL for Alphabet (v12) and Little Luck
--  (v11). Every purchase and depletion CTE inside compute_avt_for_audit is
--  gated on `v_ops_venue_id is not null`:
--
--      where v_ops_venue_id is not null and i.venue_id = v_ops_venue_id
--
--  so with a NULL bridge those venues can never produce purchases or
--  depletion, and their variance report would read as zero-purchased /
--  zero-depleted no matter how good the upstream data got. Verified that
--  compute_avt_for_audit is the ONLY object in the database referencing
--  ops_venue_id, so the blast radius of this change is exactly "variance
--  computation", nothing else.
--
--  SAFE TODAY / CORRECT TOMORROW
--  Neither venue currently has invoices or POS line items, so both the
--  purchases and depletion CTEs return zero rows whether the bridge is set
--  or NULL — this change is a no-op for today's numbers. It stops being a
--  no-op the moment the upstream feeds land, which is the point: without it
--  those feeds would arrive and still be ignored.
--
--  STILL BLOCKED UPSTREAM (this migration does NOT fix these)
--    1. Invoices — Alphabet's AP invoices ARE in R365 (proved via
--       ledger_journal_entries under R365 location fa3b21d1 "BRBP LLC":
--       832 AP invoice lines 2026-07-10 → 10-01, incl. GL 5320 Wine Cost
--       $2,758.60 and GL 5310 Liquor Cost $981.88). The KevaOS R365 OData
--       invoice sync skips them because that location is absent from the
--       sync's location map (`R365_LOCATION_MAP_JSON`, or a `location_map`
--       in integration_connections.config_json). Config change, KevaOS side.
--    2. POS depletion — Alphabet is on Toast, which syncs check HEADERS only
--       (5,432 checks / $648k since 8/13) and writes no pos_check_items. No
--       Toast venue anywhere has line items; all 613k+ line items in the
--       system come from Tipsee, which covers only the legacy Upserve
--       venues. Extending Toast to line items is build work, not config.
--
--  IDs (verified against public.venues on 2026-09-24)
--    v12 Alphabet     -> 4d2f6062-c696-49f0-9356-ac4c0c8c7b0d  (created 08-16)
--    v11 Little Luck  -> 1817c273-4fe6-4537-8276-582441641297  (created 08-21)
--
--  Reversible: set ops_venue_id back to NULL.
--
--  Apply by hand (NEVER db push), same as every other migration here:
--    supabase db query --linked --file supabase/migrations/0056_link_ops_venues_alphabet_little_luck.sql
-- =============================================================================

begin;

-- Guard: only touch rows that are still unlinked, and only when the target
-- ops venue actually exists under the expected name. A rename or a missing
-- row makes this a no-op rather than writing a wrong id.
update public.kount_venues kv
   set ops_venue_id = v.id
  from public.venues v
 where kv.id = 'v12'
   and kv.ops_venue_id is null
   and v.id = '4d2f6062-c696-49f0-9356-ac4c0c8c7b0d'
   and v.name = 'Alphabet';

update public.kount_venues kv
   set ops_venue_id = v.id
  from public.venues v
 where kv.id = 'v11'
   and kv.ops_venue_id is null
   and v.id = '1817c273-4fe6-4537-8276-582441641297'
   and v.name = 'Little Luck';

-- Verification: both rows must come back linked, with the ops name matching
-- the kount name. Anything else means a guard above did not fire.
select kv.id,
       kv.name             as kount_name,
       v.name              as ops_name,
       kv.ops_venue_id,
       (kv.ops_venue_id is not null) as linked
  from public.kount_venues kv
  left join public.venues v on v.id = kv.ops_venue_id
 where kv.id in ('v11', 'v12')
 order by kv.id;

commit;
