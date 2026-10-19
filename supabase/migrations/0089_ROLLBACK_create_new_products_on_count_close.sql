-- Rollback for 0089_create_new_products_on_count_close.
-- Removes the trigger and both functions. Products already created and the
-- entries already linked are KEPT -- they are real catalog items now.
begin;
drop trigger if exists kount_new_products_on_close on public.kount_audits;
drop function if exists public.kount_new_products_on_close_trg();
drop function if exists public.kount_create_new_products_for_audit(uuid);
select 'rolled back 0089' as status;
commit;
