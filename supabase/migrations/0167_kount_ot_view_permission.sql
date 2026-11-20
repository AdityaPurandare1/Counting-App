-- =============================================================================
--  0167_kount_ot_view_permission   (SECURITY + permission: Order tracker (view))
--
--  2026-11-10, Aditya: User access "doesnt show if they have access" -- the
--  view-only order tracker of 0165/0166 hid behind the full "Order tracker" tick.
--  Chosen: a SEPARATE tick. New permission purchasing:order-tracker-view
--  ("Order tracker (view)", Purchasing): their venues' orders, lines, prices,
--  tracking, history, documents and bibles, and the whole warehouse -- READ only.
--  Every read policy accepts it under the same venue rule (kount_ot_scope: their
--  app_users.venue_ids, or every venue with All venues). Nothing it can write:
--  writes stay Order tracker + All venues (0166); the Inbox, the mailbox and the
--  R365 lookup stay Order tracker + All venues (0165). No role template gets it --
--  it is ticked per person. The admin's "Order tracker (view)" page (v1.08) uses it.
--  ROLLBACK: 0167_ROLLBACK_kount_ot_view_permission.sql
-- =============================================================================
begin;

insert into public.kount_features (key, project, project_label, label, description, sort) values
  ('purchasing:order-tracker-view', 'purchasing', 'Purchasing', 'Order tracker (view)', 'Their venues'' orders, items, prices, tracking and documents, and the whole warehouse - view only', 202)
on conflict (key) do update set label = excluded.label, description = excluded.description, sort = excluded.sort;

drop policy if exists kount_ot_orders_read on public.kount_ot_orders;
create policy kount_ot_orders_read on public.kount_ot_orders for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or public.kount_ot_order_visible(id)));

drop policy if exists kount_ot_lines_read on public.kount_ot_lines;
create policy kount_ot_lines_read on public.kount_ot_lines for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));

drop policy if exists kount_ot_documents_read on public.kount_ot_documents;
create policy kount_ot_documents_read on public.kount_ot_documents for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));

drop policy if exists kount_ot_tracking_read on public.kount_ot_tracking;
create policy kount_ot_tracking_read on public.kount_ot_tracking for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_visible(order_id)));

drop policy if exists kount_ot_bibles_read on public.kount_ot_bibles;
create policy kount_ot_bibles_read on public.kount_ot_bibles for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));

drop policy if exists kount_ot_items_read on public.kount_ot_items;
create policy kount_ot_items_read on public.kount_ot_items for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))));

drop policy if exists kount_ot_stock_moves_read on public.kount_ot_stock_moves;
create policy kount_ot_stock_moves_read on public.kount_ot_stock_moves for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))));

drop policy if exists kount_order_docs_read on storage.objects;
create policy kount_order_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'kount-order-docs' and ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view')) or (select public.kount_has_feature('purchasing:order-prices'))) and public.kount_ot_object_visible(name));

drop policy if exists kount_ot_events_corporate_read on public.kount_ot_events;
create policy kount_ot_events_corporate_read on public.kount_ot_events for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-tracker-view'))) and ((select public.kount_ot_scope()) is null or (public.kount_ot_order_visible(order_id) and (line_id is null or public.kount_ot_line_visible(line_id)))));

select 'feature' as k, count(*)::text as v from public.kount_features where key = 'purchasing:order-tracker-view'
union all select 'read policies with view', count(*)::text from pg_policies
 where ((schemaname = 'public' and tablename like 'kount_ot%') or (schemaname = 'storage' and policyname like 'kount_order_docs%'))
   and qual like '%order-tracker-view%';
commit;
