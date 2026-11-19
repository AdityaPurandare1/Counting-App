-- ROLLBACK of 0179_kount_ot_release_mail: the link, the cursor and the table (the stock moves themselves stay).
begin;

drop index if exists public.kount_ot_stock_moves_mail_idx;
alter table public.kount_ot_stock_moves drop column if exists mail_id;
alter table public.kount_ot_mail_account drop column if exists release_cursor;
drop table if exists public.kount_ot_release_mail;

commit;
