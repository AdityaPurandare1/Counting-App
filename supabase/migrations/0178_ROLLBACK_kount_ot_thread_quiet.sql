-- ROLLBACK of 0178_kount_ot_thread_quiet: the orders' touch trigger back to kount_ot_touch(), the columns dropped.
begin;

drop trigger if exists kount_ot_orders_touch on public.kount_ot_orders;
create trigger kount_ot_orders_touch before update on public.kount_ot_orders
  for each row execute function public.kount_ot_touch();
drop function if exists public.kount_ot_order_touch();

alter table public.kount_ot_orders drop column if exists last_email_at;
alter table public.kount_ot_orders drop column if exists last_email_from;
alter table public.kount_ot_orders drop column if exists thread_checked_at;

commit;
