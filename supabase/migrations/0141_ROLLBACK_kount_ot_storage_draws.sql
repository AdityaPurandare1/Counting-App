-- ROLLBACK for 0141_kount_ot_storage_draws: the stock_draw flag goes; the stock
-- moves already recorded stay (delete them by line_id first if they should go too).
begin;
alter table public.kount_ot_lines drop column if exists stock_draw;
commit;
