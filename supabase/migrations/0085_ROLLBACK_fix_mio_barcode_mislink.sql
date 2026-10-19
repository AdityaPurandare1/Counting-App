begin;
-- Reverting 0085 puts the barcode back on the prep batch, which is known-wrong.
-- Only do this to undo a mistaken reassignment.
update public.master_item_upcs set master_item_id = (select id from public.master_items where name = '(Prep) Phony Negroni BATCH' limit 1) where upc_normalized = '86395521009';
select 'rolled back 0085' as status;
commit;
