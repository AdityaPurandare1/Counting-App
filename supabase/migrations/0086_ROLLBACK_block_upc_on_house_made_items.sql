-- Rollback for 0086_block_upc_on_house_made_items.
-- Removes the guard that stops a manufacturer barcode being attached to a
-- house-made (Prep)/(Batch) item. Only do this if the prefix convention
-- changes; otherwise the guard is protecting real data integrity.
begin;
drop trigger if exists kount_block_upc_on_house_made_trg on public.master_item_upcs;
drop function if exists public.kount_block_upc_on_house_made();
select 'rolled back 0086' as status;
commit;
