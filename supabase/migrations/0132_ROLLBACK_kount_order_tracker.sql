-- =============================================================================
--  0132_ROLLBACK_kount_order_tracker
--  Removes the order tracker tables, triggers, functions, bucket policies and
--  the bucket row. DESTROYS every order, line, document record and stock move.
--  Files in the 'kount-order-docs' bucket must be emptied first (Supabase
--  refuses to delete a bucket that still holds objects) -- use the dashboard
--  or the storage API; deleting storage.objects rows directly orphans files.
-- =============================================================================
begin;
drop policy if exists kount_order_docs_read on storage.objects;
drop policy if exists kount_order_docs_write on storage.objects;
drop policy if exists kount_order_docs_update on storage.objects;
drop policy if exists kount_order_docs_delete on storage.objects;
delete from storage.buckets where id = 'kount-order-docs'
  and not exists (select 1 from storage.objects o where o.bucket_id = 'kount-order-docs');

drop table if exists public.kount_ot_stock_moves;
drop table if exists public.kount_ot_documents;
drop table if exists public.kount_ot_events;
drop table if exists public.kount_ot_lines;
drop table if exists public.kount_ot_orders;
drop table if exists public.kount_ot_items;
drop function if exists public.kount_ot_apply_document(jsonb);
drop function if exists public.kount_ot_stamp_creator();
drop function if exists public.kount_ot_line_status_event();
drop function if exists public.kount_ot_line_status_stamp();
drop function if exists public.kount_ot_touch();
commit;
