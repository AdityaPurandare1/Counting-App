-- ROLLBACK for 0118_recount_master_link.
-- Drops the trigger FIRST: with it in place, nulling master_item_id would just
-- re-fill it. Then un-links only the rows 0118's backfill filled (and only if
-- they still hold the id it wrote). Rows linked later by the trigger or by the
-- phone keep their id, which is correct data either way.
begin;

drop trigger if exists kount_recount_fill_master on public.kount_recounts;

update public.kount_recounts r
   set master_item_id = null
  from public._mig0118_recount_backfill b
 where b.id = r.id
   and r.master_item_id = b.master_item_id;

drop function if exists public.kount_recount_fill_master();
drop function if exists public.kount_resolve_recount_master(uuid, text);
drop table if exists public._mig0118_recount_backfill;

commit;
