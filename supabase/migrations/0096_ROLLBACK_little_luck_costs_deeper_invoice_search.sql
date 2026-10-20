-- 0096_ROLLBACK: removes only what 0096 added (costs the nightly job derived from the A-maps stay until it re-runs).
begin;
delete from public.kount_invoice_item_map where set_by = 'claude 2026-10-20 (LL dup-linked lines)';
delete from public.kount_invoice_line_map where set_by = 'claude 2026-10-20 (LL dup-linked lines)';
delete from public.kount_venue_cost_overrides where set_by = 'claude 2026-10-20 (other-venue invoices)';
commit;
