-- Rollback for 0157_kount_ot_quote_approval: drops the approval stamps (the e-mails stay in Outlook; the next pull
-- after a re-apply finds them again). Deploy an admin / kount-order-mail that does not read them first.
begin;
alter table public.kount_ot_lines drop column if exists quote_approval_message_id;
alter table public.kount_ot_lines drop column if exists quote_approval_note;
alter table public.kount_ot_lines drop column if exists quote_approved_for;
alter table public.kount_ot_lines drop column if exists quote_approved_at;
commit;
