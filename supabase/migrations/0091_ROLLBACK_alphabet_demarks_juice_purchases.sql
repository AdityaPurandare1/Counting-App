-- 0091_ROLLBACK_alphabet_demarks_juice_purchases: removes only the rows 0091 added.
begin;
delete from public.kount_invoice_line_map
 where set_by = 'claude 2026-10-19 (Demarks juices, AP item-missing reports)';
commit;
