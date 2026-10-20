-- 0094_ROLLBACK_little_luck_invoice_item_packs: removes only the map rows 0094 added.
begin;
delete from public.kount_invoice_item_map where set_by = 'claude 2026-10-20 (LL invoice packs)';
commit;
