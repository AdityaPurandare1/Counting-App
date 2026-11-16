-- Rollback of 0174_kount_ot_acct_sent: the lines' touch trigger back on kount_ot_touch(), the 5 columns dropped
-- (the stamps are re-found by the mail pull if 0174 is applied again).
begin;

drop trigger if exists kount_ot_lines_touch on public.kount_ot_lines;
create trigger kount_ot_lines_touch before update on public.kount_ot_lines
  for each row execute function public.kount_ot_touch();
drop function if exists public.kount_ot_line_touch();

alter table public.kount_ot_lines drop column if exists acct_sent_at;
alter table public.kount_ot_lines drop column if exists acct_sent_to;
alter table public.kount_ot_lines drop column if exists acct_sent_by;
alter table public.kount_ot_lines drop column if exists acct_sent_subject;
alter table public.kount_ot_lines drop column if exists acct_message_id;

commit;
