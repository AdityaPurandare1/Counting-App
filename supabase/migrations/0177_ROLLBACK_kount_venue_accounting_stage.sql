-- Rollback for 0177: the column and its check. Deploy an admin that does not read or save it first.
begin;
alter table public.kount_venues drop constraint if exists kount_venues_accounting_stage_check;
alter table public.kount_venues drop column if exists accounting_stage;
commit;
