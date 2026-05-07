-- =============================================================================
--  0019_recount_per_zone
--
--  Splits the unique constraint on kount_recounts so a single audit can have
--  multiple recount rows for the same item — one per zone the item lives in.
--
--  Background: an item like "Caymus, Cabernet" might be counted in Main Bar,
--  VIP, and Patio at Count 1. Before this migration kount_recounts had ONE
--  row per item per audit (uniqueness on `(audit_id, item_id_or_lower_name)`).
--  closeCount1 was forced to pick a single primary zone and display the
--  others as a "+N more zones" hint. Counter A and Counter B couldn't both
--  record a recount for the same item in their respective zones because the
--  second insert collided with the first.
--
--  After: uniqueness is `(audit_id, item_id_or_name, zone)`. closeCount1
--  generates one recount row per (item, counted_zone). Each zone's row
--  independently tracks count1_qty (per-zone), count2_qty (per-zone recount),
--  audit_result, and audit_reason. finalizeCount2 / variance reporting sums
--  the per-zone count2_qty values to produce the rolled-up recount total.
--
--  Backwards-compatible with existing rows: legacy recount rows have either
--  null zone (pre-0014) or a single primary zone (post-0014, pre-0019). The
--  coalesce(zone, '') in the new index treats null and '' the same, so a
--  pre-existing row collides with itself (correct) but not with a per-zone
--  row that gets inserted with a non-null zone (also correct).
-- =============================================================================

-- Drop the old uniqueness — only audit + item, no zone awareness.
drop index if exists public.kount_recounts_item_uniq;

-- New uniqueness — audit + item + zone. Multiple zones for the same item
-- in the same audit each get their own row.
create unique index if not exists kount_recounts_item_zone_uniq
  on public.kount_recounts (
    audit_id,
    coalesce(item_id::text, lower(item_name)),
    coalesce(zone, '')
  );

-- Verification (run manually after applying):
--
-- 1. Show the new index:
--      \d+ public.kount_recounts
--
-- 2. Confirm a per-zone insert pattern works:
--      insert into public.kount_recounts (audit_id, item_name, zone, count1_qty)
--        values (<audit_id>, 'Test Wine', 'Main Bar', 5);
--      insert into public.kount_recounts (audit_id, item_name, zone, count1_qty)
--        values (<audit_id>, 'Test Wine', 'VIP', 3);
--      -- Both succeed.
--      insert into public.kount_recounts (audit_id, item_name, zone, count1_qty)
--        values (<audit_id>, 'Test Wine', 'Main Bar', 99);
--      -- This one fails on the new unique index — that's correct.
