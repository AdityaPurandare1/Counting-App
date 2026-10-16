-- =============================================================================
--  0080_little_luck_setup_parity  (DATA, not schema)
--
--  Brings Little Luck (v11) up to the same configuration as Alphabet (v12),
--  ahead of its first count. Little Luck's kount_venues row predates the
--  0064/0071/0073/0074 opt-in columns, so it was left on their defaults and
--  nobody noticed — it has never been counted, so nothing surfaced the gap.
--
--  1. depletion_source: 'pos_check_items' -> 'item_day_facts'   ** the real bug **
--     Little Luck is on Simphony. Per-check lines never land for it:
--       pos_check_items for its ops venue = 0 rows
--     but the daily item aggregates DO:
--       item_day_facts  = 1,052 rows / 266 distinct items / 670 units,
--                         business_date 2026-09-26 .. 2026-10-14
--     compute_avt_for_audit only reads item_day_facts when the venue has
--     opted in (1c: `if v_depletion_source = 'item_day_facts' ...`), so as
--     configured Little Luck's depletion could only ever have computed as
--     ZERO — every drink sold would have read as unexplained loss on its
--     first variance. Alphabet (also aggregate-only) is already opted in.
--     The opt-in is self-limiting: the item_day_facts arms are gated on
--     `v_use_item_facts`, which is false whenever pos_check_items exist in
--     the window, so if per-check lines ever start arriving for Simphony the
--     original arms take over on their own and nothing double-counts.
--
--  2. purchase_mapping: 'none' -> 'venue_item_map'
--     Matches Alphabet and Lady Delilah (0076 sets this at onboarding).
--     Enables, when the data exists: kount_invoice_item_map purchase lines
--     (0064), valuing rows at the venue's OWN unit cost (0073), and the
--     counted-scope report cleanup (0074).
--     SAFE WITH NO DATA — this is additive, not a replacement. Per the
--     function's own comment on the venue_map CTE: "Read only when
--     v_use_venue_map, so for every other venue these CTEs are empty and
--     purchase_lines is unchanged." Little Luck has 0 rows in
--     kount_invoice_item_map and 0 in kount_venue_cost_overrides today, so
--     both branches are no-ops until invoices arrive, then correct.
--
--  NOT DONE HERE, and deliberately so:
--    * Menu mapping (264 rows, 0 mapped). The depletion arm that uses a
--      direct master_item_id fires ONLY for is_bottle_service = true, and
--      Little Luck's 5 bottle-service rows have sold 0 units so far. More
--      importantly the catalog holds several sizes per product (Belvedere
--      750ml / 1L / 1.75L; Don Julio 1942 375ml / 750ml / 1.75L) and picking
--      the wrong one mis-credits depletion. Which size this venue stocks
--      comes from the inventory list Aditya is sending — map after that, the
--      way Alphabet's baseline name-matching errors (818 Blanco -> Don Julio
--      Blanco, Yamazaki 12yr -> 10yr) were caught and corrected.
--    * Costs. kount_refresh_venue_invoice_costs('v11') returns 0 rows
--      because Little Luck has no invoices: its R365 location
--      5b7cb161-446f-48bd-9510-d4623c9b04f5 ("Little Luck - Operating") is
--      absent from the invoice sync's R365_LOCATION_MAP_JSON (Vercel env).
--      Same one-line change that was made for Alphabet, which now has 675
--      invoices. Not a database change — cannot be done here.
--
--  ROLLBACK: 0080_ROLLBACK_little_luck_setup_parity.sql
-- =============================================================================

begin;

update public.kount_venues
   set depletion_source = 'item_day_facts',
       purchase_mapping = 'venue_item_map'
 where id = 'v11'
   and depletion_source = 'pos_check_items'
   and purchase_mapping = 'none';

-- Verification: v11 must now read identically to v12 on both columns.
select id, name, depletion_source, purchase_mapping
  from public.kount_venues
 where id in ('v11', 'v12')
 order by id;

commit;
