-- ROLLBACK for 0151_kount_ot_line_route: lines follow their order's destination again.
begin;
drop trigger if exists kount_ot_lines_route on public.kount_ot_lines;
drop function if exists public.kount_ot_line_route();
drop function if exists public.kount_ot_ship_mode(text);
alter table public.kount_ot_lines drop column if exists deliver_to;
commit;
