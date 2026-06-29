-- 0043_effective_receipts_master_bridge
--
-- Problem: R365-synced invoice_lines populate item_id (legacy purchase_items)
-- but leave master_item_id NULL. v_effective_receipts selected il.master_item_id
-- directly, so every R365 purchase line surfaced with a NULL master — and
-- compute_avt_for_audit (which attributes purchases by master_item_id) saw
-- purchases = 0, inflating variance with impossible theoreticals.
--
-- Fix: the view ALREADY joins purchase_items pi ON pi.id = il.item_id, and
-- pi.master_item_id is fully populated (verified 403/403 recent Poppy lines ->
-- 80 masters). COALESCE the line's own master with the purchase_item bridge.
--
-- Non-destructive: view-only, no row mutation. Column list/order unchanged
-- (master_item_id stays 3rd, same name) so CREATE OR REPLACE is safe for all
-- readers incl. KevaOS. Purely additive: only fills a master id where it was NULL.
--
-- ROLLBACK: re-run this CREATE OR REPLACE with line 3 = `il.master_item_id,`.

create or replace view public.v_effective_receipts as
 select il.id as invoice_line_id,
    il.invoice_id,
    coalesce(il.master_item_id, pi.master_item_id) as master_item_id,
    il.item_id as purchase_item_id,
    il.description,
    coalesce(rel.received_qty, il.qty) as effective_qty,
    coalesce(rel.received_uom, pi.base_uom, mi.base_unit) as effective_uom,
    coalesce(rel.unit_cost, il.unit_cost) as effective_unit_cost,
    il.qty as billed_qty,
    il.unit_cost as billed_unit_cost,
    rel.variance_qty,
    rel.variance_pct,
    rel.damaged_qty,
    rel.rejected,
    rel.net_qty,
    rel.id as receiving_event_line_id,
    re.received_at,
    re.status as receiving_status
   from invoice_lines il
     left join receiving_event_lines rel on rel.source_line_type = 'invoice_line'::text and rel.source_line_id = il.id
     left join receiving_events re on re.id = rel.receiving_event_id and re.status <> 'voided'::text
     left join master_items mi on mi.id = il.master_item_id
     left join purchase_items pi on pi.id = il.item_id;
